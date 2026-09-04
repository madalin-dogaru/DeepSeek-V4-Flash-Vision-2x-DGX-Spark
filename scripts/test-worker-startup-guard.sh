#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LAUNCHER="$SCRIPT_DIR/start-official-vision-runtime.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dspark-worker-guard-test.XXXXXX")"

cleanup() {
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/test.env" <<EOF
WORKER_HOST=worker-test
WORKER_SCRIPT_DIR=/tmp/worker-test
MASTER_ADDR=10.100.32.1
VLLM_HOST_IP=10.100.32.1
WORKER_VLLM_HOST_IP=10.100.32.2
DSPARK_MODEL_OFFICIAL=deepseek-ai/DeepSeek-V4-Flash-Vision-Exp
DSPARK_REVISION=e46e16bf6035c6f317eb2ac7458eb0362926d402
OFFICIAL_VISION_IMAGE=test/image:latest
OFFICIAL_MAX_MODEL_LEN=1048576
OFFICIAL_GPU_MEMORY_UTILIZATION=0.82
OFFICIAL_MTP_NUM_TOKENS=3
DSPARK_RESTART_POLICY=no
EOF

cat > "$TMP_DIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$TMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
exit 255
EOF
chmod +x "$TMP_DIR/bin/docker" "$TMP_DIR/bin/ssh"

set +e
PATH="$TMP_DIR/bin:$PATH" \
ENV_FILE="$TMP_DIR/test.env" \
WORKER_READY_ATTEMPTS=1 \
WORKER_READY_SECONDS=1 \
  "$LAUNCHER" > "$TMP_DIR/unreachable.log" 2>&1
unreachable_rc=$?
set -e

[ "$unreachable_rc" -eq 1 ] || { cat "$TMP_DIR/unreachable.log"; exit 1; }
grep -q "did not become ready over SSH with Docker available" "$TMP_DIR/unreachable.log" || {
  cat "$TMP_DIR/unreachable.log"
  exit 1
}

cat > "$TMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"docker info"*) exit 0 ;;
  *"docker ps"*) exit 42 ;;
esac
exit 0
EOF
chmod +x "$TMP_DIR/bin/ssh"

set +e
PATH="$TMP_DIR/bin:$PATH" \
ENV_FILE="$TMP_DIR/test.env" \
WORKER_READY_ATTEMPTS=1 \
WORKER_READY_SECONDS=1 \
  "$LAUNCHER" > "$TMP_DIR/query-failed.log" 2>&1
query_failed_rc=$?
set -e

[ "$query_failed_rc" -eq 1 ] || { cat "$TMP_DIR/query-failed.log"; exit 1; }
grep -q "failed to query worker container state" "$TMP_DIR/query-failed.log" || {
  cat "$TMP_DIR/query-failed.log"
  exit 1
}

cat > "$TMP_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"docker info"*) exit 0 ;;
  *"docker ps"*) printf '%s\n' stale-worker-container ;;
esac
exit 0
EOF
chmod +x "$TMP_DIR/bin/ssh"

set +e
PATH="$TMP_DIR/bin:$PATH" \
ENV_FILE="$TMP_DIR/test.env" \
WORKER_READY_ATTEMPTS=1 \
WORKER_READY_SECONDS=1 \
  "$LAUNCHER" > "$TMP_DIR/stale.log" 2>&1
stale_rc=$?
set -e

[ "$stale_rc" -eq 2 ] || { cat "$TMP_DIR/stale.log"; exit 1; }
grep -q "refusing to replace the running worker container" "$TMP_DIR/stale.log" || {
  cat "$TMP_DIR/stale.log"
  exit 1
}

echo "Worker reachability and stale-rank startup guards passed."
