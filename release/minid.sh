#!/system/bin/sh
SELF=$(readlink -f "$0" 2>/dev/null); [ -n "$SELF" ] || SELF=$0
CPUSET=/dev/cpuset
LITTLE="0-3"
BIG="4-7"
MUSICPKG="app.symfonik.music.player"
AUDIO_SET="$CPUSET/audio"
BIGSINK="$CPUSET/bigsink"
STATE_DIR=/dev/dx180
BAK="$STATE_DIR/part.bak"
LOCKDIR="$STATE_DIR/pcm.lock"
LOG="${LOG:-/data/local/tmp/dx180quiet.log}"
LOG_MAX=262144
CARD="${CARD:-0}"
PCM_NODE="/dev/snd/pcmC0D0p"
HWP="/proc/asound/card${CARD}/pcm0p/sub0/hw_params"
POLICY0=/sys/devices/system/cpu/cpufreq/policy0
FREQ_IDLE=300000
FREQ_IDLE_MAX=614400
FREQ_STD=614400
FREQ_HIRES=864000
FREQ_ULTRA=1017600
GPU_MAX=320
SINK_INIT="${SINK_INIT:-1}"
DISABLE_SWEEP="${DISABLE_SWEEP:-1}"
INCLUDE_AUDIOSERVER="${INCLUDE_AUDIOSERVER:-1}"
MAINT="${MAINT:-fork}"
INTERVAL="${INTERVAL:-60}"
QUIET_LOGD="${QUIET_LOGD:-0}"
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
FREEZEAPPS='
com.google.android.gms.supervision com.google.android.gms.location.history com.google.android.gms
com.google.android.gms.persistent com.google.android.gms.unstable com.android.vending
com.google.android.inputmethod.latin com.qualcomm.qti.workloadclassifer
'
STOPAPPS='
com.android.settings io.github.muntashirakon.AppManager com.google.android.gsf
com.cxinventor.file.explorer com.android.documentsui
'
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }
rotate_log() {
[ -f "$LOG" ] || return 0
sz=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
[ "$sz" -gt "$LOG_MAX" ] && : > "$LOG"
}
detect_files() {
if   [ -f "$CPUSET/cpus" ];        then CF=cpus;        MF=mems;        TF=tasks
elif [ -f "$CPUSET/cpuset.cpus" ]; then CF=cpuset.cpus; MF=cpuset.mems; TF=tasks
else log "no cpuset controller at $CPUSET"; exit 1; fi
}
verify_topology() {
c0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
c4=$(cat /sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_max_freq 2>/dev/null)
[ -n "$c0" ] && [ -n "$c4" ] || { log "topology: cpufreq nodes unreadable; skipping check"; return 0; }
[ "$c0" -lt "$c4" ] || log "topology: WARN cpu0 ceiling ($c0) !< cpu4 ($c4); masks may be inverted"
}
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
if [ -w /sys/kernel/gpu/gpu_max_clock ]; then
echo "$GPU_MAX" > /sys/kernel/gpu/gpu_max_clock 2>/dev/null && log "gpu_max_clock=$GPU_MAX"
fi
[ "$QUIET_LOGD" = 1 ] && setprop persist.log.tag E
log "baseline: little idle ${FREQ_IDLE}/${FREQ_IDLE_MAX}"
}
ensure_set() {
p=$1; c=$2
[ -d "$p" ] || mkdir "$p" 2>/dev/null
[ -d "$p" ] || { log "ensure_set $p: mkdir failed"; return 1; }
read -r pm < "$CPUSET/$MF"
echo "$pm" > "$p/$MF" 2>/dev/null
echo "$c"  > "$p/$CF" 2>/dev/null
log "set ${p##*/} cpus=$c"
}
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
sink_init() {
[ "$SINK_INIT" = 1 ] || return
if [ -f "$BIGSINK/cgroup.procs" ]; then
echo 1 > "$BIGSINK/cgroup.procs" 2>/dev/null && log "init (pid 1) -> bigsink (procs)"
else
echo 1 > "$BIGSINK/$TF" 2>/dev/null && log "init (pid 1) -> bigsink (task)"
fi
}
audio_match() {
case "$1" in
ExoPlayer:Playb*|ExoPlayer:Simp*|AudioTrack*|AudioEngine*) return 0 ;;
*) return 1 ;;
esac
}
audioserver_match() {
case "$1" in
AudioOut*|FastMixer*|writer*) return 0 ;;
*) return 1 ;;
esac
}
is_dsd() {
st=/sys/devices/virtual/codec/codec0/stream_type
[ -r "$st" ] || return 1
read -r v < "$st" 2>/dev/null || return 1
case "$v" in *[Dd][Ss][Dd]*) return 0 ;; *) return 1 ;; esac
}
map_freq() {
r=$1; dsd=$2
[ "$dsd" = 1 ] && { echo "$FREQ_ULTRA"; return; }
[ -n "$r" ] || { echo "$FREQ_STD"; return; }
if   [ "$r" -le 48000 ];  then echo "$FREQ_STD"
elif [ "$r" -le 192000 ]; then echo "$FREQ_HIRES"
else                            echo "$FREQ_ULTRA"; fi
}
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
acquire_lock() {
mkdir -p "$STATE_DIR" 2>/dev/null
i=0
while ! mkdir "$LOCKDIR" 2>/dev/null; do
i=$((i + 1)); [ "$i" -ge 20 ] && break
sleep 0.1
done
trap release_lock EXIT INT TERM
}
release_lock() { rmdir "$LOCKDIR" 2>/dev/null; }
do_pcm() {
detect_files
acquire_lock
read_hw
if [ "$HW_STATE" = open ]; then
dsd=0; is_dsd && dsd=1
f=$(map_freq "$HW_RATE" "$dsd")
move_audio
sleep 0.2
move_audio
set_little_freq "$f" "$f"
log "pcm open rate=${HW_RATE} dsd=${dsd} -> little=${f}"
else
set_little_freq "$FREQ_IDLE" "$FREQ_IDLE_MAX"
log "pcm closed -> little idle ${FREQ_IDLE}/${FREQ_IDLE_MAX}"
fi
release_lock
}
detect_trace() {
for base in /sys/kernel/tracing /sys/kernel/debug/tracing; do
[ -d "$base/events/sched/sched_process_fork" ] && { TBASE=$base; return 0; }
done
return 1
}
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
[ "$cs" = "/" ] || continue
cmd=""; read -r cmd < "/proc/$c/cmdline" 2>/dev/null
[ -n "$cmd" ] || continue
echo "$c" > "$BIGSINK/$TF" 2>/dev/null
done
}
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
wait_for_node() {
i=0
while [ ! -e "$1" ]; do
i=$((i + 1)); [ "$i" -ge 50 ] && return 1
sleep 0.2
done
}
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
do_boot() {
mkdir -p "$STATE_DIR" 2>/dev/null
rotate_log
: > "$BAK"
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
case "$1" in
boot)      do_boot ;;
pcm)       do_pcm ;;
forkwatch) do_forkwatch ;;
maintslow) maintain_slow ;;
revert)    do_revert ;;
*)
if [ -n "$2" ]; then do_pcm; else usage; fi ;;
esac
