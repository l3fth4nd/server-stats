# server-stats.sh — Linux Server Performance Analyzer

A single Bash script that reports the core health metrics of any Linux server:
CPU, memory, disk, and the heaviest processes, plus an optional system/security
section. This document explains every step — not just *what* each command does,
but *why* that approach was chosen, the tradeoffs involved, and the subtle
correctness traps that bite people who write this kind of script casually.

---

## 1. What it produces

```
Server performance report  —  2026-06-03 13:45:10 UTC

== CPU usage ==
  Total CPU usage : 2.0%

== Memory usage ==
  Total : 3.9 GiB
  Used  : 221.3 MiB  (5.5%)
  Free  : 3.7 GiB  (94.5%)

== Disk usage (all real filesystems) ==
  Size  : 252.0 GiB  (filesystem total, incl. reserved)
  Used  : 8.5 GiB  (46.1%)
  Free  : 10.0 GiB  (53.9%)

== Top 5 processes by CPU ==      ... PID / USER / %CPU / COMMAND
== Top 5 processes by memory ==   ... PID / USER / %MEM / COMMAND
== System info (stretch) ==       OS, kernel, hostname, uptime, load, sessions
== Security (stretch) ==          failed login attempts
```

## 2. Running it

```bash
chmod +x server-stats.sh
./server-stats.sh              # CPU/mem/disk/process sections work as any user
sudo ./server-stats.sh         # also unlocks the failed-login section (reads /var/log/btmp)
./server-stats.sh > report.txt # piping disables color automatically (see §4)
```

There is a built-in ~1 second pause: measuring CPU usage *requires* sampling over
an interval (explained in §5.1), so the script is never instantaneous by design.

---

## 3. Design philosophy

Three decisions drive the whole script.

**3.1 Read `/proc`, not other tools, wherever possible.**
`/proc` is the kernel's own data interface. Files like `/proc/stat`,
`/proc/meminfo`, `/proc/loadavg`, and `/proc/uptime` exist on every Linux system
and their formats are stable kernel ABIs. By contrast, the human-facing output of
`top`, `free`, and friends varies across versions, locales, and distros, and is
meant for eyes, not parsing. Parsing `/proc` ourselves is more portable and has
zero surprising dependencies. We only shell out to `df` and `ps` where reading
`/proc` directly (`/proc/<pid>/*`, `/proc/mounts` + `statvfs`) would mean
reimplementing a lot of bookkeeping for no real gain.

**3.2 Allowlist over denylist for "real" things.**
When deciding which filesystems count as "disk," an allowlist of known on-disk
types (`ext4`, `xfs`, …) is used rather than a denylist of pseudo types
(`tmpfs`, `overlay`, …). A denylist silently breaks the day a new virtual or
network filesystem type shows up; an allowlist fails safe. See §5.3 — this was a
real bug caught during testing.

**3.3 No `set -e` / `set -o pipefail`; yes `set -u`.**
A reporting script must not abort because `ps | head` closed a pipe early
(SIGPIPE → non-zero exit) or because `/var/log/btmp` doesn't exist. Those are
expected, benign conditions. `set -e`/`pipefail` would turn them into fatal
errors. `set -u` is kept because an *unset variable* is almost always a genuine
typo, and catching it early is worth it.

---

## 4. Output plumbing (color + formatting helpers)

```bash
if [ -t 1 ]; then BOLD=$(tput bold) ... ; else BOLD='' ... ; fi
```

`[ -t 1 ]` tests whether stdout is a terminal. If you redirect to a file or pipe,
the test fails and all color codes become empty strings — so `report.txt` stays
clean instead of being littered with escape sequences. `tput` is used instead of
hard-coded ANSI codes because it consults the terminal's capabilities via
terminfo (graceful when the terminal doesn't support an attribute).

`human_kib()` converts a KiB figure to GiB/MiB/KiB, and `pct()` formats a
fraction as a percentage. Both delegate the float math to `awk` because Bash has
no native floating-point arithmetic — Bash `$(( ))` is integer-only. `awk` is on
every POSIX system, so this stays portable. (`bc` would also work but is less
universally installed than `awk`.)

---

## 5. The metrics, one by one

### 5.1 CPU usage — `/proc/stat`, sampled twice

The first line of `/proc/stat` is cumulative CPU time *since boot*, in USER_HZ
"jiffies," split across states:

```
cpu  user nice system idle iowait irq softirq steal guest guest_nice
```

A single reading tells you nothing about *current* load — it's a lifetime
counter. The only way to get a usage *rate* is to take two snapshots a known
interval apart and diff them:

```
busy_fraction = (Δtotal − Δidle) / Δtotal
```

where `total` is the sum of all states and `idle` counts both `idle` and
`iowait` (the CPU is idle while waiting on disk/network I/O).

- **How:** `read_cpu_counters` sums the fields and returns `total idle`. The main
  function samples, `sleep 1`, samples again, and `awk` computes the percentage.
- **Why this over `top`:** `top -bn1`'s first sample is also since-boot and thus
  meaningless; you'd need `top -bn2` and to parse a locale-dependent line. Doing
  the diff ourselves is simpler and deterministic.
- **Tradeoff:** the 1-second window is a deliberate accuracy/latency choice. A
  shorter window is noisier; a longer one smooths over short spikes. One second
  is the conventional sweet spot.
- **Gotcha:** `steal` time (cycles the hypervisor gave to *other* VMs) is
  included in `total` but not `idle`, so on a noisy-neighbor VM high steal will
  correctly show up as the CPU being unavailable to you.

### 5.2 Memory usage — `/proc/meminfo`

```bash
used = MemTotal − MemAvailable
```

This is the single most important subtlety in the whole script. The naive
formula `MemTotal − MemFree` is **wrong** for judging health: Linux deliberately
fills otherwise-idle RAM with page cache (cached file data) to speed up I/O. That
cache is instantly reclaimable, so counting it as "used" makes a perfectly
healthy server look like it's about to run out of memory.

`MemAvailable` is the kernel's *own* estimate of how much memory a new workload
could claim without swapping — it already credits back the reclaimable cache.
Using it matches the "available" column of modern `free` and reflects reality.

- **Fallback:** kernels older than 3.14 lack `MemAvailable`; the script
  approximates it as `MemFree + Buffers + Cached`.
- **Practical implication:** if `Used` here is genuinely high *and* climbing,
  that's real memory pressure worth investigating — not just a full page cache.

### 5.3 Disk usage — `df`, allowlisted filesystem types

```bash
df -PTk | awk '$2 ~ /^(ext[2-4]|xfs|btrfs|zfs|f2fs|…|fuseblk)$/ { t+=$3; u+=$4; a+=$5 }'
```

- `-P` forces the POSIX one-line-per-filesystem layout, so a long device name
  can't wrap onto a second line and break column parsing.
- `-T` prints the filesystem **type**, which is what we filter on.
- `-k` forces 1024-byte (KiB) blocks so columns are in consistent units.

**Why an allowlist (and the bug it fixed):** during testing the totals came out
as *4.1 million GiB*. The cause: FUSE network mounts (an `rclone` remote) each
advertised a 1 PiB size, and a denylist of pseudo types didn't know about them.
Switching to an allowlist of genuine block-backed filesystem types fixed it and
also correctly excludes network mounts (NFS/CIFS/sshfs), which aren't local disk.

- **Tradeoff:** on an unusual host whose root sits on `overlay` (some container
  setups), the allowlist reports 0. That's an accepted, documented limitation —
  the brief targets normal servers where root is ext4/xfs/btrfs.

**Why the percentage uses `used/(used+avail)`, not `used/total`:** ext-family
filesystems reserve ~5% of blocks for root, so `Size` (the raw filesystem total)
is larger than `Used + Free`. `df`'s own `Use%` column ignores reserved blocks
and reports `used/(used+avail)`. The script matches that convention so its
percentages (a) sum to 100 and (b) reconcile with what `df -h` shows. `Size` is
printed separately as the raw total for transparency.

### 5.4 & 5.5 Top processes by CPU / memory — `ps --sort`

```bash
ps -eo pid,user,%cpu,comm --sort=-%cpu | head -6   # header + 5
ps -eo pid,user,%mem,comm --sort=-%mem | head -6
```

`ps` does the ranking; `--sort=-%cpu` (leading `-` = descending) plus taking the
first five gives the top consumers. `comm` (the executable name) is used instead
of `args` (full command line) to keep columns readable — swap to `args` if you
need to disambiguate, say, three `python` processes.

- **Important gotcha — `ps %cpu` is not `top`'s `%CPU`.** `ps` reports a
  *lifetime average*: total CPU time consumed ÷ wall-clock time the process has
  been alive. A long-running daemon that spikes hard right now can still show a
  low `%cpu`, because the spike is averaged over hours of mostly-idle life.
  `top`/`htop` show an *instantaneous* rate. For a point-in-time snapshot script,
  the `ps` average is the standard, portable answer — just know what it means.
- **`%mem`** is resident set size as a fraction of physical RAM, which is the
  intuitive "how much memory is this eating" number.

---

## 6. Stretch goals

| Metric | Source | Notes |
|---|---|---|
| OS version | `/etc/os-release` → `PRETTY_NAME` | The freedesktop standard; present on essentially all modern distros. |
| Kernel | `uname -r` | — |
| Uptime | `/proc/uptime` (field 1 = seconds since boot) | Parsed into days/hours/minutes in pure Bash integer math. |
| Load average | `/proc/loadavg` (1/5/15-min) | Shown alongside core count (`nproc`) — load only means something *relative to cores*: load 4 is saturated on 4 cores, comfortable on 16. |
| Sessions | `who` | Count + per-session detail. |
| Failed logins | `lastb` (then `journalctl` fallback) | Needs root to read `/var/log/btmp`; degrades gracefully when unavailable. |

**Reading load average correctly:** the three numbers are the average number of
processes in the run queue over 1/5/15 minutes. Comparing the three tells you the
*trend*: `1-min ≫ 15-min` means load is spiking now; `1-min ≪ 15-min` means a
past spike is subsiding. Always divide by core count to judge saturation.

---

## 7. How to extend it

- **Network throughput:** diff `/proc/net/dev` RX/TX byte counters over the same
  1s window already used for CPU.
- **Per-mount disk breakdown:** print each allowlisted `df` row instead of only
  the aggregate.
- **Swap usage:** `SwapTotal`/`SwapFree` from `/proc/meminfo` — sustained swap-in
  is a strong real-memory-pressure signal that pairs well with §5.2.
- **JSON output mode:** add a `--json` flag and emit machine-readable output for
  ingestion by a monitoring agent. This is the natural bridge from a manual
  debug script toward something Prometheus's `node_exporter` does continuously.

---

## 8. Where this sits in the bigger picture

This script is the manual, run-it-when-something-feels-wrong version of what
production monitoring (Prometheus `node_exporter`, Netdata, `glances`) does on a
schedule and stores as time series. Writing it by hand is worthwhile precisely
because it forces you to confront the semantics those tools hide: that CPU usage
is a rate requiring two samples, that "used memory" is a judgment call about page
cache, and that "disk usage percent" depends on whether you count reserved
blocks. Understanding those three things is most of what separates reading a
dashboard from actually trusting it.
