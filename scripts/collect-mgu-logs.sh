#!/usr/bin/env bash
# Collect MGU cluster-render + Apex Dash diagnostics from macOS over SSH.
# Usage: ./scripts/collect-mgu-logs.sh root@MGU-IP [duration-seconds] [--keep-remote]
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  ./scripts/collect-mgu-logs.sh root@MGU-IP [duration-seconds] [--keep-remote]

Examples:
  ./scripts/collect-mgu-logs.sh root@192.168.1.50
  ./scripts/collect-mgu-logs.sh root@192.168.1.50 600
  ./scripts/collect-mgu-logs.sh root@my-mgu.local 900 --keep-remote

The script runs on your Mac, connects to the MGU, captures diagnostics for
the requested period (default 600 seconds), downloads one .tar.gz archive,
and removes its temporary directory from the MGU unless --keep-remote is set.
EOF
  exit 2
}

[[ $# -ge 1 && $# -le 3 ]] || usage
HOST="$1"
SSH_PORT="${MGU_SSH_PORT:-22}"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || { echo "Invalid MGU_SSH_PORT: $SSH_PORT" >&2; exit 2; }
SSH_OPTS=(-T -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10)
SCP_OPTS=(-O -P "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=10)
if [[ -n "${MGU_SSH_KEY:-}" ]]; then
  KEY="${MGU_SSH_KEY/#\~/$HOME}"
  [[ -f "$KEY" ]] || { echo "SSH identity file not found: $KEY" >&2; exit 1; }
  SSH_OPTS+=(-i "$KEY")
  SCP_OPTS+=(-i "$KEY")
fi
DURATION=600
KEEP_REMOTE=0
for arg in "${@:2}"; do
  case "$arg" in
    --keep-remote) KEEP_REMOTE=1 ;;
    ''|*[!0-9]*) usage ;;
    *) DURATION="$arg" ;;
  esac
done
(( DURATION >= 30 && DURATION <= 7200 )) || { echo "Duration must be 30..7200 seconds." >&2; exit 2; }

command -v ssh >/dev/null || { echo "ssh not found." >&2; exit 1; }
command -v scp >/dev/null || { echo "scp not found." >&2; exit 1; }

STAMP="$(date '+%Y%m%d-%H%M%S')"
OUTDIR="${PWD}/mgu-diagnostics"
mkdir -p "$OUTDIR"
LOCAL_ARCHIVE="$OUTDIR/apex-dash-mgu-$STAMP.tar.gz"

echo "Connecting to $HOST ..."
echo "Collection window: $DURATION seconds."
echo "If SSH asks about the host key, verify it before accepting."

REMOTE_ARCHIVE="$(
ssh "${SSH_OPTS[@]}" "$HOST" "sh -s -- '$DURATION'" <<'REMOTE_SCRIPT'
set -u
DURATION="$1"
STAMP="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo unknown)"
BASE="/tmp/apex-dash-diag-$STAMP-$$"
mkdir -p "$BASE/meta" "$BASE/logs" "$BASE/snapshots" "$BASE/processes"
START_EPOCH="$(date +%s 2>/dev/null || echo 0)"
START_TEXT="$(date 2>/dev/null || echo unknown)"
PIDS=""

run_capture() {
  NAME="$1"; shift
  {
    echo "### $NAME"
    echo "### captured: $(date 2>/dev/null)"
    "$@" 2>&1
    RC=$?
    echo "### exit_code=$RC"
    echo
  } > "$BASE/meta/$NAME.txt"
}

# DCSM2 Lab writes its persistent benchmark journal to ctx.dataDir/dcsm2_lab.log.
# Search app-data and temporary roots explicitly; preserve each source path in the archive.
collect_dcsm2_lab_logs() {
  PHASE="$1"
  INVENTORY="$BASE/meta/dcsm2_lab_saved_log_inventory.txt"
  : > "$INVENTORY"
  ROOTS="/var/opt/public/oap /var/opt /tmp /var/tmp /home/root"
  {
    for ROOT in $ROOTS; do
      [ -d "$ROOT" ] || continue
      find "$ROOT" -type f -name 'dcsm2_lab.log*' -print 2>/dev/null
    done
  } | sort -u | while IFS= read -r F; do
    [ -f "$F" ] || continue
    SAFE="$(echo "$F" | sed 's#/#_#g')"
    DEST="$BASE/logs/$SAFE"
    if cp -p "$F" "$DEST" 2>/dev/null; then
      echo "COPIED $F -> $DEST" >> "$INVENTORY"
    else
      echo "FOUND_BUT_COPY_FAILED $F" >> "$INVENTORY"
    fi
  done
  if [ ! -s "$INVENTORY" ]; then
    echo "No dcsm2_lab.log files found in: $ROOTS" > "$INVENTORY"
  fi
}

# Basic platform and service inventory; commands are probed, never assumed.
run_capture system uname -a
run_capture date date
run_capture uptime uptime
run_capture df df -h
run_capture mount mount
run_capture memory sh -c 'cat /proc/meminfo 2>/dev/null; echo; command -v free >/dev/null 2>&1 && free -m'
run_capture processes ps w
run_capture services sh -c 'command -v systemctl >/dev/null 2>&1 && systemctl --no-pager --full status cluster-render.service; command -v service >/dev/null 2>&1 && service cluster-render status'
run_capture renderer_version sh -c 'command -v cluster-render; cluster-render --version 2>&1; command -v opkg >/dev/null 2>&1 && opkg list-installed | grep -Ei "cluster-render|ramses|oap"'
run_capture renderer_status sh -c 'command -v cluster-render >/dev/null 2>&1 && cluster-render status; echo; cat /run/cluster-render/status.txt 2>/dev/null; echo; cat /var/run/cluster-render/status.txt 2>/dev/null'
run_capture renderer_paths sh -c 'ls -la /run/cluster-render /var/run/cluster-render /dev/shm/cluster-render 2>/dev/null; echo; ls -lah /var/opt/cluster-render/log 2>/dev/null'
run_capture app_inventory sh -c 'find /var/opt/public/oap -maxdepth 4 -type f \\( -name package.json -o -name app.json -o -iname "*apex*dash*" \\) -print 2>/dev/null'
run_capture renderer_processes sh -c 'ps w 2>/dev/null | grep -Ei "cluster.render|ramses|oap|apex" | grep -v grep'
run_capture sockets sh -c 'cat /proc/net/unix 2>/dev/null | grep -Ei "cluster|render|ramses|oap"; echo; netstat -an 2>/dev/null | head -300'
# BusyBox-compatible kernel log capture: do not use GNU-only dmesg -T.
run_capture kernel_boot dmesg
run_capture journal_boot sh -c 'command -v journalctl >/dev/null 2>&1 && journalctl -b --no-pager -n 5000'
run_capture journal_boot_list sh -c 'command -v journalctl >/dev/null 2>&1 && journalctl --list-boots --no-pager'
run_capture journal_previous_boot sh -c 'command -v journalctl >/dev/null 2>&1 && journalctl -b -1 --no-pager -n 5000'
run_capture renderer_unit sh -c 'command -v journalctl >/dev/null 2>&1 && journalctl -u cluster-render.service --no-pager -n 8000; command -v systemctl >/dev/null 2>&1 && systemctl cat cluster-render.service'
run_capture init_scripts sh -c 'ls -la /etc/init.d 2>/dev/null | grep -Ei "cluster|oap|render"; ls -la /etc/systemd/system 2>/dev/null | grep -Ei "cluster|oap|render"'
run_capture log_file_inventory sh -c 'find /var/log /var/opt /tmp /var/tmp -type f 2>/dev/null | grep -Ei "dcsm|ramses|cluster.?render|kombi|instrument|apex.?dash|oap"'
run_capture journal_all_history sh -c 'command -v journalctl >/dev/null 2>&1 && journalctl --no-pager -o short-precise'
run_capture journal_relevant_history sh -c 'command -v journalctl >/dev/null 2>&1 && journalctl --no-pager -o short-precise | grep -Ei "dcsm|ramses|cluster.?render|renderer|watchdog|kombi|instrument|apex.?dash|oap"'
run_capture journal_all_previous_boot sh -c 'command -v journalctl >/dev/null 2>&1 && journalctl -b -1 --no-pager -o short-precise'
run_capture kombi_log_inventory sh -c 'find /var/log /var/opt /tmp /var/tmp -type f 2>/dev/null | grep -Ei "kombi|instrument.?cluster|dkombi|kombiinstrument"'


echo "[collector] Initial system and renderer inventory captured." >&2

# Copy known renderer logs before live-following them.
for F in /var/opt/cluster-render/log/cluster-render.log /var/opt/cluster-render/log/cluster-render.log.1 /var/log/cluster-render.log /var/log/cluster-render/cluster-render.log; do
  if [ -f "$F" ]; then
    SAFE="$(echo "$F" | sed 's#/#_#g')"
    cp "$F" "$BASE/logs/$SAFE.initial" 2>/dev/null || true
  fi
done

# Find likely OAP/Apex Dash log files only; do not sweep arbitrary application data.
find /var/opt/public/oap -type f \( -iname "*.log" -o -iname "*.log.1" -o -iname "*.out" -o -iname "*.err" \) -print 2>/dev/null |
while IFS= read -r F; do
  case "$F" in
    */logs/*|*apex*|*oap*)
      SAFE="$(echo "$F" | sed 's#/#_#g')"
      cp "$F" "$BASE/logs/$SAFE.initial" 2>/dev/null || true
      ;;
  esac
done

# Follow live logs while reproducing the issue. tail -F survives log rotation.
for F in /var/opt/cluster-render/log/cluster-render.log /var/log/cluster-render.log /var/log/cluster-render/cluster-render.log; do
  if [ -f "$F" ] && command -v tail >/dev/null 2>&1; then
    SAFE="$(echo "$F" | sed 's#/#_#g')"
    tail -n 0 -F "$F" > "$BASE/logs/$SAFE.live" 2>&1 &
    PIDS="$PIDS $(jobs -p | tail -n 1)"
  fi
done

if command -v journalctl >/dev/null 2>&1; then
  journalctl -f -u cluster-render.service --no-pager > "$BASE/logs/cluster-render-journal.live" 2>&1 &
  PIDS="$PIDS $(jobs -p | tail -n 1)"
  # Full live system stream; service names differ between MGU software builds.
  journalctl -f --no-pager > "$BASE/logs/system-journal.live" 2>&1 &
  PIDS="$PIDS $(jobs -p | tail -n 1)"
fi

# Time series: renderer status, process state, memory and socket presence.
END_EPOCH=$((START_EPOCH + DURATION))
N=0
LAST_PROGRESS=0
while [ "$(date +%s 2>/dev/null || echo "$END_EPOCH")" -lt "$END_EPOCH" ]; do
  N=$((N + 1))
  ELAPSED=$((N * 5))
  if [ $((ELAPSED - LAST_PROGRESS)) -ge 30 ]; then
    echo "[collector] Live capture: ${ELAPSED}s / ${DURATION}s" >&2
    LAST_PROGRESS=$ELAPSED
  fi
  {
    echo "===== sample=$N time=$(date 2>/dev/null) epoch=$(date +%s 2>/dev/null) ====="
    echo "--- renderer status ---"
    command -v cluster-render >/dev/null 2>&1 && cluster-render status 2>&1
    cat /run/cluster-render/status.txt 2>/dev/null
    echo "--- processes ---"
    ps w 2>/dev/null | grep -Ei 'cluster.render|ramses|oap|apex' | grep -v grep
    echo "--- memory ---"
    grep -E 'MemTotal|MemFree|MemAvailable|Buffers|Cached|Slab' /proc/meminfo 2>/dev/null
    echo "--- sockets ---"
    grep -Ei 'cluster|render|ramses' /proc/net/unix 2>/dev/null
  } >> "$BASE/snapshots/timeline.txt"
  sleep 5
done

echo "[collector] Capture window complete; finalizing logs and building archive." >&2

# Final snapshots and time-bounded journal/kernel diagnostics.
run_capture final_renderer_status sh -c 'command -v cluster-render >/dev/null 2>&1 && cluster-render status; cat /run/cluster-render/status.txt 2>/dev/null'
run_capture final_processes ps w
run_capture final_dmesg dmesg

# One-time retrieval of persisted DCSM2 Lab logs after the capture window; no tail/follow.
collect_dcsm2_lab_logs saved
# Copy existing and rotated diagnostics without modifying originals. Include compressed rotations.
find /var/log /var/opt /tmp /var/tmp -type f 2>/dev/null |
  grep -Ei 'dcsm|ramses|cluster.?render|kombi|instrument.?cluster|dkombi|apex.?dash|oap' |
  while IFS= read -r F; do
    SAFE="$(echo "$F" | sed 's#/#_#g')"
    cp -p "$F" "$BASE/logs/$SAFE" 2>/dev/null || true
  done

# Stop background followers cleanly.
for P in $PIDS; do kill "$P" 2>/dev/null || true; done
sleep 1

{
  echo "Apex Dash / MGU diagnostic bundle"
  echo "Started: $START_TEXT"
  echo "Finished: $(date 2>/dev/null)"
  echo "Duration requested: $DURATION seconds"
  echo "Hostname: $(hostname 2>/dev/null)"
  echo "Kernel: $(uname -a 2>/dev/null)"
  echo "User: $(id 2>/dev/null)"
  echo
  echo "Privacy: bundle can contain vehicle/app diagnostics and system identifiers."
  echo "Review before sharing publicly."
} > "$BASE/README.txt"

ARCHIVE="$BASE.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$BASE")" "$(basename "$BASE")" 2>/dev/null || {
  echo "ERROR: tar archive creation failed" >&2
  exit 1
}
echo "$ARCHIVE"
REMOTE_SCRIPT
)" || { echo "Remote collection failed. Check SSH access and try root@MGU." >&2; exit 1; }

[[ -n "$REMOTE_ARCHIVE" ]] || { echo "MGU did not return an archive path." >&2; exit 1; }
echo "Downloading diagnostic bundle..."
scp "${SCP_OPTS[@]}" "$HOST:$REMOTE_ARCHIVE" "$LOCAL_ARCHIVE"
if [[ "$KEEP_REMOTE" -eq 0 ]]; then
  ssh "${SSH_OPTS[@]}" "$HOST" "rm -f '$REMOTE_ARCHIVE'; rm -rf '${REMOTE_ARCHIVE%.tar.gz}'" >/dev/null 2>&1 || true
fi

echo
echo "Done:"
echo "  $LOCAL_ARCHIVE"
echo "Send this archive here. Do not post it publicly without reviewing it first."
 |
  while IFS= read -r F; do
    SAFE="$(echo "$F" | sed 's#/#_#g')"
    cp -p "$F" "$BASE/logs/$SAFE" 2>/dev/null || true
  done
if command -v journalctl >/dev/null 2>&1; then
  journalctl -u cluster-render.service --since "@$START_EPOCH" --no-pager > "$BASE/logs/cluster-render-journal.window" 2>&1
  journalctl --since "@$START_EPOCH" --no-pager -o short-precise > "$BASE/logs/system-journal.window" 2>&1
  grep -Ei 'apex_dash|apex dash|cluster-render|DCSM2|RAMSES|oap_|watchdog|kombi|instrument' "$BASE/logs/system-journal.window" > "$BASE/logs/relevant-system-journal.log" 2>&1 || true
fi

# Stop background followers cleanly.
for P in $PIDS; do kill "$P" 2>/dev/null || true; done
sleep 1

{
  echo "Apex Dash / MGU diagnostic bundle"
  echo "Started: $START_TEXT"
  echo "Finished: $(date 2>/dev/null)"
  echo "Duration requested: $DURATION seconds"
  echo "Hostname: $(hostname 2>/dev/null)"
  echo "Kernel: $(uname -a 2>/dev/null)"
  echo "User: $(id 2>/dev/null)"
  echo
  echo "Privacy: bundle can contain vehicle/app diagnostics and system identifiers."
  echo "Review before sharing publicly."
} > "$BASE/README.txt"

ARCHIVE="$BASE.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$BASE")" "$(basename "$BASE")" 2>/dev/null || {
  echo "ERROR: tar archive creation failed" >&2
  exit 1
}
echo "$ARCHIVE"
REMOTE_SCRIPT
)" || { echo "Remote collection failed. Check SSH access and try root@MGU." >&2; exit 1; }

[[ -n "$REMOTE_ARCHIVE" ]] || { echo "MGU did not return an archive path." >&2; exit 1; }
echo "Downloading diagnostic bundle..."
scp "${SCP_OPTS[@]}" "$HOST:$REMOTE_ARCHIVE" "$LOCAL_ARCHIVE"
if [[ "$KEEP_REMOTE" -eq 0 ]]; then
  ssh "${SSH_OPTS[@]}" "$HOST" "rm -f '$REMOTE_ARCHIVE'; rm -rf '${REMOTE_ARCHIVE%.tar.gz}'" >/dev/null 2>&1 || true
fi

echo
echo "Done:"
echo "  $LOCAL_ARCHIVE"
echo "Send this archive here. Do not post it publicly without reviewing it first."
