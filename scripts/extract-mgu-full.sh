#!/usr/bin/env bash
# Two-stage read-only MGU extraction.
set -euo pipefail
MODE=lists
if [[ "${1:-}" == "--lists" ]]; then shift
elif [[ "${1:-}" == "--download-assets" ]]; then MODE=download-assets; shift
fi
if [[ "$MODE" == lists && $# -ne 1 ]] || [[ "$MODE" == download-assets && $# -ne 2 ]]; then
  echo "Usage: $0 --lists root@MGU-IP | --download-assets root@MGU-IP OUTPUT_DIR" >&2; exit 2
fi
HOST="$1"
command -v ssh >/dev/null || { echo "ssh not found" >&2; exit 1; }
command -v tar >/dev/null || { echo "tar not found" >&2; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_ROOT="$HOME/BMW_MGU_Extract"; mkdir -p "$OUT_ROOT"; OUT_ROOT="$(cd "$OUT_ROOT" && pwd -P)"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10)
SCP_OPTS=(-O -o BatchMode=yes -o ConnectTimeout=10)
if [[ -n "${MGU_SSH_KEY:-}" ]]; then
  KEY="${MGU_SSH_KEY/#\~/$HOME}"
  [[ -f "$KEY" ]] || { echo "SSH identity not found: $KEY" >&2; exit 1; }
  SSH_OPTS+=(-i "$KEY"); SCP_OPTS+=(-i "$KEY")
fi
ssh_mgu() { ssh "${SSH_OPTS[@]}" "$HOST" "$@"; }
scp_mgu() { scp "${SCP_OPTS[@]}" "$@"; }

if [[ "$MODE" == download-assets ]]; then
  [[ -d "$2" ]] || { echo "Output directory not found: $2" >&2; exit 1; }
  DEST="$(cd "$2" && pwd -P)"
  case "$DEST/" in "$OUT_ROOT"/*) ;; *) echo "Refusing path outside $OUT_ROOT" >&2; exit 1;; esac
  ASSET_DIR="$DEST/assets"; INDEX="$ASSET_DIR/file_index.txt"
  [[ -s "$INDEX" ]] || { echo "Missing asset index; run --lists first" >&2; exit 1; }
  mkdir -p "$ASSET_DIR/rootfs"
  PATH_LIST="$ASSET_DIR/.asset-paths.tmp"
  sed -n 's#^/##p' "$INDEX" > "$PATH_LIST"
  COUNT="$(wc -l < "$PATH_LIST" | tr -d ' ')"
  if [[ "$COUNT" -eq 0 ]]; then rm -f "$PATH_LIST"; echo "No indexed paths to download."; exit 0; fi
  echo "[assets] Downloading $COUNT indexed files from $HOST ..."
  if ssh_mgu "cd / && tar -czf - -T -" < "$PATH_LIST" | tar -xzf - -C "$ASSET_DIR/rootfs"; then
    rm -f "$PATH_LIST"
    printf 'Indexed files: %s\nDownload completed: %s\n' "$COUNT" "$(date)" > "$ASSET_DIR/download-report.txt"
    echo "[assets] Download complete: $ASSET_DIR/rootfs"
  else
    rm -f "$PATH_LIST"; echo "Transfer failed; retry Download assets." >&2; exit 1
  fi
  exit 0
fi

command -v scp >/dev/null || { echo "scp not found" >&2; exit 1; }
command -v node >/dev/null || { echo "Node.js is required for SDK reconstruction" >&2; exit 1; }
STAMP="$(date '+%Y%m%d-%H%M%S')"; DEST="$OUT_ROOT/$STAMP"
SDK_DIR="$DEST/sdk"; SYS_DIR="$DEST/system_info"; ASSET_DIR="$DEST/assets"
mkdir -p "$SDK_DIR" "$SYS_DIR" "$ASSET_DIR"
echo "[mgu] Connecting to $HOST ..."
ssh_mgu "uname -a; cat /etc/os-release" > "$SYS_DIR/os-release-and-kernel.txt"
echo "[sdk] Locating x_call archive ..."
REMOTE_TGZ="$(ssh_mgu "find /usr/lib/oap-mainapp/preinstalled_apps -maxdepth 1 -type f -name 'x_call@*.tgz' -print 2>/dev/null | sort | tail -n 1")"
[[ -n "$REMOTE_TGZ" && "$REMOTE_TGZ" == /usr/lib/oap-mainapp/preinstalled_apps/x_call@*.tgz ]] || { echo "No x_call archive found" >&2; exit 1; }
echo "[sdk] Downloading $REMOTE_TGZ ..."
scp_mgu "$HOST:$REMOTE_TGZ" "$SDK_DIR/"
ARCHIVE="$SDK_DIR/$(basename "$REMOTE_TGZ")"; mkdir "$SDK_DIR/x_call"; tar -xzf "$ARCHIVE" -C "$SDK_DIR/x_call"
APP_JS="$(find "$SDK_DIR/x_call" -type f -path '*/javascript/app.js' -print -quit)"
[[ -n "$APP_JS" ]] || { echo "x_call archive has no javascript/app.js" >&2; exit 1; }
node "$ROOT/scripts/extract_sdk.js" "$APP_JS" "$SDK_DIR/oap-sdk"
echo "[system] Collecting SOME/IP definitions ..."
if ssh_mgu "test -r /etc/oap/someip/someip-interfaces.json"; then
  scp_mgu "$HOST:/etc/oap/someip/someip-interfaces.json" "$SYS_DIR/"
else
  echo "Not present or not readable on this MGU." > "$SYS_DIR/someip-interfaces-unavailable.txt"
fi
ssh_mgu '
echo "=== MGU VERSION ==="; cat /etc/os-release 2>/dev/null || true
echo; echo "=== KERNEL ==="; uname -a
echo; echo "=== STORAGE ==="; df -h
echo; echo "=== OAP APPS ==="; find /usr/lib/oap-mainapp/preinstalled_apps -maxdepth 1 -type f -print 2>/dev/null | sort
echo; echo "=== OAP CONFIG ==="; find /etc/oap -maxdepth 3 -type f -print 2>/dev/null | sort
' > "$SYS_DIR/inventory.txt"
echo "[assets] Building resource index only ..."
ssh_mgu '
for d in /usr/share /usr/lib /opt /var/opt/public /etc/oap; do
 echo "===== $d ====="
 find "$d" -maxdepth 6 -type f \( -iname "*.png" -o -iname "*.svg" -o -iname "*.ttf" -o -iname "*.otf" -o -iname "*.json" -o -iname "*.dds" -o -iname "*.ktx" -o -iname "*.bin" \) 2>/dev/null
done
' > "$ASSET_DIR/file_index.txt"
COUNT="$(grep -c '^/' "$ASSET_DIR/file_index.txt" || true)"
cat > "$DEST/README.txt" <<EOF
BMW MGU extraction — list stage
Collected: $(date)
SSH target: $HOST
SDK: x_call archive and locally reconstructed oap-sdk
System: OS/kernel, storage, OAP app and /etc/oap inventory, SOME/IP JSON
Assets: assets/file_index.txt contains paths only. Run Download assets separately.
Indexed asset paths: $COUNT
Stage 2 streams the indexed files over SSH into assets/rootfs/ preserving paths.
Read-only on MGU; no installation, flashing, coding, restarts or configuration changes.
Keep BMW proprietary SDK/configuration/assets private.
EOF
echo
echo "[mgu] List collection complete: $DEST"
echo "[mgu] Asset index: $ASSET_DIR/file_index.txt"
echo "[mgu] Indexed asset paths: $COUNT"
echo "OUTPUT_DIR=$DEST"
