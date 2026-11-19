#!/usr/bin/env bash
# Extract the BMW OAP SDK from an MGU over SSH.
# Prefer mgu-deploy's stock SDK donor; fall back to the x_call Browserify bundle.
set -euo pipefail
[[ $# -eq 1 && -n "$1" ]] || { echo "Usage: $0 root@MGU-IP" >&2; exit 2; }
HOST="$1"
SSH_PORT="${MGU_SSH_PORT:-6811}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || { echo "Invalid MGU_SSH_PORT: $SSH_PORT" >&2; exit 2; }
SSH_OPTS=(-T -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10)
SCP_OPTS=(-O -P "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10)
if [[ -n "${MGU_SSH_KEY:-}" ]]; then
  KEY="${MGU_SSH_KEY/#\~/$HOME}"
  [[ -f "$KEY" ]] || { echo "SSH identity file not found: $KEY" >&2; exit 1; }
  SSH_OPTS+=(-i "$KEY")
  SCP_OPTS+=(-i "$KEY")
fi
command -v ssh >/dev/null || { echo "ssh not found." >&2; exit 1; }
command -v scp >/dev/null || { echo "scp not found." >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required." >&2; exit 1; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="$ROOT/mgu-sdk"
STAMP="$(date '+%Y%m%d-%H%M%S')"
DEST="$OUTDIR/sdk-extract-$STAMP"
mkdir -p "$DEST"
META="$(mktemp -t mgu-sdk-meta)"
FIELDS="$(mktemp -t mgu-sdk-fields)"
trap 'rm -f "$META" "$FIELDS"' EXIT

echo "[sdk] Connecting to $HOST ..."
# First try the MGU deploy tool's canonical SDK donor interface.
if ssh "${SSH_OPTS[@]}" "$HOST" '
  if command -v mgu-deploy.sh >/dev/null 2>&1; then
    mgu-deploy.sh sdk-donor --json
  elif [ -x /var/opt/mgu-deploy/mgu-deploy.sh ]; then
    /var/opt/mgu-deploy/mgu-deploy.sh sdk-donor --json
  elif [ -x /var/opt/mgu-deploy/current/deploy/unit/mgu-deploy.sh ]; then
    /var/opt/mgu-deploy/current/deploy/unit/mgu-deploy.sh sdk-donor --json
  else
    echo "mgu-deploy.sh not found" >&2
    exit 127
  fi
' > "$META"; then
  if python3 - "$META" > "$FIELDS" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
decoder = json.JSONDecoder()
data = None
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
if not data:
    raise SystemExit(1)
prefix = "/run/mgu-deploy/sdk-donor/"
for key in ("path", "module"):
    value = data.get(key)
    if not isinstance(value, str) or not value.startswith(prefix) or ".." in value.split("/"):
        raise SystemExit(1)
print(data["path"])
print(data["module"])
print(data.get("donor") or "")
print(data.get("sdkVersion") or "")
PY
  then
    BUNDLE="$(sed -n '1p' "$FIELDS")"
    MODULE="$(sed -n '2p' "$FIELDS")"
    DONOR="$(sed -n '3p' "$FIELDS")"
    SDK_VERSION="$(sed -n '4p' "$FIELDS")"
    echo "[sdk] Using mgu-deploy donor: ${DONOR:-unknown} (oap-sdk ${SDK_VERSION:-unknown})"
    if scp "${SCP_OPTS[@]}" "$HOST:$BUNDLE" "$DEST/sdk-donor.js" &&
       scp "${SCP_OPTS[@]}" -r "$HOST:$MODULE" "$DEST/oap-sdk"; then
      cp "$META" "$DEST/sdk-donor-response.json"
      METHOD="mgu-deploy sdk-donor"
    else
      echo "[sdk] Could not download the donor cache; trying x_call fallback."
      rm -f "$DEST/sdk-donor.js"
      rm -rf "$DEST/oap-sdk"
    fi
  else
    echo "[sdk] mgu-deploy returned unrecognized metadata; trying x_call fallback."
  fi
else
  echo "[sdk] mgu-deploy SDK donor unavailable; trying x_call fallback."
fi

# If the donor interface did not produce both files, rebuild from the stock x_call app.
if [[ ! -s "$DEST/sdk-donor.js" || ! -s "$DEST/oap-sdk/index.js" ]]; then
  command -v node >/dev/null || { echo "Node.js is required only for the x_call fallback method." >&2; exit 1; }
  echo "[sdk] Locating a preinstalled x_call archive ..."
  REMOTE_TGZ="$(ssh "${SSH_OPTS[@]}" "$HOST" '
    for D in /usr/lib/oap-mainapp/preinstalled_apps /usr/lib/oap-mainapp21/preinstalled_apps; do
      [ -d "$D" ] && find "$D" -maxdepth 1 -type f -name "x_call@*.tgz" -print 2>/dev/null
    done | sort | tail -n 1
  ')"
  [[ -n "$REMOTE_TGZ" ]] || {
    echo "[sdk] No x_call@*.tgz found in either MainApp preinstalled_apps directory." >&2
    echo "[sdk] The MGU also did not provide a usable mgu-deploy SDK donor." >&2
    exit 1
  }
  mkdir -p "$DEST/x_call"
  echo "[sdk] Downloading $REMOTE_TGZ ..."
  scp "${SCP_OPTS[@]}" "$HOST:$REMOTE_TGZ" "$DEST/x_call/"
  ARCHIVE="$DEST/x_call/$(basename "$REMOTE_TGZ")"
  mkdir -p "$DEST/x_call/unpacked"
  tar -xzf "$ARCHIVE" -C "$DEST/x_call/unpacked"
  APP_JS="$(find "$DEST/x_call/unpacked" -type f -path '*/javascript/app.js' -print -quit)"
  [[ -n "$APP_JS" ]] || { echo "[sdk] x_call archive has no javascript/app.js." >&2; exit 1; }
  cp "$APP_JS" "$DEST/sdk-donor.js"
  node "$ROOT/scripts/extract_sdk.js" "$APP_JS" "$DEST/oap-sdk"
  METHOD="x_call fallback"
fi

cat > "$DEST/README.txt" <<EOF
BMW MGU OAP SDK extraction
Extracted: $(date)
SSH target: $HOST
Method: $METHOD

sdk-donor.js is the Browserify bundle used to reconstruct the SDK.
oap-sdk/ contains the reconstructed module (index.js, package.json and source/).
Keep BMW-provided SDK material local and do not redistribute without permission.
EOF
echo
echo "[sdk] Complete ($METHOD):"
echo "  $DEST"
echo "[sdk] Files: sdk-donor.js, oap-sdk/, README.txt"
