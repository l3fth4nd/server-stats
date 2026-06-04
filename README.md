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
- **Memory usage** — used vs. free with percentages, based on `MemAvailable` so reclaimable page cache isn't miscounted as "used"
- **Disk usage** — aggregated across real (block-backed) filesystems, with percentages that reconcile with `df`
- **Top 5 processes by CPU**
- **Top 5 processes by memory**
- **Stretch:** OS version, kernel, hostname, uptime, load average (vs. core count), logged-in sessions, failed login attempts

No external dependencies beyond standard coreutils (`awk`, `ps`, `df`, `who`) — no Python, no extra packages.

## Requirements

- A Linux system with a mounted `/proc` (i.e. essentially any Linux server)
- `bash` 4+
- Standard tooling: `awk`, `ps`, `df`, `who`, `uname`
- `root` (via `sudo`) only for the failed-login section, which reads `/var/log/btmp`

## Installation

```bash
git clone https://github.com/<your-username>/server-stats.git
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
sampling `/proc/stat` over an interval.

## Example output

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

== Top 5 processes by CPU ==
  PID      USER           %CPU  COMMAND
  1        root            1.6  process_api
  ...

== Top 5 processes by memory ==
  PID      USER           %MEM  COMMAND
  489      root            0.8  some-daemon
  ...

== System info (stretch) ==
  OS         : Ubuntu 24.04.4 LTS
  Kernel     : 6.18.5
  Uptime     : 12d 4h 31m
  Load avg   : 0.42, 0.55, 0.60   (cores: 4)
  Sessions   : 1 logged-in user session(s)
```

## How it works

The script favors the kernel's `/proc` filesystem over scraping other tools, and
makes a few deliberate correctness choices that aren't obvious at first glance:

- CPU usage is a **rate**, so it's computed by diffing two `/proc/stat` samples ~1s apart.
- "Used" memory is `MemTotal − MemAvailable`, not `MemTotal − MemFree`, so reclaimable cache doesn't masquerade as pressure.
- Disk totals use an **allowlist** of on-disk filesystem types, which fails safe against virtual/network mounts; percentages follow `df`'s `used/(used+avail)` convention.
- `ps %cpu` is a lifetime average, not the instantaneous figure `top` shows — see the walkthrough for why that matters.

Full reasoning, tradeoffs, and the bugs caught during development are documented in
**[docs/WALKTHROUGH.md](docs/WALKTHROUGH.md)**.

## Roadmap

- Network throughput by diffing `/proc/net/dev`
- Per-mount disk breakdown
- Swap usage
- `--json` output mode for ingestion by monitoring agents

## Acknowledgements

Based on the [Server Performance Stats](https://roadmap.sh/projects/server-stats)
project from [roadmap.sh](https://roadmap.sh).

## License

MIT
