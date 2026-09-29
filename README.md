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

Every minute the timer fires and `beniced` does this:

1. Reads device counters from `/proc/diskstats` (IOPS, busy time, in-flight
   requests), plus load, iowait and error counters.
2. Samples PSI (`/proc/pressure/io`) for 30 seconds. PSI is the kernel's own
   meter of how many tasks are stuck waiting for I/O. This is the single most
   honest number on the box.
3. Snapshots per-process I/O (`/proc/<pid>/io`) before and after that window
   and diffs them. Whatever ate the most bytes is your suspect.
4. If the pressure crossed the threshold, the top consumers are written to the
   log (`off1=4242:chromium:87MiB` — bytes accumulated over the window, not a
   rate) and — if mitigation is on — demoted with `ionice -c3` and `renice 19`.
   The offenders keep running. They just lose every queue they are standing
   in, temporarily: their original nice is recorded before the demotion, and
   once the disk has stayed calm for two consecutive runs the nice is given
   back (logged as `restored:` lines).

Everything is one `key=value` line per disk in a plain log file. No
dashboard required.

## Demotion and recovery, step by step

The demote/restore mechanism is the part people usually want to understand
in detail, so here it is with the actual values.

When a PSI trigger fires, beniced records three things about each offender
**before touching it**:

- the original nice value (from `/proc/<pid>/stat`)
- the original I/O class and level (from `ionice -p <pid>`)
- the process start time (so a recycled PID is never confused with the
  original one)

It then demotes: nice → 19, ionice → idle.

Every later run, each demoted process earns one clean point for every
window in which it does not re-appear among the top I/O consumers. After
two clean points the process is restored — nice goes back to the recorded
original, ionice goes back to the recorded class and level, and the log
gets a `restored:` line. A process that exits while demoted is logged as
`restored: pid=4242 nice=0 (process had already exited or been killed)`
and simply dropped — a new process always starts with default values.

The lifecycle in one picture:

    normal ──▶ demoted ──▶ (2 clean windows) ──▶ restored ──▶ normal
                 │
                 └─ process exits meanwhile ──▶ logged as restored (exited)

And one run, end to end:

    systemd timer (every 1 min)
      └─▶ beniced run
          ├─ snapshot A: per-process I/O + start times
          ├─ sample PSI for 30 s
          ├─ snapshot B
          ├─ rank processes by I/O delta over the window
          ├─ PSI full >= threshold?
          │     yes ─▶ report offenders, demote top set (record originals)
          │     no  ─▶ tick clean counters, restore whoever reached 2
          └─ write one key=value line per disk

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

### The scheduler matters for demotion

Demotion has two halves, enforced by different parts of the kernel:

- the **CPU side** (`renice 19`) works everywhere, on every scheduler;
- the **I/O side** (`ionice -c3`) is only fully honored by the **BFQ**
  scheduler.

Some history, because it explains the situation: in the single-queue days
the CFQ scheduler applied `ionice` faithfully. Kernel 5.0 removed CFQ when
the block layer moved to multiqueue, and the modern schedulers treat
`ionice` differently:

| scheduler | what a demoted process gets |
|---|---|
| `bfq` | the real thing — served only when nothing else wants the disk |
| `mq-deadline` | partial (supported since kernel 5.18): a hint, not a guarantee |
| `none` / `kyber` | effectively ignored |

Check what your disks are running:

```bash
cat /sys/block/sda/queue/scheduler
# e.g. "none [mq-deadline] kyber bfq"  — the bracketed entry is active
```

If it is not `bfq`, the installer will offer to switch the watched disks
for you: it applies the change immediately and persists it with a udev
rule. By hand, per boot:

```bash
echo bfq | sudo tee /sys/block/sda/queue/scheduler
```

Without BFQ beniced still works — the CPU-side `renice` keeps doing its
job and every demotion is logged — but a demoted process keeps most of
its I/O share.

## Installation

```bash
sudo ./install.sh
```

The installer asks which disks you want to watch (it lists them, and marks
the root disk), installs a systemd unit and a one-minute timer, drops a
logrotate stanza for the log, warns you if PSI looks unavailable on this
kernel, and enables everything. For unattended setups:

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
| `/etc/logrotate.d/benice` | keeps the log from growing forever |
| `/var/lib/benice/state.<dev>` | per-disk counters between runs, for deltas |
| `/var/lib/benice/mitigate.state` | throttle bookkeeping (frozen pid, demoted pids + original nice and ionice) |
| `/etc/systemd/system/beniced.service` | oneshot unit, runs as root |
| `/etc/systemd/system/beniced.timer` | fires it every minute |

## Configuration

Edit `/etc/benice/benice.conf`. Changes apply on the next run — the file is
sourced fresh every time, no restart needed.

| Key | Default | Meaning |
|---|---|---|
| `DISKS` | `sda` | space-separated list of devices to watch |
| `PSI_TRIG` | `25` | PSI "full" avg10 % above which a stall is declared |
| `PSI_WINDOW` / `PSI_STEP` | `15` / `3` | PSI sampling window and step (seconds) |
| `IO_TRIG_MBPS` | `5` | minimum MiB a process must transfer during the PSI window to be flagged (the name is historical — the log label reports MiB per window) |
| `MEM_TRIG` / `MEM_AVAIL_MIN` | `40` / `750` | memory-pressure alert threshold (%) / MemAvailable floor (MiB) that raise `MEM_HIGH` |
| `MITIGATE` | `1` | 0 observe only · 1 demote · 2 also freeze; demotions are undone after 2 clean runs |

## Self-I/O hygiene (F12–F14)

beniced watches I/O — it must not become an I/O problem itself:

- **F12 — incremental error counting:** kernel I/O errors are counted with
  `journalctl --cursor-file`, so each run reads only lines newer than the
  previous run. The old full-journal scan re-walked ~1 GB of journal files
  per run; with a cold page cache that faulted in ~950 MB on the USB SSD
  (84-second runs, recurring ~950 MB "memory peak" — clean page cache, but
  a real read storm). First run after boot keeps the old since-boot count.
- **F13 — system processes are off-limits:** PID 1 and every process under
  `/system.slice` are excluded from offender ranking, the below-threshold
  valve, and demotion. `/proc/<pid>/io` rolls reaped children's I/O into the
  parent, so systemd and build orchestrators always LOOK like top consumers —
  on 2026-09-29 the valve demoted systemd plus 61 system services on exactly
  that false signal (auto-restored after 2 clean runs).
- **F14 — fork-free snapshot:** the per-process I/O snapshot uses bash
  builtins only. The old helper forked `cat` + `awk` per PID (~3200 execs per
  run): measured 5.5 s CPU per run → 0.3 s after the fix.

## Reading the log

```text
2026-09-22 11:55:20 dev=sda load_1m=0.20 ... util_pct=12 iowait_pct=0 \
  kernel_io_errors=0 fs_errors=0 psi_io_some_max=4 psi_io_full_max=0 \
  sched=mq-deadline status=OK
```

Most of it is standard iostat vocabulary. The interesting bits: `util_pct` is
how much of the interval the disk was busy; `psi_io_full_max` is the peak
percentage of time tasks were *blocked* on I/O — if that climbs and
`status=WARN` appears, the run names the culprit.

When the pressure threshold trips, the offending runs get their own lines:

```text
offenders: off1=4242:chromium:87MiB off2=891:backup:12MiB
action: ionice+renice pids=4242 (ionice fully binding only under bfq)
restored: pid=4242 nice=0
```

`offN=` names the culprit together with the MiB it moved during the window
(not a rate). `action:` records what beniced did about it, and `restored:`
appears when a previously demoted process has been given its original nice
back — that happens automatically after two consecutive runs with no PSI
trigger.

## Uninstall

```bash
sudo ./uninstall.sh           # stops the timer, removes units and binary
sudo ./uninstall.sh --purge   # also removes config, logs and state
```

## Security: what beniced may touch

Although beniced runs as root, it does so inside a small sandbox that systemd
enforces on its behalf. The service can read the whole system, but it may
write only to its own two directories, `/var/log/benice` and
`/var/lib/benice`. A few of the rules that make this work:

- `ProtectSystem=strict` — the filesystem is mounted read-only for the
  service, with the two directories above as the only exceptions.
- `NoNewPrivileges=yes` — the service cannot gain additional privileges, no
  matter what happens inside the script.
- `PrivateTmp=yes` and `ProtectHome=yes` — the service sees its own private
  `/tmp`, and neither `/home` nor `/root` are accessible to it.
- `UMask=0027` — files it creates are readable by group at most, never by
  everyone.

You are welcome to verify this yourself rather than take the README's word
for it:

```bash
systemctl show beniced.service -p NoNewPrivileges -p ProtectSystem
systemctl show beniced.service -p ReadWritePaths -p PrivateTmp
```

In practice this means that even an unexpected bug in beniced could, at
worst, write to its own log and state files or adjust the priority of a
process — the rest of the system stays out of reach, and the service makes
no network connections at all.

## General Notes

- `ionice` demotion is only fully binding under BFQ — see
  [the scheduler notes](#the-scheduler-matters-for-demotion) in
  Prerequisites.
- `MITIGATE=2` freezes the top offender until the next run. Crash-safe: the
  pid (plus its `/proc` start time and original nice) is written to the state
  file *before* the SIGSTOP, and every run starts by SIGCONT-ing whatever is
  on record — even a power cut mid-freeze cannot leave a process stopped
  forever. Still, do not enable it if a database or server could ever be
  flagged.
- Demotion is not a life sentence. Every offender's original nice is recorded
  at demote time, and after two consecutive runs with no PSI trigger the
  surviving offenders are reniced back automatically (`restored:` lines in
  the log). Processes that exited in the meantime are simply dropped.
- `beniced` runs as root, because it needs to see and throttle every user's
  processes. It refuses to touch PID 1 and kernel threads.
- Requirements are listed in [Prerequisites](#prerequisites) — the big one is
  PSI being present and enabled.

## benice and the kernel OOM killer

OOM stands for **Out Of Memory**. The kernel's OOM killer is the last line of
defense: when RAM *and* swap are exhausted it picks a process by an
`oom_score` heuristic — roughly "biggest memory hog wins" — and kills it. Two
things make it a poor guardian on a small box: by the time it fires the
system has usually been thrashing for a while (everything is already slow or
stuck), and the score is blind to *value* — it may kill your database while
the runaway agent that caused the pressure survives.

benice is the earlier, better-aimed layer:

- it detects **pressure** (I/O via PSI, memory via `/proc/pressure/memory`)
  long before RAM is gone and names/demotes the actual offenders;
- the `user-1000.slice` memory guardrails (companion report:
  `~/homelab/reports/2026-09-28-system-resource-limits.md`) guarantee that IF
  an OOM kill ever becomes necessary it happens **inside the slice** — the
  fattest runaway agent dies, SSH and system services survive;
- the hardware watchdog is the final backstop if even that fails.

In short: benice prevents, the OOM killer executes as a last resort, the
watchdog reboots what even that could not save.

## Responsibility

beniced is a small tool I wrote for my own homelab, shared in the hope that
it may be useful to others as well. Since it runs with elevated privileges
and adjusts process priorities, I would kindly ask you to read through the
script before installing it — it is short, and there is nothing hidden in
it.

The software is provided as-is, without any warranty. While I use it daily
on my own machines, I unfortunately cannot take responsibility for any
issues or data loss that may occur on your system. Please use it at your own
discretion — and if you are trying it on an important machine, running it in
observe-only mode (`MITIGATE=0`) for a few days first is a gentle way to get
to know it.

## License

MIT — see [LICENSE](LICENSE).

## Author

**Toprak Keskin** — [github.com/toprakkeskin](https://github.com/toprakkeskin)

Built for my own homelab after it fell over twice in one day. If it saves
your box once, it was worth writing down.
