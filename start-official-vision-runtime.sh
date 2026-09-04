#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.official-vision.yml"
PROJECT_NAME="${PROJECT_NAME:-deepseek-v4-flash}"
SERVICE_NAME="vllm-dspark"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-120}"
WAIT_SECONDS="${WAIT_SECONDS:-15}"
WORKER_READY_ATTEMPTS="${WORKER_READY_ATTEMPTS:-60}"
WORKER_READY_SECONDS="${WORKER_READY_SECONDS:-2}"

[ -f "$SOURCE_ENV_FILE" ] || { echo "missing environment file: $SOURCE_ENV_FILE" >&2; exit 2; }
[ -f "$COMPOSE_FILE" ] || { echo "missing compose file: $COMPOSE_FILE" >&2; exit 2; }

set -a
# shellcheck disable=SC1090
source "$SOURCE_ENV_FILE"
set +a

IMAGE="${OFFICIAL_VISION_IMAGE:-local/deepseek-v4-flash-vision:vllm-1356635-pr54631-fi-26fabfe-gb10}"

: "${WORKER_HOST:?WORKER_HOST must be set}"
: "${WORKER_SCRIPT_DIR:?WORKER_SCRIPT_DIR must be set}"
: "${MASTER_ADDR:?MASTER_ADDR must be set}"
: "${VLLM_HOST_IP:?VLLM_HOST_IP must be set}"
: "${WORKER_VLLM_HOST_IP:?WORKER_VLLM_HOST_IP must be set}"
: "${DSPARK_MODEL_OFFICIAL:?DSPARK_MODEL_OFFICIAL must be set}"
: "${DSPARK_REVISION:?DSPARK_REVISION must be set}"

if [[ ! "$DSPARK_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  echo "DSPARK_REVISION must be an immutable 40-character lowercase commit hash" >&2
  exit 2
fi

case "${OFFICIAL_MTP_NUM_TOKENS:-3}" in
  3|5) ;;
  *) echo "OFFICIAL_MTP_NUM_TOKENS must be 3 or 5" >&2; exit 2 ;;
esac
case "${OFFICIAL_ADAPTIVE_VERIFICATION:-false}" in
  true|false) ;;
  *) echo "OFFICIAL_ADAPTIVE_VERIFICATION must be true or false" >&2; exit 2 ;;
esac
case "${VLLM_USE_BREAKABLE_CUDAGRAPH:-1}" in
  0|1) ;;
  *) echo "VLLM_USE_BREAKABLE_CUDAGRAPH must be 0 or 1" >&2; exit 2 ;;
esac
case "${OFFICIAL_MAX_MODEL_LEN:-1048576}" in
  ''|*[!0-9]*) echo "OFFICIAL_MAX_MODEL_LEN must be an integer" >&2; exit 2 ;;
esac
case "$WORKER_READY_ATTEMPTS:$WORKER_READY_SECONDS" in
  *[!0-9:]*|0:*|*:0)
    echo "WORKER_READY_ATTEMPTS and WORKER_READY_SECONDS must be positive integers" >&2
    exit 2
    ;;
esac
case "${VLLM_ADAPTIVE_VERIFICATION_PROFILE_CONTEXT_LEN:-131072}" in
  ''|*[!0-9]*) echo "VLLM_ADAPTIVE_VERIFICATION_PROFILE_CONTEXT_LEN must be an integer" >&2; exit 2 ;;
esac
case "${OFFICIAL_RUNTIME_CACHE_ROOT:-/cache/huggingface/runtime-cache/vllm-1356635-pr54631-sm121}" in
  /*) ;;
  *) echo "OFFICIAL_RUNTIME_CACHE_ROOT must be an absolute container path" >&2; exit 2 ;;
esac

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)
container_name="${PROJECT_NAME}-${SERVICE_NAME}-1"

worker_ready=false
for _ in $(seq 1 "$WORKER_READY_ATTEMPTS"); do
  if ssh "${ssh_opts[@]}" "$WORKER_HOST" \
    "docker info >/dev/null 2>&1" >/dev/null 2>&1; then
    worker_ready=true
    break
  fi
  sleep "$WORKER_READY_SECONDS"
done
if [ "$worker_ready" != true ]; then
  echo "worker $WORKER_HOST did not become ready over SSH with Docker available" >&2
  exit 1
fi

if docker ps -q --filter "name=^/${container_name}$" | grep -q .; then
  echo "refusing to replace the running head container; stop the cluster first" >&2
  exit 2
fi
# Expansion is intentionally local; the worker receives the resolved name.
# shellcheck disable=SC2029
if ! worker_container_id="$(ssh "${ssh_opts[@]}" "$WORKER_HOST" \
  "docker ps -q --filter 'name=^/${container_name}\$'")"; then
  echo "failed to query worker container state on $WORKER_HOST" >&2
  exit 1
fi
if [ -n "$worker_container_id" ]; then
  echo "refusing to replace the running worker container; stop the cluster first" >&2
  exit 2
fi

REQUIRE_ADAPTIVE_VERIFICATION="${OFFICIAL_ADAPTIVE_VERIFICATION:-false}" \
  "$SCRIPT_DIR/scripts/verify-current-vision-image.sh" "$IMAGE"

local_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
# Expansion is intentionally local; both nodes must inspect the same tag.
# shellcheck disable=SC2029
remote_image_id="$(ssh "${ssh_opts[@]}" "$WORKER_HOST" \
  "docker image inspect '$IMAGE' --format '{{.Id}}'")"
if [ "$local_image_id" != "$remote_image_id" ]; then
  echo "image mismatch between head and worker: $local_image_id != $remote_image_id" >&2
  exit 2
fi

scp "${ssh_opts[@]}" "$COMPOSE_FILE" \
  "$WORKER_HOST:$WORKER_SCRIPT_DIR/docker-compose.official-vision.yml"

compose_head=(docker compose -p "$PROJECT_NAME" --env-file "$SOURCE_ENV_FILE" -f "$COMPOSE_FILE")
worker_env="NODE_RANK=1 HEADLESS=1 VLLM_HOST_IP=$WORKER_VLLM_HOST_IP OFFICIAL_VISION_IMAGE=$OFFICIAL_VISION_IMAGE DSPARK_MODEL_OFFICIAL=$DSPARK_MODEL_OFFICIAL DSPARK_REVISION=$DSPARK_REVISION OFFICIAL_MAX_MODEL_LEN=$OFFICIAL_MAX_MODEL_LEN OFFICIAL_GPU_MEMORY_UTILIZATION=$OFFICIAL_GPU_MEMORY_UTILIZATION OFFICIAL_MTP_NUM_TOKENS=$OFFICIAL_MTP_NUM_TOKENS OFFICIAL_ADAPTIVE_VERIFICATION=${OFFICIAL_ADAPTIVE_VERIFICATION:-false} VLLM_ADAPTIVE_VERIFICATION_PROFILE_CONTEXT_LEN=${VLLM_ADAPTIVE_VERIFICATION_PROFILE_CONTEXT_LEN:-131072} OFFICIAL_RUNTIME_CACHE_ROOT=${OFFICIAL_RUNTIME_CACHE_ROOT:-/cache/huggingface/runtime-cache/vllm-1356635-pr54631-sm121} VLLM_USE_BREAKABLE_CUDAGRAPH=${VLLM_USE_BREAKABLE_CUDAGRAPH:-1} DSPARK_RESTART_POLICY=${DSPARK_RESTART_POLICY:-no}"
worker_compose="docker compose -p '$PROJECT_NAME' --env-file .env.dspark -f docker-compose.official-vision.yml"

NODE_RANK=0 HEADLESS='' VLLM_HOST_IP="$VLLM_HOST_IP" \
  "${compose_head[@]}" config --quiet
# Expansion is intentionally local so worker-specific values are explicit.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "$WORKER_HOST" \
  "cd '$WORKER_SCRIPT_DIR' && $worker_env $worker_compose config --quiet"

echo "Starting official vLLM worker on $WORKER_HOST..."
# Expansion is intentionally local so worker-specific values are explicit.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "$WORKER_HOST" \
  "cd '$WORKER_SCRIPT_DIR' && $worker_env $worker_compose up -d"

echo "Starting official vLLM head..."
NODE_RANK=0 HEADLESS='' VLLM_HOST_IP="$VLLM_HOST_IP" \
  "${compose_head[@]}" up -d

health_url="http://127.0.0.1:${VLLM_PORT:-8888}/health"
models_url="http://127.0.0.1:${VLLM_PORT:-8888}/v1/models"
for _ in $(seq 1 "$WAIT_ATTEMPTS"); do
  if curl -fsS --max-time 5 "$health_url" >/dev/null 2>&1; then
    curl -fsS --max-time 10 "$models_url" >/dev/null
    echo "Official DeepSeek Vision runtime is healthy: $models_url"
    exit 0
  fi
  if ! docker inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -qx true; then
    echo "head container stopped during startup" >&2
    docker logs --tail 300 "$container_name" >&2 || true
    exit 1
  fi
  sleep "$WAIT_SECONDS"
done

echo "official runtime did not become healthy before the startup deadline" >&2
docker logs --tail 300 "$container_name" >&2 || true
exit 1
