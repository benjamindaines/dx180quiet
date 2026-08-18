#!/system/bin/sh
# DX180 Quiet - late_start service stage.
#
# Two tiers:
#   Tier 1 - a one-shot batch of init 'stop' plus 'pm disable-user'. A clean 'stop' persists unless the
#            service is re-triggered (class_start or an 'on property:' match), so most entries stay down for
#            the session from this single pass.
#   Tier 2 - a screen-off edge watcher that re-stops only services observed to respawn via property
#            re-trigger. Assuming there will be some things to double and triple kill... we'll see.

MODDIR=${0%/*}
LOG="$MODDIR/quiet.log"

# Log ring: limit to 256KiB
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ] && : > "$LOG"

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


# --- Tier 2: screen-off edge watcher ----------------------------------------------------------------
# Trigger source: debug.tracing.screen_state, set by SurfaceFlinger frame tracing. Display.STATE_OFF = 1,
# ON = 2.

TIER2=""

if [ -z "$(getprop debug.tracing.screen_state)" ]; then
    log "watcher: debug.tracing.screen_state absent; screen-off trigger unavailable, watcher not started"
    exit 0
fi

if [ -z "$TIER2" ]; then
    log "watcher: Tier-2 list empty; watcher not started"
    exit 0
fi

sweep() {
    for svc in $TIER2; do
        [ -n "$(getprop "init.svc.$svc")" ] && stop "$svc"
    done
    log "watcher: screen-off sweep fired"
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
