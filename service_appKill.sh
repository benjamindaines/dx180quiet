#!/system/bin/sh
# DX180 Quiet - late_start service stage.
#
# Two tiers:
#   Tier 1 - a one-shot batch of init 'stop' plus 'pm disable-user'. A clean 'stop' persists unless the
#            service is re-triggered (class_start or an 'on property:' match), so most entries stay down for
#            the session from this single pass.
#   Tier 2 - a screen-off edge watcher that re-stops services observed to respawn via property re-trigger,
#            and (optionally) reaps non-whitelisted applications on each screen-off transition.

MODDIR=${0%/*}
LOG="$MODDIR/quiet.log"

# Reaper state files. reaper.killed holds the most recent screen-off kill set; reaper.flagged holds
# packages already reported as respawners during the current boot (dedupe). flagged is reset at boot so a
# still-misbehaving app re-warns each session.
KILLED="$MODDIR/reaper.killed"
FLAGGED="$MODDIR/reaper.flagged"

# Log ring: limit to 256KiB
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ] && : > "$LOG"
: > "$FLAGGED"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

stop_if_present() {
    svc=$1
    state=$(getprop "init.svc.$svc")
    if [ -n "$state" ]; then
        stop "$svc"
        log "stop: $svc (was $state)"
    else
        log "absent: $svc - no init.svc entry; resolve name via discover.sh"
    fi
}

log "=== boot sweep start ==="

for svc in \
    ims_rtp_daemon imsqmidaemon imsrcsd imsdatadaemon \
    netmgrd port-bridge adpl \
    dpmd dpmQmiMgr ssgqmigd ipacm ipacm-diag \
    vendor.qti.esepowermanager@1.1-service \
    vendor.qti.hardware.soter@1.0-service \
    vendor.qti.hardware.tui_comm@1.0-service-qti \
    neuralnetworks_hal_service \
    qti_esepowermanager_service_1_1 \
    wfdhdcphalservice \
    wifidisplayhalservice \
    update_engine \
    rmt_storage \
    tftp_server \
    wfdvndservice \
    traced \
    mlid \
    tloc_daemon \
    traced_probes \
    statsd \
    incidentd \
	soter-1-0 \
	tui_comm-1-0 \
	vendor.cdsprpcd \
	vendor.dataadpl \
	vendor.ims_rtp_daemon \
	vendor.imsdatadaemon \
	vendor.imsrcsservice \
	vendor.imsqmidaemon \
	vendor.ipacm \
	vendor.ipacm-diag \
	vendor.netmgrd \
	vendor.port-bridge \
	vendor.qcc-trd \
	vendor.rmt_storage \
	vendor.tftp_server \
	vendor.tlocd \
    credstore \
    cdsprpcd qcc-trd \
    vendor.qti.qesdk.sysservice \
    android.hardware.neuralnetworks@1.3-service-qti \
    vendor.drm-widevine-hal-1-3 \
    vendor.drm-clearkey-hal-1-3 \
    vendor.keymaster-4-1 \
    vendor.qti.vibrator
do
    stop_if_present "$svc"
done

pm disable --user 0 com.tafayor.killall \
    && log "disabled pkg: com.tafayor.killall" \
    || log "pm miss: com.tafayor.killall"
    
pm disable --user 0 com.qualcomm.qti.workloadclassifier \
    && log "disabled pkg: com.qualcomm.qti.workloadclassifier" \
    || log "pm miss: com.qualcomm.qti.workloadclassifier"

pm disable --user 0 com.qti.pasrservice \
    && log "disabled pkg: com.qti.pasrservice" \
    || log "pm miss: com.qti.pasrservice"
    

log "=== boot sweep complete ==="

# --- CPU Scaling ------------------------------------------------------------------------------------
# Seems as good a place as any to squeeze these in. Tier 1 is complete, but before the loop.

echo 'conservative' > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
echo 'conservative' > /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor
echo 'conservative' > /sys/devices/system/cpu/cpu2/cpufreq/scaling_governor
echo 'conservative' > /sys/devices/system/cpu/cpu3/cpufreq/scaling_governor

echo 'conservative' > /sys/devices/system/cpu/cpu4/cpufreq/scaling_governor
echo 'conservative' > /sys/devices/system/cpu/cpu5/cpufreq/scaling_governor
echo 'conservative' > /sys/devices/system/cpu/cpu6/cpufreq/scaling_governor
echo 'conservative' > /sys/devices/system/cpu/cpu7/cpufreq/scaling_governor

echo '300000' > /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq
echo '300000' > /sys/devices/system/cpu/cpu1/cpufreq/scaling_min_freq
echo '300000' > /sys/devices/system/cpu/cpu2/cpufreq/scaling_min_freq
echo '300000' > /sys/devices/system/cpu/cpu3/cpufreq/scaling_min_freq

echo '300000' > /sys/devices/system/cpu/cpu4/cpufreq/scaling_min_freq
echo '300000' > /sys/devices/system/cpu/cpu5/cpufreq/scaling_min_freq
echo '300000' > /sys/devices/system/cpu/cpu6/cpufreq/scaling_min_freq
echo '300000' > /sys/devices/system/cpu/cpu7/cpufreq/scaling_min_freq


log "=== CPU scaling set ======="


# --- Tier 2: configuration --------------------------------------------------------------------------
# TIER2: services to re-stop on screen-off (respawners). Space/newline-delimited init service names.
# APPKILL: 1 enables the screen-off application reaper; 0 disables it. Independent of TIER2.
# APP_SCOPE: package scope for the reaper. '-3' restricts to third-party packages, which structurally
#   excludes the system UI surface (SystemUI, system launcher, AOSP IME) as those are platform apps.
#   Clearing it (APP_SCOPE="") widens to all packages, which then requires the system UI surface to be
#   present in WHITELIST or it is force-stopped on screen-off.
# RESPAWN_GRACE: seconds after force-stop before the immediate respawn check.
# WHITELIST: packages exempt from the reaper. Matched whole. Newline- or space-delimited.
TIER2=""
APPKILL=1
APP_SCOPE="-3"
RESPAWN_GRACE=5
WHITELIST="
app.symfonik.music.player
"
#com.topjohnwu.magisk
#io.github.muntashirakon.AppManager
#com.pearlauncher.pearlauncher
#"

# --- Tier 2: reaper helpers -------------------------------------------------------------------------
# in_whitelist: whole-token match against WHITELIST. The command substitution collapses newlines to spaces
# so the case glob matches regardless of delimiter.
in_whitelist() {
    case " $(echo $WHITELIST) " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# is_running: true when a process exists whose name equals the package or begins "package:" (accounts for
# multi-process apps). Regex metacharacters in the package name are escaped.
is_running() {
    rp=$(printf '%s' "$1" | sed 's/[.[]/\\&/g')
    ps -Ao NAME 2>/dev/null | grep -qE "^$rp(:|$)"
}

already_flagged() { [ -f "$FLAGGED" ] && grep -qxF "$1" "$FLAGGED"; }

# flag_respawn: records a respawn once per boot with a standing recommendation. A force-stopped app carries
# the stopped-state flag, so a restart implies a persistent process or an external restart source; such an
# app will not stay down under this mechanism.
flag_respawn() {
    if ! already_flagged "$1"; then
        log "respawn: $1 restarted $2; recommend disabling, removing, or adding to WHITELIST"
        echo "$1" >> "$FLAGGED"
    fi
}

# app_reap: force-stops running, non-whitelisted, in-scope packages, and reports respawns.
#   Phase 1 - packages from the prior sweep now running again (restarted during the awake interval).
#   Phase 2 - force-stop the current running, non-whitelisted set; record it.
#   Phase 3 - after a grace window, report any of that set already back (instant restarters).
app_reap() {
    if [ -f "$KILLED" ]; then
        while IFS= read -r pkg; do
            [ -n "$pkg" ] && is_running "$pkg" && flag_respawn "$pkg" "since the previous sweep"
        done < "$KILLED"
    fi

    : > "$KILLED.tmp"
    for pkg in $(pm list packages $APP_SCOPE 2>/dev/null | sed 's/^package://'); do
        in_whitelist "$pkg" && continue
        is_running "$pkg" || continue
        am force-stop --user 0 "$pkg" 2>/dev/null && log "force-stop: $pkg"
        echo "$pkg" >> "$KILLED.tmp"
    done
    mv "$KILLED.tmp" "$KILLED"

    [ -s "$KILLED" ] || return 0
    sleep "$RESPAWN_GRACE"
    while IFS= read -r pkg; do
        [ -n "$pkg" ] && is_running "$pkg" && flag_respawn "$pkg" "within ${RESPAWN_GRACE}s of force-stop"
    done < "$KILLED"
}

# --- Tier 2: screen-off edge watcher ----------------------------------------------------------------
# Trigger source: debug.tracing.screen_state, set by SurfaceFlinger frame tracing. Display.STATE_OFF = 1,
# ON = 2.

if [ -z "$(getprop debug.tracing.screen_state)" ]; then
    log "watcher: debug.tracing.screen_state absent; screen-off trigger unavailable, watcher not started"
    exit 0
fi

if [ -z "$TIER2" ] && [ "$APPKILL" != "1" ]; then
    log "watcher: Tier-2 empty and app reaper disabled; watcher not started"
    exit 0
fi

sweep() {
    for svc in $TIER2; do
        [ -n "$(getprop "init.svc.$svc")" ] && stop "$svc"
    done
    [ -n "$TIER2" ] && log "watcher: service sweep fired"
    [ "$APPKILL" = "1" ] && app_reap
}

log "watcher: starting screen-off edge trigger"
(
    prev=$(getprop debug.tracing.screen_state)
    while :; do
        t0=$(date +%s)
        cur=$(getprop -w debug.tracing.screen_state 2>/dev/null)
        t1=$(date +%s)
        [ -z "$cur" ] && cur=$(getprop debug.tracing.screen_state)
        # Non-blocking -w detection: an immediate return with an unchanged value indicates the wait form is
        # unsupported; degrade to a poll interval and re-read.
        if [ "$cur" = "$prev" ] && [ $((t1 - t0)) -lt 2 ]; then
            sleep 10
            cur=$(getprop debug.tracing.screen_state)
        fi
        if [ "$cur" = "1" ] && [ "$prev" != "1" ]; then
            sweep
        fi
        prev=$cur
    done
) &
