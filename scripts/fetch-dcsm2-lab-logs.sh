#!/usr/bin/env bash
# Retrieve only persisted DCSM2 Lab benchmark logs from an MGU.
# No capture window, journal following, or live subscriptions.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 root@MGU-IP" >&2; exit 2; }
HOST="$1"
SSH_PORT="${MGU_SSH_PORT:-22}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || { echo "Invalid MGU_SSH_PORT: $SSH_PORT" >&2; exit 2; }
SSH_OPTS=(-T -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10)
if [[ -n "${MGU_SSH_KEY:-}" ]]; then
  KEY="${MGU_SSH_KEY/#\\~/$HOME}"
  [[ -f "$KEY" ]] || { echo "SSH identity file not found: $KEY" >&2; exit 1; }
  SSH_OPTS+=(-i "$KEY")
fi
command -v ssh >/dev/null || { echo "ssh not found." >&2; exit 1; }
OUTDIR="${PWD}/mgu-diagnostics"
mkdir -p "$OUTDIR"
STAMP="$(date '+%Y%m%d-%H%M%S')"
ARCHIVE="$OUTDIR/dcsm2-lab-saved-logs-$STAMP.tar.gz"
echo "Connecting to $HOST; retrieving persisted DCSM2 Lab logs only..."
if ssh "${SSH_OPTS[@]}" "$HOST" "sh -s" > "$ARCHIVE" <<'REMOTE'
set -eu
TMP="/tmp/dcsm2-lab-saved-logs-$$"
mkdir -p "$TMP/files"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
INVENTORY="$TMP/dcsm2_lab_saved_log_inventory.txt"
: > "$INVENTORY"
ROOTS="/var/opt/public/oap /var/opt /tmp /var/tmp /home/root"
# Find saved benchmark logs once. No tail, journalctl -f, or monitoring.
for ROOT in $ROOTS; do
  [ -d "$ROOT" ] || continue
  find "$ROOT" -type f -name 'dcsm2_lab.log*' -print 2>/dev/null || true
done | sort -u > "$TMP/candidates.txt"
N=0
while IFS= read -r F; do
  [ -n "$F" ] || continue
  [ -f "$F" ] || continue
  N=$((N + 1))
  NAME="$(printf '%05d' "$N")_dcsm2_lab.log"
  if cp -p "$F" "$TMP/files/$NAME" 2>/dev/null; then
    printf 'COPIED %s -> files/%s\n' "$F" "$NAME" >> "$INVENTORY"
  else
    printf 'FOUND_BUT_COPY_FAILED %s\n' "$F" >> "$INVENTORY"
  fi
done < "$TMP/candidates.txt"
if [ ! -s "$INVENTORY" ]; then
  echo "No dcsm2_lab.log files found in: $ROOTS" > "$INVENTORY"
fi
if ! grep -q '^COPIED ' "$INVENTORY"; then
  echo "No saved DCSM2 Lab log files could be copied." >&2
  exit 4
fi
{
  echo "Saved DCSM2 Lab benchmark logs"
  echo "Collected: $(date 2>/dev/null || echo unknown)"
  echo "MGU: $(hostname 2>/dev/null || echo unknown)"
  echo "Mode: one-time file retrieval; no live capture or log following"
  echo
  cat "$INVENTORY"
} > "$TMP/README.txt"
tar -czf - -C "$TMP" files dcsm2_lab_saved_log_inventory.txt README.txt
REMOTE
then
  :
else
  RC=$?
  rm -f "$ARCHIVE"
  echo "Could not retrieve saved DCSM2 Lab logs (remote exit $RC)." >&2
  exit "$RC"
fi
if [[ ! -s "$ARCHIVE" ]]; then
  rm -f "$ARCHIVE"
  echo "MGU returned an empty archive." >&2
  exit 1
fi
echo
echo "Downloaded: $ARCHIVE"
