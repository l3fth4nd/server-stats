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
# 1. CPU usage
#
# We sample the aggregate "cpu" line of /proc/stat twice, ~1s apart, and
# diff the counters. Each value is "jiffies spent in a state since boot".
# Busy fraction over the interval = (Δtotal - Δidle) / Δtotal.
#
# Why not `top`? `top` reports the same thing but its output format varies
# across versions and locales, and batch mode still needs a sampling delay.
# Reading /proc/stat ourselves is portable and dependency-free.
# ----------------------------------------------------------------------------

read_cpu_counters() {
    # Prints: "<total_jiffies> <idle_jiffies>"
    # Fields: user nice system idle iowait irq softirq steal guest guest_nice
    local _cpu user nice system idle iowait irq softirq steal _rest
    read -r _cpu user nice system idle iowait irq softirq steal _rest < /proc/stat
    local total=$(( user + nice + system + idle + iowait + irq + softirq + steal ))
    local idle_all=$(( idle + iowait ))   # iowait = CPU idle waiting on I/O
    printf '%s %s\n' "$total" "$idle_all"
}

cpu_usage_pct() {
    local t0 i0 t1 i1
    read -r t0 i0 <<< "$(read_cpu_counters)"
    sleep 1
    read -r t1 i1 <<< "$(read_cpu_counters)"

    local dt=$(( t1 - t0 ))
    local di=$(( i1 - i0 ))
    if [ "$dt" -le 0 ]; then echo "0.0"; return; fi
    awk -v dt="$dt" -v di="$di" 'BEGIN { printf "%.1f", (dt - di) / dt * 100 }'
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

    # df's own "Use%" is used/(used+avail), i.e. it ignores root-reserved
    # blocks. We follow that convention so Used%+Free% sum to 100 and reconcile
    # with `df`; Size is shown separately as the raw filesystem total.
    local base=$(( used + avail ))
    printf '  Size  : %s  (filesystem total, incl. reserved)\n' "$(human_kib "$total")"
    printf '  Used  : %s  (%s)\n' "$(human_kib "$used")"  "$(pct "$used"  "$base")"
    printf '  Free  : %s  (%s)\n' "$(human_kib "$avail")" "$(pct "$avail" "$base")"
}

# ----------------------------------------------------------------------------
# 4 & 5. Top processes by CPU / memory  (source: ps)
#
# `ps --sort` does the ranking in-kernel/in-tool; we just take the top 5.
# Caveat worth knowing: ps %cpu is lifetime-average (total CPU time / wall
# time alive), NOT the instantaneous rate `top` shows. A long-lived daemon
# can therefore show a modest %cpu even while spiking right now. For a
# point-in-time snapshot this is the standard, portable answer.
# ----------------------------------------------------------------------------

print_top_cpu() {
    ps -eo pid,user,%cpu,comm --sort=-%cpu 2>/dev/null \
        | awk 'NR==1 {printf "  %-8s %-12s %6s  %s\n", $1,$2,$3,$4; next}
               NR<=6 {printf "  %-8s %-12s %6s  %s\n", $1,$2,$3,$4}'
}

print_top_mem() {
    ps -eo pid,user,%mem,comm --sort=-%mem 2>/dev/null \
        | awk 'NR==1 {printf "  %-8s %-12s %6s  %s\n", $1,$2,$3,$4; next}
               NR<=6 {printf "  %-8s %-12s %6s  %s\n", $1,$2,$3,$4}'
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
            | awk '{printf "    %-12s from %-15s %s %s %s\n", $1,$3,$4,$5,$6}'
    elif command -v journalctl >/dev/null 2>&1; then
        local n
        n=$(journalctl _SYSTEMD_UNIT=sshd.service 2>/dev/null | grep -c "Failed password")
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

    section "CPU usage"
    printf '  Total CPU usage : %s%%\n' "$(cpu_usage_pct)"

    section "Memory usage"
    print_memory

    section "Disk usage (all real filesystems)"
    print_disk

    section "Top 5 processes by CPU"
    print_top_cpu

    section "Top 5 processes by memory"
    print_top_mem

    section "System info (stretch)"
    print_sysinfo

    section "Security (stretch)"
    print_failed_logins

    printf '\n'
}

main "$@"
