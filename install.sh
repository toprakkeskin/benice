#!/usr/bin/env bash
# =============================================================================
# install.sh — system-wide installer for beniced (BeNice)
#
# What it does:
#   1. installs the sampler binary to /usr/local/sbin/beniced
#   2. creates /etc/benice, /var/lib/benice, /var/log/benice and installs a
#      logrotate stanza for the log (/etc/logrotate.d/benice)
#   3. installs the central config /etc/benice/benice.conf
#      (never overwrites an existing config — only sets the DISKS= line)
#   4. interactively asks which disks to watch (or accepts --disks "sda sdb",
#      or falls back to the root disk when non-interactive); warns when PSI
#      (/proc/pressure/io) is unavailable — stall detection needs psi=1
#   4b. asks to switch the watched disks to the BFQ scheduler — beniced's
#       ionice demotions are fully binding only under BFQ; on confirmation it
#       writes /etc/udev/rules.d/61-benice-bfq.rules so BFQ persists across
#       reboots (uninstall.sh removes the rule again)
#   5. installs systemd units (system-wide, user-independent) and enables
#      the 5-minute timer
#
# Usage:
#   sudo ./install.sh                       # interactive disk prompt
#   sudo ./install.sh --disks "sda sdb"     # non-interactive disk selection
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must run as root —  sudo $0" >&2
  exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DST=/usr/local/sbin/beniced
CONF_DIR=/etc/benice
CONF_DST=$CONF_DIR/benice.conf
LIB_DIR=/var/lib/benice
LOG_DIR=/var/log/benice
LOGROTATE_DST=/etc/logrotate.d/benice
UNIT_DIR=/etc/systemd/system

# ---------------------------------------------------------------- parse args
DISKS_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --disks)   DISKS_ARG="${2:-}"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1  (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------- steps 1-3
echo "==> [1/5] installing binary to $BIN_DST"
install -m 0755 "$SRC_DIR/bin/beniced" "$BIN_DST"

echo "==> [2/5] creating runtime directories"
install -d -m 0755 "$CONF_DIR" "$LIB_DIR" "$LOG_DIR"

# log rotation for the append-only log (weekly, keep 8, no daemon restart
# needed thanks to copytruncate). Idempotent: never clobber a user-customized
# stanza — only write it when absent.
if [[ -f $LOGROTATE_DST ]]; then
  echo "    logrotate stanza already exists — keeping $LOGROTATE_DST"
else
  cat > "$LOGROTATE_DST" <<'EOF'
/var/log/benice/benice.log {
    weekly
    rotate 8
    copytruncate
    compress
    missingok
    notifempty
}
EOF
  chmod 0644 "$LOGROTATE_DST"   # root:root by construction (script requires root)
  echo "    installed logrotate stanza: $LOGROTATE_DST"
fi

echo "==> [3/5] installing central config to $CONF_DST"
if [[ -f $CONF_DST ]]; then
  echo "    already exists — keeping current config (DISKS line will be updated)"
else
  install -m 0644 "$SRC_DIR/config/benice.conf.example" "$CONF_DST"
  echo "    installed template with the default values"
fi

# ---------------------------------------------------------------- PSI check
# Stall detection needs PSI (/proc/pressure/io). Raspberry Pi OS ships with
# PSI disabled by default — the fix is psi=1 on the kernel cmdline + reboot.
# Health sampling works without PSI, so warn prominently and continue.
PSI_PATH=${PSI_PATH:-/proc/pressure/io}
if [[ ! -r $PSI_PATH ]]; then
  {
    echo
    echo "  **************************************************************************************"
    echo "  *  WARNING: PSI is not available on this kernel — stall detection will stay inactive."
    echo "  *  FIX: append psi=1 to /boot/firmware/cmdline.txt and reboot."
    echo "  *  (health sampling still works without PSI)"
    echo "  **************************************************************************************"
    echo
  } >&2
fi

# ------------------------------------------------- step 4: disk selection
# candidates: real disks only (no loops, no zram)
mapfile -t CAND < <(lsblk -dn -o NAME,SIZE,TYPE,MODEL | awk '$3=="disk"{$3=""; print $1, $2, $4}' | sed 's/  *$//')

# root disk = parent of the device mounted at /
root_src=$(findmnt -n -o SOURCE / 2>/dev/null || echo "")
root_disk=$(lsblk -no pkname "${root_src#/dev/}" 2>/dev/null || true)
[[ -z $root_disk && -n $root_src ]] && root_disk=${root_src#/dev/}

# default selection: current central config (DISKS or DEV) else root disk
def_conf=$(grep -hE '^(DISKS|DEV)=' "$CONF_DST" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' || true)
DEFAULT_DISKS=${def_conf:-$root_disk}

echo "==> [4/5] selecting disks to watch"
echo "    available disks:"
i=0
for c in "${CAND[@]}"; do
  i=$((i + 1))
  name=${c%% *}
  mark=""
  [[ $name == "$root_disk" ]] && mark="   <- root disk (/)"
  echo "      [$i] $c$mark"
done

resolve_selection() { # $1 = user input -> echo validated disk names
  local input=$1 tok name idx out=""
  input=${input//,/ }
  for tok in $input; do
    if [[ $tok =~ ^[0-9]+$ ]]; then
      idx=$tok
      [[ $idx -ge 1 && $idx -le ${#CAND[@]} ]] || return 1
      name=${CAND[$((idx - 1))]%% *}
    else
      name=$tok
      found=0
      for c in "${CAND[@]}"; do
        [[ ${c%% *} == "$name" ]] && { found=1; break; }
      done
      [[ $found -eq 1 ]] || return 1
    fi
    case " $out " in *" $name "*) ;; *) out="${out:+$out }$name" ;; esac
  done
  [[ -n $out ]] || return 1
  echo "$out"
}

if [[ -n $DISKS_ARG ]]; then
  SELECTED=$(resolve_selection "$DISKS_ARG") || { echo "ERROR: invalid --disks value '$DISKS_ARG'" >&2; exit 1; }
  echo "    non-interactive selection: $SELECTED"
elif [[ -t 0 ]]; then
  tries=0
  while :; do
    read -rp "    disks to watch [numbers or names, comma/space separated; default: ${DEFAULT_DISKS}]: " ans
    ans=${ans:-$DEFAULT_DISKS}
    if SELECTED=$(resolve_selection "$ans"); then
      break
    fi
    tries=$((tries + 1))
    if [[ $tries -ge 3 ]]; then
      SELECTED=$DEFAULT_DISKS
      echo "    too many invalid attempts — falling back to: $SELECTED"
      break
    fi
    echo "    invalid selection, try again (e.g.: 1  or  sda  or  sda sdb)"
  done
else
  SELECTED=$DEFAULT_DISKS
  echo "    non-interactive session — using default: $SELECTED"
fi
echo "    watching: $SELECTED"

# persist DISKS= into the central config. The value is replaced in place,
# right under its "# Disks to watch" comment; if the line or the comment is
# missing entirely, the entry is appended at the end instead.
sed -i '/^DISKS=/d; /^DEV=/d' "$CONF_DST"
if grep -q '^# Disks to watch, space-separated' "$CONF_DST"; then
  sed -i "/^# Disks to watch, space-separated/a DISKS=\"$SELECTED\"" "$CONF_DST"
else
  printf 'DISKS="%s"\n' "$SELECTED" >> "$CONF_DST"
fi

# ------------------- BFQ scheduler step (ask-to-enable) --------------------
# beniced demotes competing I/O via ionice, which is fully binding only under
# the BFQ scheduler. Override hooks (mirroring PSI_PATH above) exist so the
# logic can be exercised against a fake sysfs without touching the host:
#   SYS_BLOCK (default /sys/block), UDEV_RULE (default below).
SYS_BLOCK=${SYS_BLOCK:-/sys/block}
UDEV_RULE=${UDEV_RULE:-/etc/udev/rules.d/61-benice-bfq.rules}

active_sched() { # $1 = dev -> echo the ACTIVE scheduler (the bracketed entry)
  local line
  line=$(<"$SYS_BLOCK/$1/queue/scheduler") || return 1
  if [[ $line =~ \[([^]]+)\] ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "$line"   # single-scheduler kernels print no brackets
  fi
}

bfq_step() {
  local first=${SELECTED%% *} sched sf d tmp ans
  sched=$(active_sched "$first" 2>/dev/null || true)
  if [[ $sched == bfq ]]; then
    echo "    scheduler on watched disks: bfq — ionice demotions are fully binding ✓"
    return 0
  fi

  # non-interactive (--disks given or no tty): skip the prompt, print the
  # per-disk info line with the manual command instead
  if [[ -n $DISKS_ARG || ! -t 0 ]]; then
    for d in $SELECTED; do
      sched=$(active_sched "$d" 2>/dev/null || echo unknown)
      echo "    scheduler on $d is $sched. To make ionice fully binding run:"
      echo "      echo bfq > $SYS_BLOCK/$d/queue/scheduler"
    done
    return 0
  fi

  echo "    scheduler on watched disks: $sched"
  read -rp "Switch watched disks ($SELECTED) to the BFQ scheduler so ionice is fully binding? [y/N] " ans || ans=""
  case ${ans,,} in
    y|yes)
      for d in $SELECTED; do
        sf=$SYS_BLOCK/$d/queue/scheduler
        # 'if' context keeps set -e alive when the write fails; report it
        if [[ -w $sf ]] && echo bfq > "$sf" 2>/dev/null; then
          echo "    $d: scheduler -> bfq"
        else
          echo "    WARNING: could not switch $d to bfq ($sf not writable)" >&2
        fi
      done
      # persistence: one rule line per watched disk, regenerated wholesale
      # on every run -> install-overwrite stays idempotent, no duplicates
      tmp=$(mktemp)
      for d in $SELECTED; do
        printf 'ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="%s", ATTR{queue/scheduler}="bfq"\n' "$d" >> "$tmp"
      done
      install -m 0644 "$tmp" "$UDEV_RULE"
      rm -f "$tmp"
      echo "    BFQ enabled now + persisted across reboots (udev rule)"
      echo "    rule file: $UDEV_RULE"
      ;;
    *)
      echo "    keeping scheduler $sched — renice still works, ionice stays partially binding"
      ;;
  esac
}
bfq_step
# ------------------------------------------------------- end BFQ scheduler step

# ---------------------------------------------------------------- step 5
echo "==> [5/5] installing systemd units and enabling the timer"
install -m 0644 "$SRC_DIR/systemd/beniced.service" "$UNIT_DIR/beniced.service"
install -m 0644 "$SRC_DIR/systemd/beniced.timer"   "$UNIT_DIR/beniced.timer"
systemctl daemon-reload
systemctl enable --now beniced.timer

# resolve the next elapse via the systemd bus (raw microseconds):
#   On*Sec (monotonic) timers -> NextElapseUSecMonotonic (µs since boot)
#   OnCalendar (realtime) ones -> NextElapseUSecRealtime (µs since epoch)
# Right after a trigger both can be transiently unset — hence the fallback.
next_run() {
  local unit=beniced.timer
  local path="/org/freedesktop/systemd1/unit/${unit//./_2e}"
  path=${path//-/_2d}
  local mono rt up_us
  mono=$(busctl get-property org.freedesktop.systemd1 "$path" org.freedesktop.systemd1.Timer NextElapseUSecMonotonic 2>/dev/null | awk '{print $2}')
  if [[ $mono =~ ^[0-9]+$ && $mono -gt 0 ]]; then
    up_us=$(awk '{printf "%d", $1 * 1000000}' /proc/uptime)
    date -d "@$(( $(date +%s) + (mono - up_us) / 1000000 ))" '+%F %T %Z' && return 0
  fi
  rt=$(busctl get-property org.freedesktop.systemd1 "$path" org.freedesktop.systemd1.Timer NextElapseUSecRealtime 2>/dev/null | awk '{print $2}')
  if [[ $rt =~ ^[0-9]+$ && $rt -gt 0 ]]; then
    date -d "@$(( rt / 1000000 ))" '+%F %T %Z' && return 0
  fi
  echo "scheduling in progress — check: systemctl list-timers $unit"
}

echo
echo "Done. beniced (BeNice) is installed system-wide."
echo "  binary : $BIN_DST"
echo "  config : $CONF_DST  (DISKS=\"$SELECTED\")"
echo "  log    : $LOG_DIR/benice.log  (logrotate: $LOGROTATE_DST)"
echo "  psi    : $( [[ -r $PSI_PATH ]] && echo available || echo 'NOT available — stall detection inactive' )"
echo "  state  : $LIB_DIR/"
echo "  timer  : $(systemctl is-enabled beniced.timer 2>/dev/null) ($(systemctl is-active beniced.timer 2>/dev/null))"
echo
echo "Next run: $(next_run)"
