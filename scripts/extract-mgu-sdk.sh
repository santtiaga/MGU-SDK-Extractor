#!/usr/bin/env bash
# Extract the BMW OAP SDK donor from an MGU over SSH.
# Usage: ./scripts/extract-mgu-sdk.sh root@MGU-IP
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
  echo "Usage: $0 root@MGU-IP" >&2
  exit 2
fi
HOST="$1"
SSH_OPTS=(-T -o BatchMode=yes -o ConnectTimeout=10)
SCP_OPTS=(-O -o BatchMode=yes -o ConnectTimeout=10)
if [[ -n "${MGU_SSH_KEY:-}" ]]; then
  KEY="${MGU_SSH_KEY/#\~/$HOME}"
  [[ -f "$KEY" ]] || { echo "SSH identity file not found: $KEY" >&2; exit 1; }
  SSH_OPTS+=(-i "$KEY")
  SCP_OPTS+=(-i "$KEY")
fi
command -v ssh >/dev/null || { echo "ssh not found." >&2; exit 1; }
command -v scp >/dev/null || { echo "scp not found." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required on the Mac to parse sdk-donor metadata." >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="$ROOT/mgu-sdk"
STAMP="$(date '+%Y%m%d-%H%M%S')"
DEST="$OUTDIR/sdk-donor-$STAMP"
mkdir -p "$DEST"
META="$(mktemp -t mgu-sdk-donor)"
trap 'rm -f "$META"' EXIT

echo "[sdk] Requesting the stock SDK donor from $HOST ..."
echo "[sdk] Running mgu-deploy.sh sdk-donor --json (read-only command; writes its cache under /run)."
if ! ssh "${SSH_OPTS[@]}" "$HOST" '
  if command -v mgu-deploy.sh >/dev/null 2>&1; then
    mgu-deploy.sh sdk-donor --json
  elif [ -x /var/opt/mgu-deploy/mgu-deploy.sh ]; then
    /var/opt/mgu-deploy/mgu-deploy.sh sdk-donor --json
  else
    echo "mgu-deploy.sh not found; install/update the MGU deploy tool first." >&2
    exit 127
  fi
' >"$META"; then
  echo "[sdk] Extraction command failed. Check that mgu-deploy is installed and that the unit has a stock SDK donor." >&2
  exit 1
fi

FIELDS="$(python3 - "$META" <<'PY'
import json
import sys

raw = open(sys.argv[1], "r", encoding="utf-8").read()
data = None
decoder = json.JSONDecoder()
for i, ch in enumerate(raw):
    if ch != "{":
        continue
    try:
        candidate, _ = decoder.raw_decode(raw[i:])
    except ValueError:
        continue
    if isinstance(candidate, dict) and "path" in candidate and "module" in candidate:
        data = candidate
        break
if data is None:
    raise SystemExit("Could not find sdk-donor JSON with path and module fields.")
bundle = data["path"]
module = data["module"]
prefix = "/run/mgu-deploy/sdk-donor/"
for label, value in (("path", bundle), ("module", module)):
    if not isinstance(value, str) or not value.startswith(prefix) or ".." in value.split("/"):
        raise SystemExit("Unsafe or unexpected remote %s path: %r" % (label, value))
print(bundle)
print(module)
print(data.get("donor") or "")
print(data.get("sdkVersion") or "")
PY
)" || {
  echo "[sdk] Invalid metadata returned by mgu-deploy.sh:" >&2
  cat "$META" >&2
  exit 1
}
BUNDLE="$(printf '%s\n' "$FIELDS" | sed -n '1p')"
MODULE="$(printf '%s\n' "$FIELDS" | sed -n '2p')"
DONOR="$(printf '%s\n' "$FIELDS" | sed -n '3p')"
SDK_VERSION="$(printf '%s\n' "$FIELDS" | sed -n '4p')"

echo "[sdk] Donor: ${DONOR:-unknown}"
echo "[sdk] SDK version: ${SDK_VERSION:-unknown}"
echo "[sdk] Downloading Browserify bundle..."
scp "${SCP_OPTS[@]}" "$HOST:$BUNDLE" "$DEST/sdk-donor.js"
echo "[sdk] Downloading generated oap-sdk module..."
scp "${SCP_OPTS[@]}" -r "$HOST:$MODULE" "$DEST/oap-sdk"
cp "$META" "$DEST/sdk-donor-response.json"
cat > "$DEST/README.txt" <<EOF
BMW MGU OAP SDK donor
Extracted: $(date)
SSH target: $HOST
Donor: ${DONOR:-unknown}
SDK version: ${SDK_VERSION:-unknown}

sdk-donor.js is the Browserify donor bundle returned by:
  mgu-deploy.sh sdk-donor --json

oap-sdk/ is the generated public oap-sdk module returned by the same command.
The original JSON response is in sdk-donor-response.json.

Treat these files as BMW-provided SDK material. Keep them local and do not
commit or publish them unless you have confirmed the applicable permissions.
EOF

echo
echo "[sdk] Complete:"
echo "  $DEST"
echo "[sdk] Files: sdk-donor.js, oap-sdk/, sdk-donor-response.json"
