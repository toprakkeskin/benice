#!/usr/bin/env bash
# =============================================================================
# install.sh — system-wide installer for disk-watch
#
# What it does:
#   1. installs the sampler binary to /usr/local/sbin/disk-watch
#   2. creates /etc/disk-watch, /var/lib/disk-watch, /var/log/disk-watch
#   3. installs the central config /etc/disk-watch/disk-watch.conf
#      (never overwrites an existing config — only sets the DISKS= line)
#   4. INTERACTIVELY asks which disks to watch (or accepts --disks "sda sdb",
#      or falls back to the root disk when non-interactive)
#   5. installs systemd units (system-wide, user-independent) and enables
#      the 5-minute timer
#   6. migrates data from a previous per-user installation (log + state) and
#      REMOVES the old per-user setup (user timer/service units + user config)
#      for the invoking user (sudo "$SUDO_USER")
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

BIN_DST=/usr/local/sbin/disk-watch
CONF_DIR=/etc/disk-watch
CONF_DST=$CONF_DIR/disk-watch.conf
LIB_DIR=/var/lib/disk-watch
LOG_DIR=/var/log/disk-watch
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
echo "==> [1/6] installing binary to $BIN_DST"
install -m 0755 "$SRC_DIR/disk-watch" "$BIN_DST"

echo "==> [2/6] creating runtime directories"
install -d -m 0755 "$CONF_DIR" "$LIB_DIR" "$LOG_DIR"

echo "==> [3/6] installing central config to $CONF_DST"
if [[ -f $CONF_DST ]]; then
  echo "    already exists — keeping current config (DISKS line will be updated)"
else
  install -m 0644 "$SRC_DIR/examples/disk-watch.conf.example" "$CONF_DST"
  echo "    installed default template (all knobs commented out)"
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

echo "==> [4/6] selecting disks to watch"
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

# persist DISKS= into the central config (replace existing line, keep the rest)
sed -i '/^DISKS=/d; /^DEV=/d' "$CONF_DST"
printf 'DISKS="%s"\n' "$SELECTED" >> "$CONF_DST"

# ---------------------------------------------------------------- step 5
echo "==> [5/6] installing systemd units (system-wide)"
install -m 0644 "$SRC_DIR/systemd/disk-watch.service" "$UNIT_DIR/disk-watch.service"
install -m 0644 "$SRC_DIR/systemd/disk-watch.timer"   "$UNIT_DIR/disk-watch.timer"

# ---------------------------------------------------------------- step 6
echo "==> [6/6] migrating data from previous per-user installation (if any)"
if [[ -n "${SUDO_USER:-}" ]] && getent passwd "$SUDO_USER" >/dev/null; then
  UHOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  UUID=$(id -u "$SUDO_USER")

  # migrate history: old log + delta states (only if new locations are empty)
  if [[ -f "$UHOME/disk-health.log" && ! -e "$LOG_DIR/disk-watch.log" ]]; then
    install -m 0640 "$UHOME/disk-health.log" "$LOG_DIR/disk-watch.log"
    echo "    migrated health log: $UHOME/disk-health.log -> $LOG_DIR/disk-watch.log"
  fi
  for old_state in "$UHOME"/.disk-watch.state "$LIB_DIR"/state; do
    :
  done
  if [[ -f "$UHOME/.disk-watch.state" ]]; then
    # the script itself renames plain "state" -> "state.<first-disk>" on first run
    if [[ ! -e "$LIB_DIR/state" ]]; then
      install -m 0644 "$UHOME/.disk-watch.state" "$LIB_DIR/state"
      echo "    migrated delta state: $UHOME/.disk-watch.state -> $LIB_DIR/state"
    fi
  fi

  # stop + disable + remove the old per-user timer/service
  if [[ -d "/run/user/$UUID" ]]; then
    runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$UUID" \
      systemctl --user stop disk-watch.timer disk-watch.service 2>/dev/null || true
    runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$UUID" \
      systemctl --user disable disk-watch.timer 2>/dev/null || true
  fi
  removed=0
  for f in disk-watch.timer disk-watch.service; do
    if [[ -f "$UHOME/.config/systemd/user/$f" ]]; then
      rm -f "$UHOME/.config/systemd/user/$f"
      removed=1
    fi
  done
  if [[ $removed -eq 1 && -d "/run/user/$UUID" ]]; then
    runuser -u "$SUDO_USER" -- env XDG_RUNTIME_DIR="/run/user/$UUID" \
      systemctl --user daemon-reload 2>/dev/null || true
  fi
  [[ $removed -eq 1 ]] && echo "    removed per-user units for $SUDO_USER"

  # remove the old per-user config (central config replaces it)
  if [[ -f "$UHOME/.config/disk-watch.conf" ]]; then
    rm -f "$UHOME/.config/disk-watch.conf"
    echo "    removed per-user config: $UHOME/.config/disk-watch.conf"
  fi

  # NOTE: the old copy at $UHOME/bin/disk-watch is intentionally kept;
  # it is no longer used by anything. Delete it manually if you wish.
else
  echo "    no invoking user detected (SUDO_USER empty) — skipping migration"
fi

echo "==> enabling systemd timer"
systemctl daemon-reload
systemctl enable --now disk-watch.timer

echo
echo "Done. disk-watch is installed system-wide."
echo "  binary : $BIN_DST"
echo "  config : $CONF_DST  (DISKS=\"$SELECTED\")"
echo "  log    : $LOG_DIR/disk-watch.log"
echo "  state  : $LIB_DIR/"
echo "  timer  : $(systemctl is-enabled disk-watch.timer 2>/dev/null) ($(systemctl is-active disk-watch.timer 2>/dev/null))"
echo
echo "Next run: $(systemctl show disk-watch.timer -p NextElapseUSecRealtime --value)"
