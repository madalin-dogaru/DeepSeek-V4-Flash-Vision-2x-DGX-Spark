#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPERVISOR="$SCRIPT_DIR/supervise-dspark-cluster.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dspark-supervisor-test.XXXXXX")"
SUPERVISOR_PID=""

cleanup() {
  if [ -n "$SUPERVISOR_PID" ] && kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
    kill -KILL "$SUPERVISOR_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

cat > "$TMP_DIR/test.env" <<EOF
WORKER_HOST=unused
DSPARK_RESTART_POLICY=no
EOF

cat > "$TMP_DIR/start.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
trap 'printf terminated > "$TMP_DIR/start-terminated"; exit 0' TERM
touch "$TMP_DIR/start-entered"
while :; do sleep 1; done
EOF

cat > "$TMP_DIR/stop.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "$TMP_DIR/stop-called"
EOF
chmod +x "$TMP_DIR/start.sh" "$TMP_DIR/stop.sh"

ENV_FILE="$TMP_DIR/test.env" \
START_SCRIPT="$TMP_DIR/start.sh" \
STOP_SCRIPT="$TMP_DIR/stop.sh" \
DSPARK_SUPERVISOR_LOCK_FILE="$TMP_DIR/lock" \
DSPARK_SUPERVISOR_INCIDENT_DIR="$TMP_DIR/incidents" \
  "$SUPERVISOR" > "$TMP_DIR/output.log" 2>&1 &
SUPERVISOR_PID=$!

for _ in $(seq 1 50); do
  [ -e "$TMP_DIR/start-entered" ] && break
  sleep 0.1
done
[ -e "$TMP_DIR/start-entered" ] || { cat "$TMP_DIR/output.log"; exit 1; }

kill -TERM "$SUPERVISOR_PID"
for _ in $(seq 1 100); do
  kill -0 "$SUPERVISOR_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$SUPERVISOR_PID" 2>/dev/null; then
  echo "supervisor did not stop within 10 seconds" >&2
  exit 1
fi
wait "$SUPERVISOR_PID"
SUPERVISOR_PID=""

[ -e "$TMP_DIR/start-terminated" ] || { echo "startup process group did not receive SIGTERM" >&2; exit 1; }
[ -e "$TMP_DIR/stop-called" ] || { echo "coordinated stop was not called" >&2; exit 1; }

# Exercise the other EXIT path: startup has completed, a steady-state worker
# failure is confirmed, and no startup process remains to stop. This catches a
# non-zero helper return aborting the EXIT trap under `set -e`.
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/docker" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = inspect ] && [ "\${2:-}" = -f ]; then
  echo true
fi
exit 0
EOF
cat > "$TMP_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP_DIR/start-complete.sh" <<EOF
#!/usr/bin/env bash
touch "$TMP_DIR/steady-started"
EOF
cat > "$TMP_DIR/stop-steady.sh" <<EOF
#!/usr/bin/env bash
touch "$TMP_DIR/steady-stop-called"
EOF
chmod +x "$TMP_DIR/bin/docker" "$TMP_DIR/bin/curl" "$TMP_DIR/bin/ssh" \
  "$TMP_DIR/start-complete.sh" "$TMP_DIR/stop-steady.sh"

set +e
PATH="$TMP_DIR/bin:$PATH" \
ENV_FILE="$TMP_DIR/test.env" \
START_SCRIPT="$TMP_DIR/start-complete.sh" \
STOP_SCRIPT="$TMP_DIR/stop-steady.sh" \
DSPARK_SUPERVISOR_LOCK_FILE="$TMP_DIR/steady-lock" \
DSPARK_SUPERVISOR_INCIDENT_DIR="$TMP_DIR/incidents" \
DSPARK_SUPERVISOR_POLL_SECONDS=1 \
DSPARK_SUPERVISOR_FAILURE_THRESHOLD=1 \
  "$SUPERVISOR" > "$TMP_DIR/steady-output.log" 2>&1
steady_rc=$?
set -e

[ "$steady_rc" -eq 1 ] || { cat "$TMP_DIR/steady-output.log"; exit 1; }
[ -e "$TMP_DIR/steady-started" ] || { echo "steady-state startup did not complete" >&2; exit 1; }
[ -e "$TMP_DIR/steady-stop-called" ] || { echo "steady-state failure skipped coordinated stop" >&2; exit 1; }
find "$TMP_DIR/incidents" -maxdepth 1 -name '*-head-state.log' -print -quit | grep -q . || {
  echo "steady-state failure did not preserve incident evidence" >&2
  exit 1
}

echo "Supervisor startup and steady-state shutdown regressions passed."
