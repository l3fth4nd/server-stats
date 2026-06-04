# server-stats

A single, dependency-free Bash script that reports the core performance metrics
of any Linux server: CPU, memory, disk, and the heaviest processes — plus an
optional system/security section. Built to run unmodified across mainstream
distros by reading the kernel's own `/proc` interface instead of parsing the
human-facing output of `top`/`free`.

![shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnubash&logoColor=white)
![platform](https://img.shields.io/badge/platform-Linux-FCC624?logo=linux&logoColor=black)
![license](https://img.shields.io/badge/license-MIT-blue)

## Features

- **CPU usage** — true interval-sampled rate from `/proc/stat`, not a meaningless since-boot snapshot
- **Top 5 processes by CPU (instantaneous)** — sampled from `/proc/[pid]/stat` over the same 1-second window as overall CPU%, so a long-lived idle process doesn't hide a current spike
- **Top 5 processes by CPU (lifetime avg)** — the classic `ps`-based ranking alongside instantaneous, for comparison
- **Memory usage** — used/free with swap, based on `MemAvailable` so reclaimable page cache isn't miscounted as "used"
- **Disk usage** — space and inode consumption across real (block-backed) filesystems; catches "disk full" from exhausted inodes as well as exhausted space
- **Top 5 processes by memory**
- **Stretch:** OS version, kernel, hostname, uptime, load average (vs. core count), logged-in sessions, failed login attempts (current boot only)

No external dependencies beyond standard coreutils (`awk`, `ps`, `df`, `who`) — no Python, no extra packages.

## Requirements

- A Linux system with a mounted `/proc` (i.e. essentially any Linux server)
- `bash` 4+
- Standard tooling: `awk`, `ps`, `df`, `who`, `uname`
- `root` (via `sudo`) only for the failed-login section, which reads `/var/log/btmp`

## Installation

```bash
git clone https://github.com/l3fth4nd/server-stats.git
cd server-stats
chmod +x server-stats.sh
```

## Usage

```bash
./server-stats.sh                 # run as any user
sudo ./server-stats.sh            # also collect failed-login stats
./server-stats.sh > report.txt    # color auto-disables when output isn't a terminal
```

The script pauses for ~1 second by design: measuring a CPU usage *rate* requires
sampling `/proc/stat` over an interval. Both the overall CPU% and the per-process
instantaneous ranking share this single sleep — there is no extra delay.

## Example output

```
Server performance report  —  2026-06-04 22:25:21 +0330

== CPU usage ==
  Total CPU usage : 22.5%

== Memory usage ==
  Total : 7.4 GiB
  Used  : 5.9 GiB  (79.5%)
  Free  : 1.5 GiB  (20.5%)
  Swap  : 506.9 MiB used / 512.0 MiB total  (99.0%)

== Disk usage (all real filesystems) ==
  Size  : 234.2 GiB  (filesystem total, incl. reserved)
  Used  : 18.7 GiB  (8.4%)
  Free  : 204.9 GiB  (91.6%)
  Inodes: 481377 used / 15630336 total  (3.1%)

== Top 5 processes by CPU ==
  PID      USER               %CPU  COMMAND
  27589    lefthand            0.9  code
  27631    lefthand            0.7  code
  51       root                0.5  kcompactd0

== Top 5 processes by CPU (lifetime avg) ==
  PID      USER               %CPU  COMMAND
  27631    lefthand            9.4  code
  28568    lefthand            8.0  code
  5715     lefthand            6.6  firefox
  27589    lefthand            5.1  code
  20054    lefthand            3.3  Isolated

== Top 5 processes by memory ==
  PID      USER               %MEM  COMMAND
  5715     lefthand            7.0  firefox
  20054    lefthand            6.2  Isolated
  28420    lefthand            5.5  code
  6738     lefthand            5.3  Isolated
  27631    lefthand            4.7  code

== System info (stretch) ==
  OS         : Ubuntu 26.04 LTS
  Kernel     : 7.0.0-22-generic
  Hostname   : lefthand-laptop
  Uptime     : 0d 3h 17m
  Load avg   : 0.81, 0.72, 0.82   (cores: 4)
  Sessions   : 0 logged-in user session(s)

== Security (stretch) ==
  Failed SSH password attempts (journal): 0
```

## How it works

The script favors the kernel's `/proc` filesystem over scraping other tools, and
makes several deliberate correctness choices:

### CPU measurement

Overall CPU% and per-process instantaneous CPU% share **one** sampling window:

1. `_take_cpu_snapshot` reads `/proc/stat` (aggregate) and every `/proc/[pid]/stat` (per-process `utime+stime`) in a single pass.
2. The script sleeps 1 second.
3. A second snapshot is taken.
4. The delta of the aggregate counters gives overall CPU%.
5. The delta of each process's counters, divided by the same system-total delta, gives instantaneous per-process CPU%.

A separate **lifetime average** section uses `ps --sort=-%cpu`, which reports `total_cpu_time / wall_time_alive`. This is what `top` shows in batch mode. The two sections complement each other: instantaneous catches current spikes; lifetime average reveals consistently heavy processes.

### Memory

"Used" is `MemTotal − MemAvailable`, not `MemTotal − MemFree`, so reclaimable
cache doesn't masquerade as memory pressure. Swap is shown separately — high
swap usage is often the first indicator of a real memory problem.

### Disk

Totals use an **allowlist** of on-disk filesystem types (`ext2/3/4`, `xfs`,
`btrfs`, `zfs`, …), which fails safe against virtual/network mounts.
**Inode** usage is reported alongside space usage: a filesystem can return
"No space left on device" while still showing gigabytes free, if inodes are
exhausted.

### Security

Failed-login counting uses `-b` (current boot) when querying `journald`, so
the count reflects recent activity rather than the entire journal history.
`lastb` output is printed verbatim to avoid field-position fragility across
distros.

Full reasoning and tradeoffs are documented in
**[docs/WALKTHROUGH.md](docs/WALKTHROUGH.md)**.

## Roadmap

- Network throughput by diffing `/proc/net/dev`
- Per-mount disk breakdown
- `--json` output mode for ingestion by monitoring agents

## Acknowledgements

Based on the [Server Performance Stats](https://roadmap.sh/projects/server-stats)
project from [roadmap.sh](https://roadmap.sh).

## License

MIT
