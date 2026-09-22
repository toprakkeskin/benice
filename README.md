# benice

*"BeNice" — because something on your box is always being mean to your disk.*

A small systemd service that watches the disks on a Linux machine, notices
when something is grinding them into the ground, works out which process is
doing it, and pushes that process to the back of the queue before the whole
machine falls over.

It is one bash script (`beniced`) and one systemd timer. No agents, no
databases, no telemetry. Works on any block device — `sda`, `nvme0n1`,
whatever you have — and you can watch several at once.

**Author:** Toprak Keskin · [github.com/toprakkeskin](https://github.com/toprakkeskin)

## How this project was born

I run my homelab on a Raspberry Pi 5. Everything lives on one disk: the OS, a
handful of containers, my projects. One afternoon it rebooted itself. No
warning, no log, nothing in `journalctl`. The reason I never found out why is
that the system journal lived in RAM and died with the crash.

The second time it happened, the journal was persistent, and I caught the
machine red-handed: one of my own automations had been quietly launching
headless Chromium every 30 seconds for five hours. Six hundred launches, a
couple of thousand read IOPS, load average of 14 on four cores. The disk
drowned, the system stalled, and the hardware watchdog reset the box a minute
later. The logs told the whole story after the fact — but by then it had
already fallen over twice.

So I wrote a tiny script that logged disk numbers every five minutes. It was
an honest tool: it told me exactly when the disk was suffering, every single
time. I just got tired of reading obituaries. Now the same script measures the
pressure, finds out who is causing it, and demotes them before the machine
goes down. That is what you are looking at.

## How it works

Every 5 minutes the timer fires and `beniced` does this:

1. Reads device counters from `/proc/diskstats` (IOPS, busy time, in-flight
   requests), plus load, iowait and error counters.
2. Samples PSI (`/proc/pressure/io`) for 30 seconds. PSI is the kernel's own
   meter of how many tasks are stuck waiting for I/O. This is the single most
   honest number on the box.
3. Snapshots per-process I/O (`/proc/<pid>/io`) before and after that window
   and diffs them. Whatever ate the most bytes is your suspect.
4. If the pressure crossed the threshold, the top consumers are written to the
   log (`off1=4242:chromium:87MBps`) and — if mitigation is on — demoted with
   `ionice -c3` and `renice 19`. The offenders keep running. They just lose
   every queue they are standing in.

Everything is one `key=value` line per disk in a plain log file. No
dashboard required.

## Prerequisites

The big one: **PSI (Pressure Stall Information) must be present and enabled.**
beniced reads `/proc/pressure/io`; without it stall detection has nothing to
measure. Most mainline distro kernels ship this on by default — but Raspberry
Pi OS builds it disabled (`CONFIG_PSI_DEFAULT_DISABLED=y`), so on a Pi you
need one extra step:

```bash
# append psi=1 to the kernel command line (cmdline.txt is a SINGLE line —
# append to it, do not create a second line)
sudo sed -i 's/$/ psi=1/' /boot/firmware/cmdline.txt
sudo reboot

# verify after the reboot:
cat /proc/pressure/io        # should print some/full statistics
```

If `/proc/pressure/io` is missing, beniced still logs disk health, but runs
are marked `MISSING_PSI` and stall detection stays inactive.

The rest is modest:

- systemd (a oneshot service + a timer, no extras)
- bash and the usual coreutils (`awk`, `vmstat`, `ionice`, `renice`,
  `journalctl`)
- root — beniced must be able to see and throttle every user's processes

## Installation

```bash
sudo ./install.sh
```

The installer asks which disks you want to watch (it lists them, and marks
the root disk), installs a systemd unit and a 5-minute timer, and enables
them. For unattended setups:

```bash
sudo ./install.sh --disks "sda"
```

Re-running the installer is safe: it refreshes the binary and units but never
touches your existing config.

## What goes where

| Path | Purpose |
|---|---|
| `/usr/local/sbin/beniced` | the sampler itself |
| `/etc/benice/benice.conf` | central configuration (survives upgrades) |
| `/var/log/benice/benice.log` | one `key=value` line per disk, per run |
| `/var/lib/benice/state.<dev>` | per-disk counters between runs, for deltas |
| `/var/lib/benice/mitigate.state` | throttle bookkeeping (cooldowns, frozen pid) |
| `/etc/systemd/system/beniced.service` | oneshot unit, runs as root |
| `/etc/systemd/system/beniced.timer` | fires it every 5 minutes |

## Configuration

Edit `/etc/benice/benice.conf`. Changes apply on the next run — the file is
sourced fresh every time, no restart needed.

| Key | Default | Meaning |
|---|---|---|
| `DISKS` | `sda` | space-separated list of devices to watch |
| `PSI_TRIG` | `25` | PSI "full" avg10 % above which a stall is declared |
| `PSI_WINDOW` / `PSI_STEP` | `30` / `5` | PSI sampling window and step (seconds) |
| `IO_TRIG_MBPS` | `5` | minimum MiB/s for a process to be flagged |
| `MITIGATE` | `1` | 0 observe only · 1 demote · 2 also freeze/unfreeze |
| `COOLDOWN` | `300` | minimum seconds between two mitigations |

## Reading the log

```text
2026-09-22 11:55:20 dev=sda load_1m=0.20 ... util_pct=12 iowait_pct=0 \
  kernel_io_errors=0 fs_errors=0 psi_io_some_max=4 psi_io_full_max=0 \
  sched=mq-deadline status=OK
```

Most of it is standard iostat vocabulary. The interesting bits: `util_pct` is
how much of the interval the disk was busy; `psi_io_full_max` is the peak
percentage of time tasks were *blocked* on I/O — if that climbs while
`status=WARN` appears with an `off1=...` field, the log names the culprit.

## Uninstall

```bash
sudo ./uninstall.sh           # stops the timer, removes units and binary
sudo ./uninstall.sh --purge   # also removes config, logs and state
```

## Notes and small print

- `ionice` is only fully honored by the BFQ scheduler. On other elevators
  (mq-deadline is common) it is mostly cosmetic; `renice` always works on the
  CPU side.
- `MITIGATE=2` freezes the top offender between runs (SIGSTOP, then SIGCONT).
  It works, but do not enable it if a database or server could ever be
  flagged.
- `beniced` runs as root, because it needs to see and throttle every user's
  processes. It refuses to touch PID 1 and kernel threads.
- Requirements are listed in [Prerequisites](#prerequisites) — the big one is
  PSI being present and enabled.

## License

MIT — see [LICENSE](LICENSE).

## Author

**Toprak Keskin** — [github.com/toprakkeskin](https://github.com/toprakkeskin)

Built for my own homelab after it fell over twice in one day. If it saves
your box once, it was worth writing down.
