#!/system/bin/sh
# DX180 Quiet - discovery helper.

echo "=== init services (name : state) ==="
# init.svc.<name> properties enumerate every service init knows, with current state (running/stopped).
getprop | sed -n 's/^\[init\.svc\.\([^]]*\)\]: \[\(.*\)\]$/\1 : \2/p' | sort

echo
echo "=== candidates of interest (grep of the above) ==="
getprop | sed -n 's/^\[init\.svc\.\([^]]*\)\]: \[\(.*\)\]$/\1 : \2/p' | sort | grep -Ei \
    "ims|netmgr|ipacm|dpm|ssgqmi|adpl|port-bridge|rmt|tftp|mlid|tloc|wfd|wifidisplay|traced|statsd|incident|ese|soter|tui|credstore|cdsprpc|qcc-trd|qesdk|neuralnetwork"

echo
echo "=== packages of interest ==="
pm list packages | grep -Ei "tafayor|workloadclassifier|pasr|launcher|pearl"
