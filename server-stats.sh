#!/usr/bin/env bash
#
# server-stats.sh — basic Linux server performance analyzer
#
# Reports core health metrics (CPU, memory, disk, top processes) plus an
# optional system-info section (OS, uptime, load, sessions, failed logins).
#
# Design principle: prefer /proc and POSIX-flavored coreutils over
# distro-specific tooling so the script runs unmodified on most Linux boxes
# (Debian/Ubuntu, RHEL/Fedora, Alpine-with-bash, Arch, ...).
#
# Usage:  ./server-stats.sh
#         sudo ./server-stats.sh   # needed for the failed-login section
#
# Notes:
#   - We deliberately avoid `set -e`/`-o pipefail`. This is a reporting
#     script: a `ps | head` that triggers SIGPIPE, or a missing log file,
#     is benign and must not abort the whole run. We use `set -u` to catch
#     genuine typos in variable names.

set -u

# ----------------------------------------------------------------------------
# Presentation helpers
# ----------------------------------------------------------------------------

# Color only when stdout is an interactive terminal; piping to a file stays clean.
if [ -t 1 ]; then
    BOLD=$(tput bold 2>/dev/null || printf '')
    DIM=$(tput dim 2>/dev/null || printf '')
    RESET=$(tput sgr0 2>/dev/null || printf '')
else
    BOLD='' DIM='' RESET=''
fi

section() {
    printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$RESET"
}

# Render a value in KiB as a human-readable size (KiB/MiB/GiB).
human_kib() {
    awk -v k="$1" 'BEGIN {
        if      (k >= 1048576) printf "%.1f GiB", k/1048576
        else if (k >= 1024)    printf "%.1f MiB", k/1024
        else                   printf "%d KiB",  k
    }'
}

# Render a fraction (used,total) as a "NN.N%" string.
pct() {
    awk -v a="$1" -v b="$2" 'BEGIN { if (b>0) printf "%.1f%%", a/b*100; else printf "n/a" }'
}

# ----------------------------------------------------------------------------
# 1. CPU usage — sampled over one shared 1-second window
#
# _take_cpu_snapshot reads /proc/stat (aggregate) and every /proc/[pid]/stat
# (per-process utime+stime) in a single pass. Calling it twice with sleep 1
# between lets us compute both overall CPU% and instantaneous per-process
# CPU% from the same interval — one sleep total, not two.
# ----------------------------------------------------------------------------

_take_cpu_snapshot() {
    awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print "SYS",t,$5+$6}' /proc/stat
    for f in /proc/[0-9]*/stat; do
        [ -r "$f" ] || continue
        awk 'NR==1{
            match($0,/\(.*\)/)
            rest=substr($0,RSTART+RLENGTH+2)
            split(rest,a," ")
            if(length(a)>=13) printf "PID %s %d\n",$1,a[12]+a[13]
        }' "$f" 2>/dev/null
    done
}

# Prints two kinds of lines (consumed by main):
#   overall <pct>
#   proc <pid> <pct>   (top 5, descending)
cpu_and_top_procs() {
    local s0 s1
    s0=$(_take_cpu_snapshot)
    sleep 1
    s1=$(_take_cpu_snapshot)

    local t0 i0 t1 i1
    read -r _ t0 i0 <<< "$(grep '^SYS' <<< "$s0")"
    read -r _ t1 i1 <<< "$(grep '^SYS' <<< "$s1")"
    local dt=$(( t1 - t0 ))
    [ "$dt" -le 0 ] && dt=1

    printf 'overall %s\n' "$(awk -v dt="$dt" -v di="$(( i1 - i0 ))" \
        'BEGIN{printf "%.1f",(dt-di)/dt*100}')"

    awk -v dt="$dt" '
        NR==FNR && /^PID/ { t[$2]=$3; next }
        /^PID/ {
            pid=$2; delta=$3-(t[pid]+0)
            if (pid in t && delta>0) printf "%.4f %s\n", delta/dt*100, pid
        }
    ' <(printf '%s\n' "$s0") <(printf '%s\n' "$s1") \
        | sort -rn | head -5 | awk '{printf "proc %s %.1f\n",$2,$1}'
}

# ----------------------------------------------------------------------------
# 2. Memory usage  (source: /proc/meminfo, values in kB)
#
# "Used" = MemTotal - MemAvailable. MemAvailable is the kernel's own estimate
# of memory available for new workloads WITHOUT swapping — it already accounts
# for reclaimable page cache. This matches `free`'s "available" column and is
# far more honest than MemTotal - MemFree, which would count the (reclaimable)
# page cache as "used" and make a healthy server look nearly full.
# ----------------------------------------------------------------------------

print_memory() {
    local total avail
    total=$(awk '/^MemTotal:/     {print $2; exit}' /proc/meminfo)
    avail=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)

    # Fallback for kernels < 3.14 that lack MemAvailable.
    if [ -z "${avail:-}" ]; then
        local free buffers cached
        free=$(awk    '/^MemFree:/  {print $2; exit}' /proc/meminfo)
        buffers=$(awk '/^Buffers:/  {print $2; exit}' /proc/meminfo)
        cached=$(awk  '/^Cached:/   {print $2; exit}' /proc/meminfo)
        avail=$(( free + buffers + cached ))
    fi

    local used=$(( total - avail ))
    printf '  Total : %s\n'            "$(human_kib "$total")"
    printf '  Used  : %s  (%s)\n'      "$(human_kib "$used")"  "$(pct "$used"  "$total")"
    printf '  Free  : %s  (%s)\n'      "$(human_kib "$avail")" "$(pct "$avail" "$total")"

    local swap_total swap_free swap_used
    swap_total=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo)
    swap_free=$(awk  '/^SwapFree:/  {print $2; exit}' /proc/meminfo)
    if [ -n "${swap_total:-}" ] && [ "$swap_total" -gt 0 ]; then
        swap_used=$(( swap_total - swap_free ))
        printf '  Swap  : %s used / %s total  (%s)\n' \
            "$(human_kib "$swap_used")" "$(human_kib "$swap_total")" "$(pct "$swap_used" "$swap_total")"
    fi
}

# ----------------------------------------------------------------------------
# 3. Disk usage  (source: df)
#
# "Disk" here means local, on-disk storage. We use an ALLOWLIST of real
# filesystem types rather than a denylist of pseudo ones. A denylist is
# brittle: new virtual/network types (overlay, fuse.rclone, nfs4, ...) keep
# appearing and would silently inflate the totals. An allowlist of block-backed
# types (ext*, xfs, btrfs, ...) is precise and also excludes network mounts,
# at the documented cost of showing 0 on exotic setups (e.g. an overlay root).
# `df -PTk`: -P = stable POSIX one-line format, -T = print type, -k = KiB blocks.
# ----------------------------------------------------------------------------

print_disk() {
    # Pull the three aggregates (in KiB) into shell vars so we can reuse
    # human_kib/pct for consistent formatting.
    local total used avail
    read -r total used avail < <(
        df -PTk 2>/dev/null | awk '
            NR > 1 && $2 ~ /^(ext[2-4]|xfs|btrfs|zfs|f2fs|jfs|reiserfs|vfat|exfat|ntfs3?|fuseblk|ufs|hfsplus)$/ {
                t += $3; u += $4; a += $5
            }
            END { printf "%d %d %d\n", t, u, a }
        '
    )

    if [ "${total:-0}" -eq 0 ]; then
        printf '  (no standard block filesystem detected — overlay/exotic root?)\n'
        return
    fi

    # df's own "Use%" is used/(used+avail), i.e. it ignores root-reserved
    # blocks. We follow that convention so Used%+Free% sum to 100 and reconcile
    # with `df`; Size is shown separately as the raw filesystem total.
    local base=$(( used + avail ))
    printf '  Size  : %s  (filesystem total, incl. reserved)\n' "$(human_kib "$total")"
    printf '  Used  : %s  (%s)\n' "$(human_kib "$used")"  "$(pct "$used"  "$base")"
    printf '  Free  : %s  (%s)\n' "$(human_kib "$avail")" "$(pct "$avail" "$base")"

    local itotal iused iavail
    read -r itotal iused iavail < <(
        df -PTi 2>/dev/null | awk '
            NR > 1 && $2 ~ /^(ext[2-4]|xfs|btrfs|zfs|f2fs|jfs|reiserfs|vfat|exfat|ntfs3?|fuseblk|ufs|hfsplus)$/ {
                t += $3; u += $4; a += $5
            }
            END { printf "%d %d %d\n", t, u, a }
        '
    )
    if [ "${itotal:-0}" -gt 0 ]; then
        printf '  Inodes: %d used / %d total  (%s)\n' "$iused" "$itotal" "$(pct "$iused" "$itotal")"
    fi
}

# ----------------------------------------------------------------------------
# 4 & 5. Top processes by CPU (instantaneous) / memory
# ----------------------------------------------------------------------------

print_top_cpu() {
    local cpu_data="$1"
    printf '  %-8s %-16s %6s  %s\n' "PID" "USER" "%CPU" "COMMAND"
    while IFS=' ' read -r _ pid pct; do
        local info user comm
        info=$(ps -p "$pid" -o user:16=,comm= 2>/dev/null | head -1) || continue
        [ -z "$info" ] && continue
        user=$(awk '{print $1}' <<< "$info")
        comm=$(awk '{print $2}' <<< "$info")
        printf '  %-8s %-16s %6s  %s\n' "$pid" "$user" "$pct" "$comm"
    done < <(grep '^proc ' <<< "$cpu_data")
}

print_top_cpu_lifetime() {
    ps -eo pid,user:16,%cpu,comm --sort=-%cpu 2>/dev/null \
        | awk 'NR==1 {printf "  %-8s %-16s %6s  %s\n", $1,$2,$3,$4; next}
               NR<=6 {printf "  %-8s %-16s %6s  %s\n", $1,$2,$3,$4}'
}

print_top_mem() {
    ps -eo pid,user:16,%mem,comm --sort=-%mem 2>/dev/null \
        | awk 'NR==1 {printf "  %-8s %-16s %6s  %s\n", $1,$2,$3,$4; next}
               NR<=6 {printf "  %-8s %-16s %6s  %s\n", $1,$2,$3,$4}'
}

# ----------------------------------------------------------------------------
# Stretch goal: general system info
# ----------------------------------------------------------------------------

print_sysinfo() {
    # OS pretty name
    local os="unknown"
    [ -r /etc/os-release ] && os=$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)
    printf '  OS         : %s\n' "$os"
    printf '  Kernel     : %s\n' "$(uname -r)"
    printf '  Hostname   : %s\n' "$(cat /proc/sys/kernel/hostname 2>/dev/null || hostname)"

    # Uptime from /proc/uptime (seconds since boot, first field).
    local up_s
    up_s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
    if [ -n "${up_s:-}" ]; then
        local d=$(( up_s/86400 )) h=$(( (up_s%86400)/3600 )) m=$(( (up_s%3600)/60 ))
        printf '  Uptime     : %dd %dh %dm\n' "$d" "$h" "$m"
    fi

    # Load average: 1 / 5 / 15 minute run-queue averages.
    local l1 l5 l15
    read -r l1 l5 l15 _ < /proc/loadavg
    local ncpu
    ncpu=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)
    printf '  Load avg   : %s, %s, %s   (cores: %s)\n' "$l1" "$l5" "$l15" "$ncpu"

    # Logged-in sessions.
    local users
    users=$(who 2>/dev/null | wc -l)
    printf '  Sessions   : %s logged-in user session(s)\n' "$users"
    who 2>/dev/null | awk '{printf "               %-12s %-8s %s %s\n", $1,$2,$3,$4}'
}

# Failed logins need access to /var/log/btmp (root). Try lastb, then journald.
print_failed_logins() {
    if command -v lastb >/dev/null 2>&1 && lastb >/dev/null 2>&1; then
        local n
        n=$(lastb 2>/dev/null | grep -cve '^$' -e '^btmp begins')
        printf '  Failed login attempts (recent): %s\n' "$n"
        lastb 2>/dev/null | grep -v -e '^$' -e '^btmp begins' | head -5 \
            | awk '{printf "    %s\n", $0}'
    elif command -v journalctl >/dev/null 2>&1; then
        local n
        n=$(journalctl -b _SYSTEMD_UNIT=sshd.service 2>/dev/null | grep -c "Failed password")
        printf '  Failed SSH password attempts (journal): %s\n' "$n"
    else
        printf '  Failed login data unavailable (need root / no btmp / no journald)\n'
    fi
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------

main() {
    printf '%sServer performance report%s  —  %s\n' "$BOLD" "$RESET" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

    local _cpu
    _cpu=$(cpu_and_top_procs)

    section "CPU usage"
    printf '  Total CPU usage : %s%%\n' "$(awk '/^overall/{print $2}' <<< "$_cpu")"

    section "Memory usage"
    print_memory

    section "Disk usage (all real filesystems)"
    print_disk

    section "Top 5 processes by CPU"
    print_top_cpu "$_cpu"

    section "Top 5 processes by CPU (lifetime avg)"
    print_top_cpu_lifetime

    section "Top 5 processes by memory"
    print_top_mem

    section "System info (stretch)"
    print_sysinfo

    section "Security (stretch)"
    print_failed_logins

    printf '\n'
}

main "$@"
