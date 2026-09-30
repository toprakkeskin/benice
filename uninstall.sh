#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — remove the system-wide beniced (BeNice) installation
#
# Usage:
#   sudo ./uninstall.sh           # stop + disable + remove units, binary,
#                                 # the logrotate stanza, the BFQ udev rule
#                                 # and the task-delay-accounting conf
#   sudo ./uninstall.sh --purge   # ALSO delete central config, logs, state
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root —  sudo $0" >&2
  exit 1
fi

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

echo "==> stopping and disabling the timer"
systemctl disable --now beniced.timer 2>/dev/null || true

echo "==> removing units and binary"
rm -f /etc/systemd/system/beniced.service
rm -f /etc/systemd/system/beniced.timer
rm -f /usr/local/sbin/beniced
systemctl daemon-reload

echo "==> removing logrotate stanza"
rm -f /etc/logrotate.d/benice

echo "==> removing udev rule (BFQ persistence)"
rm -f /etc/udev/rules.d/61-benice-bfq.rules

echo "==> removing task delay accounting conf (F19)"
DA_CONF=/etc/sysctl.d/91-benice-delayacct.conf
if [[ -f $DA_CONF ]]; then
  rm -f "$DA_CONF"
  sysctl -w kernel.task_delayacct=0 >/dev/null 2>&1 || true
  echo "    removed; runtime value restored to 0"
else
  echo "    not present — nothing to remove"
fi

echo "==> checking memory guardrails drop-in"
GUARD_DST=/etc/systemd/system/user-1000.slice.d/memory-limits.conf
if [[ -f $GUARD_DST ]]; then
  echo "    found: $GUARD_DST (MemoryHigh/MemoryMax on user-1000.slice)"
  if [[ -t 0 ]]; then
    read -rp "    remove the guardrails as well? [y/N]: " gans
  else
    gans=""
    echo "    non-interactive session — keeping them (delete the file manually)"
  fi
  if [[ $gans =~ ^[Yy] ]]; then
    rm -f "$GUARD_DST"
    rmdir /etc/systemd/system/user-1000.slice.d 2>/dev/null || true
    systemctl daemon-reload
    echo "    guardrails removed"
  else
    echo "    kept — limits stay active"
  fi
fi

if [[ $PURGE -eq 1 ]]; then
  echo "==> purging central data"
  rm -rf /etc/benice /var/lib/benice /var/log/benice
else
  echo "==> keeping /etc/benice, /var/lib/benice, /var/log/benice"
  echo "    (re-run with --purge to delete them as well)"
fi

echo "Done. beniced removed."
