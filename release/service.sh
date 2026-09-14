#!/system/bin/sh

MODDIR=${0%/*}
LOG="$MODDIR/quiet.log"

while [[ $(getprop service.bootanim.exit) != 1 ]]; do sleep 10; done
/system/bin/sh minid.sh boot
