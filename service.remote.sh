#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/quiet.log"

KILLED="$MODDIR/reaper.killed"
FLAGGED="$MODDIR/reaper.flagged"

SERVICES='
ims_rtp_daemon
imsqmidaemon
imsrcsd
imsdatadaemon
netmgrd
port-bridge
adpl
dpmd
dpmQmiMgr
ssgqmigd
ipacm
ipacm-diag
vendor.qti.esepowermanager
vendor.qti.hardware.soter
vendor.qti.hardware.tui_comm
neuralnetworks_hal_service
qti_esepowermanager_service_1_1
wfdhdcphalservice
wifidisplayhalservice
update_engine
rmt_storage
tftp_server
wfdvndservice
traced
mlid
tloc_daemon
traced_probes
statsd
incidentd
soter-1-0
tui_comm-1-0
vendor.cdsprpcd
vendor.dataadpl
vendor.ims_rtp_daemon
vendor.imsdatadaemon
vendor.imsrcsservice
vendor.imsqmidaemon
vendor.ipacm
vendor.ipacm-diag
vendor.netmgrd
vendor.port-bridge
vendor.qcc-trd
vendor.rmt_storage
vendor.tftp_server
vendor.tlocd
vendor.media.omx
credstore
cdsprpcd
qcc-trd
vendor.qti.qesdk.sysservice
android.hardware.neuralnetworks
vendor.drm-widevine-hal-1-3
vendor.drm-clearkey-hal-1-3
vendor.keymaster-4-1
vendor.qti.vibrator
sensors.qti
drmserver
media.extractor
media.swcodec
kauditd
logd
'

GOOGLE='
com.android.settings
com.io.github.muntashirakon.AppManager
com.google.android.gms.supervision
com.google.android.gms.location.history
com.google.android.gms
com.android.vending
com.google.android.gsf
com.cxinventor.file.explorer
com.android.documentsui
com.android.location.fused
'

# Log ring: limit to 256KiB
[ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 262144 ] && : > "$LOG"
: > "$FLAGGED"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

stop_if_present() {
	for svc in $SERVICES; do
		state=$(getprop "init.svc.$svc")
		if [ -n "$state" ]; then
			stop "$svc"
			log "stop: $svc (was $state)"
		else
			log "absent: $svc no init.svc entry; resolve name via discover.sh"
		fi
	done
}

while [[ $(getprop service.bootanim.exit) != 1 ]]; do sleep 10; done

stop_if_present

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

setprop persist.log.tag E

cookServ() {
	for svc in $SERVICES; do
		state=$(getprop init.svc."$svc")
		[[ $state == "running" ]] && {
			log "$svc found to be running, stopping it again."
			stop "$svc"
			postState=$(getprop init.svc."$svc")
			log "$svc is now $postState"
		}
	done
}

c=0
fryApps() {
	for app in $GOOGLE; do
		pm disable-until-used "$app"
		log "$app disabled until use."
	done
	c=0
}

darkMode() {
	while true; do
		screenState=$(watch -n 30 getprop debug.tracing.screen_state)
	
		[[ $screenState == 1 ]] && {
			cookServ
			sleep 600
			c=$((c + 1))
		}
		
		[[ $c == 6 ]] && fryApps
	done
}

darkMode
