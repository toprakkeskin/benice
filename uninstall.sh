#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — remove the system-wide beniced (BeNice) installation
#
# Usage:
#   sudo ./uninstall.sh           # stop + disable + remove units and binary
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

if [[ $PURGE -eq 1 ]]; then
  echo "==> purging central data"
  rm -rf /etc/benice /var/lib/benice /var/log/benice
else
  echo "==> keeping /etc/benice, /var/lib/benice, /var/log/benice"
  echo "    (re-run with --purge to delete them as well)"
fi

echo "Done. beniced removed."
