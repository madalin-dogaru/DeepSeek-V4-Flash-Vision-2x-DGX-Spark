#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
ENV_FILE="$SOURCE_ENV_FILE"
START_SCRIPT="${START_SCRIPT:-$SCRIPT_DIR/start-official-vision-runtime.sh}"
STOP_SCRIPT="${STOP_SCRIPT:-$SCRIPT_DIR/stop-official-vision-runtime.sh}"
POLL_SECONDS="${DSPARK_SUPERVISOR_POLL_SECONDS:-10}"
FAILURE_THRESHOLD="${DSPARK_SUPERVISOR_FAILURE_THRESHOLD:-6}"
INCIDENT_LIMIT="${DSPARK_SUPERVISOR_INCIDENT_LIMIT:-10}"
INCIDENT_DIR="${DSPARK_SUPERVISOR_INCIDENT_DIR:-$SCRIPT_DIR/logs/incidents}"
LOCK_FILE="${DSPARK_SUPERVISOR_LOCK_FILE:-/tmp/deepseek-v4-dspark-cluster.lock}"

if [ -f "$SOURCE_ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  source "$SOURCE_ENV_FILE"
  set +a
fi

# The upstream launcher sources its env file after process variables, so a
# systemd Environment= override alone is insufficient. Give the launcher a
# private copy with per-container restarts disabled.
RUNTIME_ENV="$(mktemp "${TMPDIR:-/tmp}/dspark-supervisor-env.XXXXXX")"
awk '
  BEGIN { replaced = 0 }
  /^DSPARK_RESTART_POLICY=/ {
    print "DSPARK_RESTART_POLICY=no"
    replaced = 1
    next
  }
  { print }
  END {
    if (!replaced) print "DSPARK_RESTART_POLICY=no"
  }
' "$SOURCE_ENV_FILE" > "$RUNTIME_ENV"
chmod 600 "$RUNTIME_ENV"
ENV_FILE="$RUNTIME_ENV"
DSPARK_RESTART_POLICY=no
export ENV_FILE DSPARK_RESTART_POLICY
trap 'rm -f -- "$RUNTIME_ENV"' EXIT

: "${WORKER_HOST:?WORKER_HOST must be set in $ENV_FILE or the environment}"
PROJECT_NAME="${PROJECT_NAME:-deepseek-v4-flash}"
HEAD_CONTAINER="${PROJECT_NAME}-vllm-dspark-1"
WORKER_CONTAINER="${PROJECT_NAME}-vllm-dspark-1"
VLLM_PORT="${VLLM_PORT:-8888}"
HEALTH_URL="${DSPARK_SUPERVISOR_HEALTH_URL:-http://127.0.0.1:${VLLM_PORT}/health}"

case "$POLL_SECONDS:$FAILURE_THRESHOLD:$INCIDENT_LIMIT" in
  *[!0-9:]*|0:*|*:0:*|*:*:0)
    echo "Supervisor intervals and limits must be positive integers." >&2
    exit 2
    ;;
esac

command -v docker >/dev/null
command -v curl >/dev/null
command -v flock >/dev/null
command -v setsid >/dev/null
command -v ssh >/dev/null
[ -x "$START_SCRIPT" ] || { echo "Missing executable launcher: $START_SCRIPT" >&2; exit 2; }
[ -x "$STOP_SCRIPT" ] || { echo "Missing executable stop script: $STOP_SCRIPT" >&2; exit 2; }

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another DSpark cluster supervisor already owns $LOCK_FILE." >&2
  exit 2
fi

stopping=0
failure_reason=""
startup_pid=""

container_running_local() {
  [ "$(docker inspect -f '{{.State.Running}}' "$HEAD_CONTAINER" 2>/dev/null || true)" = "true" ]
}

container_running_remote() {
  [ "$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$WORKER_HOST" \
    "docker inspect -f '{{.State.Running}}' '$WORKER_CONTAINER' 2>/dev/null" 2>/dev/null || true)" = "true" ]
}

head_healthy() {
  curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1
}

preserve_incident() {
  local stamp base
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  base="$INCIDENT_DIR/$stamp"
  mkdir -p "$INCIDENT_DIR"
  {
    printf 'time=%s\nreason=%s\nhead=%s\nworker=%s\n' \
      "$stamp" "$failure_reason" "$HEAD_CONTAINER" "$WORKER_HOST/$WORKER_CONTAINER"
    docker inspect "$HEAD_CONTAINER" 2>&1 || true
  } > "${base}-head-state.log"
  docker logs --timestamps --tail 500 "$HEAD_CONTAINER" > "${base}-head.log" 2>&1 || true
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$WORKER_HOST" \
    "docker inspect '$WORKER_CONTAINER'; docker logs --timestamps --tail 500 '$WORKER_CONTAINER'" \
    > "${base}-worker.log" 2>&1 || true

  # Keep incident evidence bounded. Each incident creates three files.
  find "$INCIDENT_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' \
    | sort -nr \
    | awk -v keep="$((INCIDENT_LIMIT * 3))" 'NR > keep {sub(/^[^ ]+ /, ""); print}' \
    | while IFS= read -r old; do rm -f -- "$old"; done
  echo "Preserved cluster failure evidence under $base*.log" >&2
}

stop_pair() {
  if [ "$stopping" = "1" ]; then
    return
  fi
  stopping=1
  "$STOP_SCRIPT" || echo "WARN: coordinated DSpark stop reported a failure." >&2
}

stop_startup() {
  [ -n "$startup_pid" ] || return 0
  if kill -0 "$startup_pid" 2>/dev/null; then
    kill -TERM -- "-$startup_pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$startup_pid" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$startup_pid" 2>/dev/null; then
      kill -KILL -- "-$startup_pid" 2>/dev/null || true
    fi
  fi
  wait "$startup_pid" 2>/dev/null || true
  startup_pid=""
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  stop_startup
  if [ -n "$failure_reason" ]; then
    preserve_incident
  fi
  stop_pair
  rm -f -- "$RUNTIME_ENV"
  exit "$rc"
}

on_signal() {
  failure_reason=""
  exit 0
}

trap on_exit EXIT
trap on_signal INT TERM HUP

if [ "${DSPARK_RESTART_POLICY:-}" != "no" ]; then
  echo "Refusing unsafe per-container restart policy '${DSPARK_RESTART_POLICY:-unset}'." >&2
  echo "Set DSPARK_RESTART_POLICY=no so the supervisor owns both TP ranks." >&2
  exit 2
fi

echo "Starting DSpark TP cluster under coordinated supervision..."
setsid --wait "$START_SCRIPT" &
startup_pid=$!
if wait "$startup_pid"; then
  startup_rc=0
else
  startup_rc=$?
fi
startup_pid=""
if [ "$startup_rc" -ne 0 ]; then
  failure_reason="cluster startup failed with exit status $startup_rc"
  exit "$startup_rc"
fi
echo "DSpark TP cluster is healthy; monitoring both ranks every ${POLL_SECONDS}s."

failures=0
while sleep "$POLL_SECONDS"; do
  reasons=()
  container_running_local || reasons+=("head container is not running")
  container_running_remote || reasons+=("worker container is not running or unreachable")
  head_healthy || reasons+=("head health endpoint is unavailable")

  if [ "${#reasons[@]}" -eq 0 ]; then
    if [ "$failures" -gt 0 ]; then
      echo "Cluster health recovered after $failures failed probe(s)."
    fi
    failures=0
    continue
  fi

  failures=$((failures + 1))
  printf -v failure_reason '; %s' "${reasons[@]}"
  failure_reason="${failure_reason:2}"
  echo "Cluster health probe $failures/$FAILURE_THRESHOLD failed: $failure_reason" >&2
  if [ "$failures" -ge "$FAILURE_THRESHOLD" ]; then
    echo "Cluster failure confirmed; preserving evidence and recycling both TP ranks." >&2
    exit 1
  fi
done
