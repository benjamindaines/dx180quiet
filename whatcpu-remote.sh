#!/bin/bash

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
log()  { printf '%s[*]%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

BAR_MP="=================== Music Player's Threads =================="
BAR_CFG="============================ Config ========================="
BAR_MT="=================== Pinned Music Threads ===================="
BAR_CPU="======================= All CPU Threads ====================="

DATA_DIR="$HOME/.tmp/dx180/adb"
DX_SCRIPT="whatcpu.sh"
DX_DIR="/data/local/tmp"
MOD_SCRIPT="/data/adb/modules/dx180quiet/dx180quiet.sh"
ADB_PROC="$DX_DIR/$DX_SCRIPT"
TIME="$(date +%s)"
OUT_FILE="$DATA_DIR/whatcpu_$TIME.txt"
REPORT="$DATA_DIR/report_$(basename $OUT_FILE)"
APPID="ik.music.player"
DEVLOG="$DX_DIR/dx180quiet.log"
# Month-day stamps (MM-DD) for today and yesterday. The stamp is a substring of ISO dates (YYYY-MM-DD),
# so a single pattern covers both logcat-style and ISO-style timestamps.
TODAY="$(date +%m-%d)"
YESTERDAY="$(date -d yesterday +%m-%d)"

cleaner() { printf "\n\n%s\n\n" "$1" >> "$REPORT"; }

readarray -t CPUS << EOF
cpu0
cpu1
cpu2
cpu3
cpu4
cpu5
cpu6
cpu7
EOF

readarray -t PROCESSES << EOF
ExoPlayer:Playb
ExoPlayer:Simp
AudioTrack
AudioEngine
AudoOut
writer
EOF

[[ "$(adb devices -l | grep -c DX180)" == 1 ]] || \
	die "cannot connect via adb"

ok "Found DX180 via adb"	
	
mkdir -p "$DATA_DIR"

log "running script..."

adb shell "$ADB_PROC" > "$OUT_FILE"  || die "ADB issue... maybe"

cleaner "$BAR_CFG"
# The module script lives on the device, so the read runs through adb and the device-side su. Host-side variables
# expand inside the outer double quotes; the device shell receives the literal pattern and path.
adb shell "su -c 'grep -C 5 \"${AUDIOHAL_COMM:-audio.service}\" $MOD_SCRIPT'" | tr -d '\r' >> "$REPORT"

i=0
threads() {
	cleaner "$BAR_MT"
	while [ "$i" -lt "${#PROCESSES[@]}" ]; do
		grep "${PROCESSES[$i]}" "$OUT_FILE" >> "$REPORT"
		echo >> "$REPORT"
		echo >> "$REPORT"
		i=$(( i + 1 ))
	done
}
threads || die "Process parsing error"
ok "music threads listed by CPU"

cleaner "$BAR_MP"
grep "$APPID" "$OUT_FILE" >> "$REPORT" || die "died at player parsing"
ok "music player threads listed"

i=0
log "sifting though sample set"
sifting() {
	cleaner "$BAR_CPU"
	while [ "$i" -lt "${#CPUS[@]}" ]; do
		grep "${CPUS[$i]}" "$OUT_FILE" >> "$REPORT"
		echo >> "$REPORT"
		echo >> "$REPORT"
		i=$(( i + 1 ))
	done
} 
sifting || die "CPU parsing error"
ok "listed processes by CPU"

# Append the dx180quiet log entries stamped with yesterday's or today's date. The date filter runs on the host,
# so the device clock is not consulted. A missing log or an empty match is a warning, not a fatal error.
log "pulling $DEVLOG entries for $YESTERDAY and $TODAY"
{
	printf '===== dx180quiet.log (%s, %s) =====\n' "$YESTERDAY" "$TODAY"
	adb shell "cat $DEVLOG" | tr -d '\r' | grep -E "$YESTERDAY|$TODAY"
} >> "$REPORT" \
	&& ok "dx180quiet.log entries appended" \
	|| warn "no dx180quiet.log entries found for $YESTERDAY or $TODAY"

ok ""
log "generated $REPORT"
vim "$REPORT"
ok "bye"

