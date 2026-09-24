#!/system/bin/sh
#
# whatcpu.sh — device-wide report of the CPU each thread last executed on, with its allowed mask.
#
# Enumerates every thread of every process. The last-run CPU is the "processor" field of
# /proc/<pid>/task/<tid>/stat. Because the comm field is parenthesized and may contain spaces or
# parentheses, the line is split on the FINAL ")" so the trailing numeric fields align regardless of
# thread-name content; processor is the 37th field of that remainder (stat field 39 minus the leading
# pid and comm). The allowed set is Cpus_allowed_list from status. Output distinguishes what actually
# occupies the little cluster (cpu0-3) from what is merely permitted there.
#
# Invoke as `sh whatcpu.sh` to avoid any shebang/line-ending dependency.
#
# Modes:
#   (default)      per-process tally: little / big / total threads, plus a sample allowed mask
#   MODE=threads   one line per thread: cpu, tid, allowed, thread-comm, process-comm
#   MODE=raw       same as threads, unsorted (cheapest)

MODE="${MODE:-threads}"

emit() {
        for t in /proc/[0-9]*/task/[0-9]*; do
                [ -r "$t/stat" ] || continue
                line=$(cat "$t/stat" 2>/dev/null) || continue
                rest=${line##*) }
                set -- $rest
                cpu=$(eval "echo \${37}")
                case "$cpu" in ''|*[!0-9]*) continue ;; esac
                tid=${t##*/}
                tcomm=$(cat "$t/comm" 2>/dev/null)
                pcomm=$(cat "${t%/task/*}/comm" 2>/dev/null)
                allow=""
                while read -r k v; do
                        [ "$k" = "Cpus_allowed_list:" ] && { allow="$v"; break; }
                done < "$t/status"
                echo "$cpu|$tid|$allow|$tcomm|$pcomm"
        done
}

case "$MODE" in
        threads)
                emit | sort -t'|' -k1,1n | \
                        awk -F'|' '{printf "cpu%s  %-7s  allow=%-5s  %-16s  %s\n",$1,$2,$3,$4,$5}' ;;
        raw)
                emit | awk -F'|' '{printf "cpu%s  %-7s  allow=%-5s  %-16s  %s\n",$1,$2,$3,$4,$5}' ;;
        *)
                emit | awk -F'|' '
                {
                        proc=$5; cpu=$1; allow=$3
                        total[proc]++
                        if (cpu <= 3) little[proc]++; else big[proc]++
                        amask[proc]=allow
                }
                END {
                        printf "%-40s %7s %5s %6s   %s\n","PROCESS","little","big","total","allowed"
                        for (p in total)
                                printf "%-40s %7d %5d %6d   %s\n", p, little[p]+0, big[p]+0, total[p], amask[p]
                }' | sort -k2 -nr ;;
esac
