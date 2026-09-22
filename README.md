# disk-watch

System-wide health sampler for the root USB SSD with a **PSI stall detector** and a
**reactive I/O throttle**. Born out of a real incident: a project automation spawned
headless Chromium every ~30 s for hours, saturated the disk, the system stalled and
the hardware watchdog reset the machine twice on 2026-09-18. Full post-mortem:
`~/homelab/reports/2026-09-18-crash-analysis.md`.

## What it does (every 5 minutes)

1. Samples device counters (`/proc/diskstats`), load, iowait, kernel I/O error lines
   and ext4 error counters.
2. Samples **PSI** (`/proc/pressure/io`, "how many tasks are stalled waiting for I/O")
   over a 30-second window.
3. Snapshots per-process I/O (`/proc/<pid>/io`) before/after the window and ranks
   the top consumers.
4. If pressure crosses the threshold: logs the offenders (`offN=pid:comm:MBps`) and,
   with `MITIGATE>=1`, **demotes them** (`ionice -c3` + `renice 19`) so the rest of
   the system keeps breathing — instead of dying to the watchdog again.
5. Appends one machine-parseable line to `/var/log/disk-watch/disk-watch.log`.

## Layout

```
disk-watch                     the sampler (bash, no dependencies beyond procps/util-linux)
systemd/disk-watch.service     system-wide oneshot unit (runs as root)
systemd/disk-watch.timer       5-minute timer
examples/disk-watch.conf.example   config template (all defaults commented)
install.sh                     system-wide installer (see below)
uninstall.sh                   remover (--purge also wipes data)
```

## Install

```bash
sudo ./install.sh
```

- binary  → `/usr/local/sbin/disk-watch`
- config  → `/etc/disk-watch/disk-watch.conf` (created from template, never overwritten)
- state   → `/var/lib/disk-watch/`
- log     → `/var/log/disk-watch/disk-watch.log`
- units   → `/etc/systemd/system/disk-watch.{service,timer}`, timer enabled

If run via `sudo` by a user who previously had the per-user version, the installer
migrates the old log + delta state and **removes the old per-user units and config**
so exactly one scheduler exists.

## Configuration

Edit `/etc/disk-watch/disk-watch.conf` (see `examples/` for the annotated template):

| Key | Default | Meaning |
|---|---|---|
| `DEV` | `sda` | block device to sample |
| `PSI_TRIG` | `25` | `/proc/pressure/io` full avg10 % that declares a stall |
| `PSI_WINDOW` / `PSI_STEP` | `30` / `5` | PSI sampling window and step (seconds) |
| `IO_TRIG_MBPS` | `5` | min MiB/s delta for a process to be flagged |
| `MITIGATE` | `1` | 0 observe · 1 demote (ionice+renice) · 2 also SIGSTOP/CONT |
| `COOLDOWN` | `300` | min seconds between mitigation actions |

Changes apply on the next run — no restart needed (config is sourced each run).

## Caveats

- `ionice` is fully honored only by the **BFQ** scheduler. The current elevator
  (`mq-deadline`) mostly ignores it; `renice` always works on the CPU side.
  Optional: `echo bfq > /sys/block/sda/queue/scheduler` (root, per-boot).
- `MITIGATE=2` freezes processes (SIGSTOP) — do not enable if services may be
  flagged as offenders.
- `max_sectors_kb` is capped at 512 KiB by `max_hw_sectors_kb` — a hard UAS
  driver/hardware ceiling. Not tunable, and irrelevant to the stall profile
  (the incident workload was thousands of small random reads, not big requests).

## Uninstall

```bash
sudo ./uninstall.sh          # keeps /etc/disk-watch, /var/lib, /var/log
sudo ./uninstall.sh --purge  # removes those too
```
