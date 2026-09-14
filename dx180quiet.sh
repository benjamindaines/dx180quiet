#!/system/bin/sh
#
# dx180quiet.sh — consolidated CPU/cpuset controller for the DX180 audio appliance.
#
# One file, several entry points, dispatched by the first argument. The components have three
# distinct lifetimes that a single linear script cannot express, so they are separated into
# subcommands invoked by init (service.sh) and by inotifyd:
#
#   boot       run-once boot preparation: stop services, disable/stop apps, set the CPU/GPU baseline,
#              establish the cpuset partition, drain the root cpuset, then launch the two daemons.
#   forkwatch  run-forever: block on a sched_process_fork trace_pipe and re-drain any userspace that
#              lands back in the root cpuset (pushes newly spawned processes off the little cluster).
#   maintslow  run-forever alternative to forkwatch: a coarse interval scan of the root cpuset only.
#   pcm        run-per-event: invoked by inotifyd on PCM open/close. Pulls the render threads onto the
#              little cluster and sets the little-cluster frequency tier. inotifyd supplies its own
#              argument signature (<events> <path> <filename>); that signature is routed here via the
#              catch-all case.
#   revert     live rollback: stop daemons, restore stock cpuset masks, remove custom sets and the
#              trace instance.
#
# Direction of the two daemons is opposite and non-colliding: forkwatch evicts everything from the
# littles by moving root-resident tasks to the big cluster; the pcm handler is the only path that
# places tasks ONTO the littles, and only the identified render threads. Because forkwatch acts solely
# on tasks still resident in the root cpuset, a render thread already moved into the audio set is not
# touched.
#
# All cpuset/cpufreq writes are runtime sysfs and revert on reboot. Ephemeral state lives under
# /dev/dx180 (/dev is tmpfs, wiped on any reboot).
#
# Topology (verified on-device): cpu0-3 little, cpu4-7 big.

# ---------------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------------

SELF=$(readlink -f "$0" 2>/dev/null); [ -n "$SELF" ] || SELF=$0

CPUSET=/dev/cpuset
LITTLE="0-3"
BIG="4-7"
MUSICPKG="app.symfonik.music.player"

AUDIO_SET="$CPUSET/audio"                 # render path holder on the littles (populated by pcm)
BIGSINK="$CPUSET/bigsink"                 # destination for drained root tasks and caught forks

STATE_DIR=/dev/dx180                      # ephemeral (tmpfs); holds snapshot, lock, pidfiles
BAK="$STATE_DIR/part.bak"                 # stock cpus snapshot for live revert
LOCKDIR="$STATE_DIR/pcm.lock"             # serializes overlapping pcm handlers (mkdir-based)

LOG="${LOG:-/data/local/tmp/dx180quiet.log}"
LOG_MAX=262144                            # bytes; truncated past this at boot

CARD="${CARD:-0}"
PCM_NODE="/dev/snd/pcmC0D0p"
HWP="/proc/asound/card${CARD}/pcm0p/sub0/hw_params"
POLICY0=/sys/devices/system/cpu/cpufreq/policy0   # little-cluster cpufreq policy

# Little-cluster frequency tiers (kHz). Values require tuning against scaling_available_frequencies:
#     cat $POLICY0/scaling_available_frequencies | tr ' ' '\n' | sort -n
FREQ_IDLE=300000                          # floor when no stream holds the PCM
FREQ_IDLE_MAX=300000                      # modest idle ceiling for an unstarved restart
FREQ_STD=614400                           # rate <= 48000
FREQ_HIRES=614000                        # 88200 .. 192000
FREQ_ULTRA=864000                        # 88200 .. 192000
GPU_MAX=320                               # gpu_max_clock at baseline
#FREQ_HIRES=864000                        # 88200 .. 192000
#FREQ_ULTRA=1401600                        # rate > 192000 or native DSD
BIG_MAX=902000

# Behavior flags (environment-overridable).
SINK_INIT="${SINK_INIT:-1}"               # 1 also moves init (pid 1) to the bigs sink
DISABLE_SWEEP="${DISABLE_SWEEP:-1}"       # 1 runs the service-stop / app-disable sweep at boot
INCLUDE_AUDIOSERVER="${INCLUDE_AUDIOSERVER:-1}"  # 1 also pulls audioserver mixer threads to littles
MAINT="${MAINT:-fork}"                    # fork | slow (maintenance daemon selection)
INTERVAL="${INTERVAL:-60}"               # seconds between passes in MAINT=slow
QUIET_LOGD="${QUIET_LOGD:-0}"             # 1 sets persist.log.tag E at baseline (reduces logspam)

# init services stopped at boot when present (checked via init.svc.<name>).
STOPSERVS='
ims_rtp_daemon imsqmidaemon imsrcsd imsdatadaemon netmgrd port-bridge adpl dpmd dpmQmiMgr ssgqmigd
ipacm drm mediametrics cnss-daemon ipacm-diag vendor.qti.esepowermanager vendor.qti.hardware.soter
vendor.qti.hardware.tui_comm neuralnetworks_hal_service qti_esepowermanager_service_1_1
wfdhdcphalservice wifidisplayhalservice update_engine rmt_storage tftp_server wfdvndservice traced
mlid tloc_daemon traced_probes statsd incidentd soter-1-0 tui_comm-1-0 vendor.cdsprpcd
vendor.dataadpl vendor.ims_rtp_daemon vendor.imsdatadaemon vendor.imsrcsservice vendor.imsqmidaemon
vendor.ipacm vendor.ipacm-diag vendor.netmgrd vendor.msm_irqbalance vendor.port-bridge vendor.qcc-trd
vendor.rmt_storage vendor.tftp_server vendor.tlocd vendor.media.omx credstore cdsprpcd qcc-trd
vendor.qti.qesdk.sysservice android.hardware.neuralnetworks vendor.drm-widevine-hal-1-3
vendor.drm-clearkey-hal-1-3 vendor.keymaster-4-1 vendor.qti.vibrator sensors.qti drmserver
media.extractor media.swcodec 

'

# Packages durably disabled at boot (reversible: pm enable). GMS suppression is the largest background
# and thermal win per the process triage.
FREEZEAPPS='
com.google.android.gms.supervision com.google.android.gms.location.history com.google.android.gms
com.google.android.gms.persistent com.google.android.gms.unstable com.android.vending
com.google.android.inputmethod.latin com.qualcomm.qti.workloadclassifer
'

# Packages force-stopped at boot (transient: they may relaunch on demand). Kept off the durable-disable
# list because disabling documentsui/gsf breaks the file picker and account sync.
STOPAPPS='
com.android.settings io.github.muntashirakon.AppManager com.google.android.gsf
com.cxinventor.file.explorer com.android.documentsui com.termux com.qualcomm.qti.workloadclassifier
com.qualcomm.qti.workloadclassifier com.android.inputmethod.latin qspmsvc cnss_diag 
'

# ---------------------------------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------------------------------

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

rotate_log() {
        [ -f "$LOG" ] || return 0
        sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
        [ "$sz" -gt "$LOG_MAX" ] && : > "$LOG"
}

# ---------------------------------------------------------------------------------------------------
# cpuset controller-file detection and topology check
# ---------------------------------------------------------------------------------------------------

# Android historically mounts cpuset v1 with noprefix (cpus/mems/tasks); some builds use cpuset.*.
detect_files() {
        if   [ -f "$CPUSET/cpus" ];        then CF=cpus;        MF=mems;        TF=tasks
        elif [ -f "$CPUSET/cpuset.cpus" ]; then CF=cpuset.cpus; MF=cpuset.mems; TF=tasks
        else log "no cpuset controller at $CPUSET"; exit 1; fi
}

# Warns if the little/big ceilings are inverted relative to the assumed 0-3 / 4-7 split.
verify_topology() {
        c0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
        c4=$(cat /sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_max_freq 2>/dev/null)
        [ -n "$c0" ] && [ -n "$c4" ] || { log "topology: cpufreq nodes unreadable; skipping check"; return 0; }
        [ "$c0" -lt "$c4" ] || log "topology: WARN cpu0 ceiling ($c0) !< cpu4 ($c4); masks may be inverted"
}

# ---------------------------------------------------------------------------------------------------
# Boot sweep: stop services, disable / stop apps
# ---------------------------------------------------------------------------------------------------

stop_services() {
        for svc in $STOPSERVS; do
                st=$(getprop "init.svc.$svc")
                if [ -n "$st" ]; then
                        stop "$svc" 2>/dev/null
                        log "stop $svc (was $st)"
                else
                        log "absent svc $svc (no init.svc entry)"
                fi
        done
}

disable_apps() {
        for app in $FREEZEAPPS; do
                pm disable-until-used "$app" >/dev/null 2>&1 \
                        && log "disabled $app" \
                        || log "disable failed/absent $app"
        done
}

stop_apps() {
        for app in $STOPAPPS; do
                am force-stop "$app" >/dev/null 2>&1 \
                        && log "force-stopped $app" \
                        || log "force-stop failed $app"
        done
}

# ---------------------------------------------------------------------------------------------------
# CPU / GPU baseline
# ---------------------------------------------------------------------------------------------------

# Writes a little-cluster frequency window [lo, hi] in kHz. The min is dropped to the idle floor first
# so a higher max can be applied without a transient min > max rejection, then the target min is set.
# Read-back is logged: it exposes any external floor assertion (cpu_boost / perf HAL / cpufreq-QoS)
# that snaps scaling_min_freq back up, which is an open investigation item.
set_little_freq() {
        lo=$1; hi=$2
        [ -d "$POLICY0" ] || { log "freq: $POLICY0 absent"; return 1; }
        echo "$FREQ_IDLE" > "$POLICY0/scaling_min_freq" 2>/dev/null
        echo "$hi"        > "$POLICY0/scaling_max_freq" 2>/dev/null
        echo "$lo"        > "$POLICY0/scaling_min_freq" 2>/dev/null
        read -r rbmin < "$POLICY0/scaling_min_freq" 2>/dev/null
        read -r rbmax < "$POLICY0/scaling_max_freq" 2>/dev/null
        [ "$rbmin" = "$lo" ] && [ "$rbmax" = "$hi" ] \
                || log "freq: WARN request min=$lo max=$hi readback min=$rbmin max=$rbmax (floor asserted?)"
}

cpu_gpu_baseline() {
        set_little_freq "$FREQ_IDLE" "$FREQ_IDLE_MAX"
        echo 300000 > /sys/devices/system/cpu/cpufreq/policy4/scaling_min_freq
        echo 652000 > /sys/devices/system/cpu/cpufreq/policy4/scaling_max_freq
        if [ -w /sys/kernel/gpu/gpu_max_clock ]; then
                echo "$GPU_MAX" > /sys/kernel/gpu/gpu_max_clock 2>/dev/null && log "gpu_max_clock=$GPU_MAX"
        fi
        [ "$QUIET_LOGD" = 1 ] && setprop persist.log.tag E
        log "baseline: little idle ${FREQ_IDLE}/${FREQ_IDLE_MAX}"
}

# ---------------------------------------------------------------------------------------------------
# cpuset partition
# ---------------------------------------------------------------------------------------------------

# Creates or re-parameterizes a cpuset at $1 with cpus=$2. mems must be populated before the set will
# accept tasks and is inherited from the root cpuset.
ensure_set() {
        p=$1; c=$2
        [ -d "$p" ] || mkdir "$p" 2>/dev/null
        [ -d "$p" ] || { log "ensure_set $p: mkdir failed"; return 1; }
        read -r pm < "$CPUSET/$MF"
        echo "$pm" > "$p/$MF" 2>/dev/null
        echo "$c"  > "$p/$CF" 2>/dev/null
        log "set ${p##*/} cpus=$c"
}

# Recursive retarget of every cpuset in the tree to the big cluster, excluding root (whose cpus may
# not be narrowed below the online set) and the two custom sets. Uniform assignment to $BIG keeps
# every child a subset of its parent regardless of walk order. Writing cpuset.cpus migrates the tasks
# already resident in the set, so a late boot catches everything present at that point. Stock cpus are
# snapshotted for live revert.
#
# Recursion under POSIX sh without local scope is safe here because a for-loop word list is expanded
# once at loop entry and held internally; the shared loop variable being clobbered by the recursive
# call does not corrupt the outer iteration.
retarget_tree() {
        d=$1
        case "$d" in
                "$CPUSET"|"$AUDIO_SET"|"$BIGSINK") : ;;
                *)
                        if [ -f "$d/$CF" ]; then
                                read -r cur < "$d/$CF"
                                [ -n "$cur" ] && echo "$d $cur" >> "$BAK"
                                echo "$BIG" > "$d/$CF" 2>/dev/null \
                                        && log "retarget ${d#$CPUSET/} -> $BIG" \
                                        || log "retarget ${d#$CPUSET/}: write failed"
                        fi ;;
        esac
        for sub in "$d"/*/; do
                [ -d "$sub" ] || continue
                retarget_tree "${sub%/}"
        done
}

# Moves root-resident userspace tasks to the bigs sink. Kernel threads (empty cmdline) are pinned by
# the kernel and are not cpuset-movable; they are skipped. This single pass is the heavy lifter: it
# evicts zygote, so subsequent app forks inherit the bigs without further action.
drain_root() {
        [ -d "$BIGSINK" ] || return
        n=0
        while read -r tid; do
                cmd=""; read -r cmd < "/proc/$tid/cmdline" 2>/dev/null
                [ -n "$cmd" ] || continue
                echo "$tid" > "$BIGSINK/$TF" 2>/dev/null && n=$((n + 1))
        done < "$CPUSET/$TF"
        log "drained ${n} root tasks -> bigsink"
}

# Optionally moves init (pid 1) to the bigs sink so its own future forks (service restarts) inherit
# the bigs. Incremental over drain_root, which already handles the app-spawn flood via zygote.
sink_init() {
        [ "$SINK_INIT" = 1 ] || return
        if [ -f "$BIGSINK/cgroup.procs" ]; then
                echo 1 > "$BIGSINK/cgroup.procs" 2>/dev/null && log "init (pid 1) -> bigsink (procs)"
        else
                echo 1 > "$BIGSINK/$TF" 2>/dev/null && log "init (pid 1) -> bigsink (task)"
        fi
}

# ---------------------------------------------------------------------------------------------------
# Audio render-thread placement (pcm entry)
# ---------------------------------------------------------------------------------------------------

# Render-path thread comms (truncated to 15 chars) held on the little cluster.
audio_match() {
        case "$1" in
                ExoPlayer:Playb*|ExoPlayer:Simp*|AudioTrack*|AudioEngine*) return 0 ;;
                *) return 1 ;;
        esac
}

# audioserver mixer/output threads, moved only when INCLUDE_AUDIOSERVER=1 (highest underrun risk if
# the little cluster is later frequency-capped).
audioserver_match() {
        case "$1" in
                AudioOut*|FastMixer*|writer*) return 0 ;;
                *) return 1 ;;
        esac
}

# DSD detection via the codec sysfs stream_type attribute, when present.
is_dsd() {
        st=/sys/devices/virtual/codec/codec0/stream_type
        [ -r "$st" ] || return 1
        read -r v < "$st" 2>/dev/null || return 1
        case "$v" in *[Dd][Ss][Dd]*) return 0 ;; *) return 1 ;; esac
}

# rate (Hz) [+ dsd flag] -> little-cluster tier (kHz).
map_freq() {
        r=$1; dsd=$2
        [ "$dsd" = 1 ] && { echo "$FREQ_ULTRA"; return; }
        [ -n "$r" ] || { echo "$FREQ_STD"; return; }
        if   [ "$r" -le 48000 ];  then echo "$FREQ_STD"
        elif [ "$r" -le 192000 ]; then echo "$FREQ_HIRES"
        else                            echo "$FREQ_ULTRA"; fi
}

# Re-derives stream state and rate from hw_params. The open() ioctl sequence populates hw_params
# slightly after the inotify open event, so a brief settle plus retries avoids reading an
# as-yet-unconfigured stream. Sets HW_STATE (open|closed) and HW_RATE.
read_hw() {
        HW_STATE=closed; HW_RATE=""
        i=0
        while [ "$i" -lt 3 ]; do
                read -r first < "$HWP" 2>/dev/null || first="closed"
                case "$first" in
                        closed*|"") HW_STATE=closed; return ;;
                        *)
                                HW_STATE=open
                                while read -r k v _; do
                                        [ "$k" = "rate:" ] && { HW_RATE=$v; break; }
                                done < "$HWP"
                                [ -n "$HW_RATE" ] && return ;;
                esac
                i=$((i + 1)); sleep 0.2
        done
}

# Moves the identified render threads into the audio cpuset. Logs the count moved on this pass.
move_audio() {
        [ -d "$AUDIO_SET" ] || ensure_set "$AUDIO_SET" "$LITTLE"
        n=0
        for p in $(pidof "$MUSICPKG" 2>/dev/null); do
                for t in /proc/"$p"/task/*; do
                        [ -d "$t" ] || continue
                        read -r comm < "$t/comm" 2>/dev/null || continue
                        audio_match "$comm" || continue
                        echo "${t##*/}" > "$AUDIO_SET/$TF" 2>/dev/null && n=$((n + 1))
                done
        done
        if [ "$INCLUDE_AUDIOSERVER" = 1 ]; then
                for p in $(pidof audioserver 2>/dev/null); do
                        for t in /proc/"$p"/task/*; do
                                [ -d "$t" ] || continue
                                read -r comm < "$t/comm" 2>/dev/null || continue
                                audioserver_match "$comm" || continue
                                echo "${t##*/}" > "$AUDIO_SET/$TF" 2>/dev/null && n=$((n + 1))
                        done
                done
        fi
        log "audio-set: ${n} threads on ${LITTLE}"
}

# ---------------------------------------------------------------------------------------------------
# Serialization lock for overlapping pcm events
# ---------------------------------------------------------------------------------------------------

acquire_lock() {
        mkdir -p "$STATE_DIR" 2>/dev/null
        i=0
        while ! mkdir "$LOCKDIR" 2>/dev/null; do
                i=$((i + 1)); [ "$i" -ge 20 ] && break   # ~2 s bound; proceed on a presumed stale holder
                sleep 0.1
        done
        trap release_lock EXIT INT TERM
}

release_lock() { rmdir "$LOCKDIR" 2>/dev/null; }

# ---------------------------------------------------------------------------------------------------
# Subcommand: pcm (per inotifyd event)
# ---------------------------------------------------------------------------------------------------

do_pcm() {
        detect_files
        acquire_lock
        read_hw
        if [ "$HW_STATE" = open ]; then
                dsd=0; is_dsd && dsd=1
                f=$(map_freq "$HW_RATE" "$dsd")
                move_audio                            # first pass
                sleep 0.2
                move_audio                            # second pass captures late-spawning render threads
                set_little_freq "$f" "$f"             # constant frequency at the tier setpoint while playing
                log "pcm open rate=${HW_RATE} dsd=${dsd} -> little=${f}"
        else
                set_little_freq "$FREQ_IDLE" "$FREQ_IDLE_MAX"
                log "pcm closed -> little idle ${FREQ_IDLE}/${FREQ_IDLE_MAX}"
        fi
        release_lock
}

# ---------------------------------------------------------------------------------------------------
# Subcommand: forkwatch (persistent) and maintslow (persistent alternative)
# ---------------------------------------------------------------------------------------------------

detect_trace() {
        for base in /sys/kernel/tracing /sys/kernel/debug/tracing; do
                [ -d "$base/events/sched/sched_process_fork" ] && { TBASE=$base; return 0; }
        done
        return 1
}

# Blocks on a sched_process_fork trace_pipe in a private ftrace instance (isolated ring buffer and
# event state; teardown is rmdir). The read sleeps in-kernel until a fork is recorded, so idle cost is
# nil. A child is re-drained only if it landed in the root cpuset; anything already confined by
# inheritance is skipped. The child comm is deliberately not matched here because at fork time it still
# carries the parent name.
do_forkwatch() {
        detect_files
        [ -d "$BIGSINK" ] || ensure_set "$BIGSINK" "$BIG"
        detect_trace || { log "forkwatch: no tracefs; switching to maintslow"; maintain_slow; return; }
        TINST="$TBASE/instances/dx180"
        if mkdir "$TINST" 2>/dev/null || [ -d "$TINST" ]; then
                EVDIR="$TINST/events/sched/sched_process_fork"; PIPE="$TINST/trace_pipe"
        else
                log "forkwatch: trace instances unsupported; using global buffer"
                EVDIR="$TBASE/events/sched/sched_process_fork"; PIPE="$TBASE/trace_pipe"
                echo 1 > "$TBASE/tracing_on" 2>/dev/null
        fi
        echo 1 > "$EVDIR/enable" 2>/dev/null \
                || { log "forkwatch: cannot enable fork event; switching to maintslow"; maintain_slow; return; }
        log "forkwatch: blocking on $PIPE"
        exec 3< "$PIPE"
        while IFS= read -r line <&3; do
                case "$line" in *child_pid=*) ;; *) continue ;; esac
                c=${line##*child_pid=}; c=${c%% *}
                case "$c" in ''|*[!0-9]*) continue ;; esac
                read -r cs < "/proc/$c/cpuset" 2>/dev/null || continue
                [ "$cs" = "/" ] || continue                 # already confined by inheritance
                cmd=""; read -r cmd < "/proc/$c/cmdline" 2>/dev/null
                [ -n "$cmd" ] || continue                   # kernel thread, not cpuset-movable
                echo "$c" > "$BIGSINK/$TF" 2>/dev/null
        done
}

# Coarse backstop: scans the root cpuset only, at a wide interval. Appropriate when SINK_INIT=1 leaves
# the root cpuset nearly empty and per-fork wakeups are unwarranted.
maintain_slow() {
        detect_files
        [ -d "$BIGSINK" ] || ensure_set "$BIGSINK" "$BIG"
        log "maintslow: root-scan every ${INTERVAL}s"
        while :; do
                sleep "$INTERVAL"
                while read -r tid; do
                        cmd=""; read -r cmd < "/proc/$tid/cmdline" 2>/dev/null
                        [ -n "$cmd" ] && echo "$tid" > "$BIGSINK/$TF" 2>/dev/null
                done < "$CPUSET/$TF"
        done
}

# ---------------------------------------------------------------------------------------------------
# Daemon launch (from boot) and node wait
# ---------------------------------------------------------------------------------------------------

wait_for_node() {
        i=0
        while [ ! -e "$1" ]; do
                i=$((i + 1)); [ "$i" -ge 50 ] && return 1   # ~10 s
                sleep 0.2
        done
}

# Backgrounded launch (prototype). Children reparent to init when boot exits; they do NOT auto-restart
# on death. The production form is a module system/etc/init/*.rc service with a seclabel, where init
# restarts the daemon. pidfiles enable a clean live revert.
launch_daemons() {
        case "$MAINT" in
                slow) "$SELF" maintslow >/dev/null 2>&1 & echo $! > "$STATE_DIR/maint.pid"
                      log "maintslow launched (pid $(cat "$STATE_DIR/maint.pid"))" ;;
                *)    "$SELF" forkwatch >/dev/null 2>&1 & echo $! > "$STATE_DIR/maint.pid"
                      log "forkwatch launched (pid $(cat "$STATE_DIR/maint.pid"))" ;;
        esac
        if wait_for_node "$PCM_NODE"; then
                inotifyd "$SELF" "$PCM_NODE" >/dev/null 2>&1 & echo $! > "$STATE_DIR/inotifyd.pid"
                log "inotifyd watching $PCM_NODE (pid $(cat "$STATE_DIR/inotifyd.pid"))"
        else
                log "PCM node $PCM_NODE absent after timeout; inotifyd not started"
        fi
}

# ---------------------------------------------------------------------------------------------------
# Subcommand: boot (run once from service.sh, after service.bootanim.exit == 1)
# ---------------------------------------------------------------------------------------------------

do_boot() {
        mkdir -p "$STATE_DIR" 2>/dev/null
        rotate_log
        : > "$BAK"                                     # fresh snapshot each boot
        detect_files
        verify_topology
        if [ "$DISABLE_SWEEP" = 1 ]; then
                stop_services
                disable_apps
                stop_apps
        fi
        ensure_set "$BIGSINK"   "$BIG"    || exit 1
        ensure_set "$AUDIO_SET" "$LITTLE" || exit 1
        retarget_tree "$CPUSET"
        drain_root
        sink_init
        cpu_gpu_baseline
        launch_daemons
        log "boot prep complete"
}

# ---------------------------------------------------------------------------------------------------
# Subcommand: revert (live rollback)
# ---------------------------------------------------------------------------------------------------

do_revert() {
        detect_files
        for pf in maint inotifyd; do
                [ -f "$STATE_DIR/$pf.pid" ] || continue
                read -r pp < "$STATE_DIR/$pf.pid"
                kill "$pp" 2>/dev/null && log "killed $pf ($pp)"
                rm -f "$STATE_DIR/$pf.pid"
        done
        for base in /sys/kernel/tracing /sys/kernel/debug/tracing; do
                ti="$base/instances/dx180"
                [ -d "$ti" ] || continue
                echo 0 > "$ti/events/sched/sched_process_fork/enable" 2>/dev/null
                rmdir "$ti" 2>/dev/null && log "removed trace instance"
        done
        if [ -f "$BAK" ]; then
                while read -r p m; do
                        [ -f "$p/$CF" ] && echo "$m" > "$p/$CF" 2>/dev/null
                done < "$BAK"
                rm -f "$BAK"
                log "restored stock cpus from snapshot"
        else
                log "no snapshot; reboot restores stock masks"
        fi
        for s in "$AUDIO_SET" "$BIGSINK"; do
                [ -d "$s" ] || continue
                if [ -f "$s/$TF" ]; then
                        while read -r tid; do echo "$tid" > "$CPUSET/$TF" 2>/dev/null; done < "$s/$TF"
                fi
                rmdir "$s" 2>/dev/null && log "removed ${s##*/}"
        done
        log "revert complete (reboot also restores all runtime sysfs)"
}

usage() { echo "usage: ${0##*/} {boot|pcm|forkwatch|maintslow|revert}"; }

# ---------------------------------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------------------------------

case "$1" in
        boot)      do_boot ;;
        pcm)       do_pcm ;;
        forkwatch) do_forkwatch ;;
        maintslow) maintain_slow ;;
        revert)    do_revert ;;
        *)
                # inotifyd invokes as: <events> <watched-path> <filename>. That signature (a non-empty
                # $2 holding the watched path) is routed to the pcm handler.
                if [ -n "$2" ]; then do_pcm; else usage; fi ;;
esac
