#!/usr/bin/env bash
# Download existing Apex Dash log files from an MGU over SSH (read-only).
# Usage: ./scripts/fetch-apex-dash-logs.sh root@MGU-IP
set -euo pipefail
[[ $# -eq 1 ]] || { echo "Usage: $0 root@MGU-IP" >&2; exit 2; }
HOST="$1"
SSH_OPTS=(-T -o BatchMode=yes -o ConnectTimeout=10)
if [[ -n "${MGU_SSH_KEY:-}" ]]; then
  KEY="${MGU_SSH_KEY/#\~/$HOME}"
  [[ -f "$KEY" ]] || { echo "SSH identity file not found: $KEY" >&2; exit 1; }
  SSH_OPTS+=(-i "$KEY")
fi
command -v ssh >/dev/null || { echo "ssh not found." >&2; exit 1; }
OUTDIR="${PWD}/mgu-diagnostics"
mkdir -p "$OUTDIR"
STAMP="$(date '+%Y%m%d-%H%M%S')"
ARCHIVE="$OUTDIR/apex-dash-old-logs-$STAMP.tar.gz"
echo "Connecting to $HOST and locating existing Apex Dash logs..."
if ssh "${SSH_OPTS[@]}" "$HOST" "sh -s" > "$ARCHIVE" <<'REMOTE'
set -eu
TMP="/tmp/apex-dash-old-logs-$$"
mkdir -p "$TMP/files"
trap 'rm -rf "$TMP"' EXIT
: > "$TMP/manifest"
# Search only application and logging locations; match Apex Dash-specific
# filenames and log files inside directories explicitly named for Apex Dash.
for ROOT in /var/opt/public/oap /var/opt/cluster-render /var/log /tmp /var/tmp; do
  [ -d "$ROOT" ] || continue
  find "$ROOT" -type f \( \
    -iname 'apex_dash.log*' -o -iname 'apex-dash.log*' -o \
    -iname '*apex*dash*.log*' -o \
    -path '*/apex*dash/*' -a \( -iname '*.log*' -o -iname '*.out' -o -iname '*.err' \) \
  \) -print 2>/dev/null >> "$TMP/manifest" || true
done
sort -u "$TMP/manifest" -o "$TMP/manifest"
if [ ! -s "$TMP/manifest" ]; then
  echo "No Apex Dash log files found in the searched locations." >&2
  rm -rf "$TMP"
  exit 4
fi
{
  echo "Apex Dash historical log bundle"
  echo "Collected: $(date 2>/dev/null || echo unknown)"
  echo "MGU: $(hostname 2>/dev/null || echo unknown)"
  echo
  cat "$TMP/manifest"
} > "$TMP/README.txt"
# Use relative paths so archive extraction does not write to absolute locations.
sed 's#^/##' "$TMP/manifest" > "$TMP/relative-manifest"
tar -czf - -C / -T "$TMP/relative-manifest" "$TMP/README.txt"
RC=$?
rm -rf "$TMP"
exit "$RC"
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
