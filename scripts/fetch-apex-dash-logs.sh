#!/usr/bin/env bash
# Download historical Apex Dash / OAP / cluster-render logs from an MGU.
# Read-only on the MGU; only a temporary staging directory under /tmp is created.
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 root@MGU-IP" >&2; exit 2; }
HOST="$1"
SSH_PORT="${MGU_SSH_PORT:-6811}"
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
ARCHIVE="$OUTDIR/apex-dash-old-logs-$STAMP.tar.gz"
echo "Connecting to $HOST and collecting historical application logs..."
if ssh "${SSH_OPTS[@]}" "$HOST" "sh -s" > "$ARCHIVE" <<'REMOTE'
set -eu
TMP="/tmp/apex-dash-old-logs-$$"
mkdir -p "$TMP/files"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
: > "$TMP/manifest"
# Include all log-like files under OAP app storage (app-specific names vary),
# plus known renderer and system log locations. Do not collect app databases.
for ROOT in /var/opt/public/oap /var/opt/cluster-render /var/log; do
  [ -d "$ROOT" ] || continue
  find "$ROOT" -type f \( \
    -iname '*.log' -o -iname '*.log.[0-9]*' -o -iname '*.log.*' -o \
    -iname '*.out' -o -iname '*.err' -o \
    -iname 'apex_dash*' -o -iname 'apex-dash*' \
  \) -print 2>/dev/null >> "$TMP/manifest" || true
done
# Include systemd journal exports when available, filtered to relevant services.
if command -v journalctl >/dev/null 2>&1; then
  journalctl --no-pager -u cluster-render.service > "$TMP/files/cluster-render-journal.log" 2>/dev/null || true
  journalctl --no-pager 2>/dev/null | grep -Ei 'apex_dash|apex dash|cluster-render|DCSM2|RAMSES' > "$TMP/files/relevant-system-journal.log" || true
fi
sort -u "$TMP/manifest" -o "$TMP/manifest"
N=0
: > "$TMP/README.txt"
{
  echo "Historical Apex Dash / OAP / cluster-render logs"
  echo "Collected: $(date 2>/dev/null || echo unknown)"
  echo "MGU: $(hostname 2>/dev/null || echo unknown)"
  echo
  echo "Files copied from the MGU:"
} >> "$TMP/README.txt"
while IFS= read -r F; do
  [ -n "$F" ] || continue
  [ -f "$F" ] || continue
  N=$((N + 1))
  NAME="$(printf '%05d' "$N")"
  if cp "$F" "$TMP/files/$NAME.log" 2>/dev/null; then
    printf '%s  %s\n' "$NAME.log" "$F" >> "$TMP/README.txt"
  fi
done < "$TMP/manifest"
if [ "$N" -eq 0 ] && [ ! -s "$TMP/files/cluster-render-journal.log" ] && [ ! -s "$TMP/files/relevant-system-journal.log" ]; then
  echo "No matching log files or journal entries found." >&2
  exit 4
fi
tar -czf - -C "$TMP" files README.txt
REMOTE
then
  :
else
  RC=$?
  rm -f "$ARCHIVE"
  echo "Could not collect Apex Dash logs (remote exit $RC)." >&2
  exit "$RC"
fi
if [[ ! -s "$ARCHIVE" ]]; then
  rm -f "$ARCHIVE"
  echo "MGU returned an empty archive." >&2
  exit 1
fi
echo
echo "Downloaded: $ARCHIVE"
