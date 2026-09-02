#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.official-vision.yml"
PROJECT_NAME="${PROJECT_NAME:-deepseek-v4-flash}"

set -a
# shellcheck disable=SC1090
source "$SOURCE_ENV_FILE"
set +a

: "${WORKER_HOST:?WORKER_HOST must be set}"
: "${WORKER_SCRIPT_DIR:?WORKER_SCRIPT_DIR must be set}"

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10)
container_name="${PROJECT_NAME}-vllm-dspark-1"

echo "Stopping official vLLM worker on $WORKER_HOST..."
# Expansion is intentionally local; the worker receives the resolved name.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "$WORKER_HOST" \
  "docker rm -f '$container_name' >/dev/null 2>&1 || true"
# Expansion is intentionally local; paths and project names come from the env.
# shellcheck disable=SC2029
ssh "${ssh_opts[@]}" "$WORKER_HOST" \
  "cd '$WORKER_SCRIPT_DIR' && docker compose -p '$PROJECT_NAME' --env-file .env.dspark -f docker-compose.official-vision.yml down --remove-orphans -t 1" \
  >/dev/null 2>&1 || true

echo "Stopping official vLLM head..."
docker rm -f "$container_name" >/dev/null 2>&1 || true
docker compose -p "$PROJECT_NAME" --env-file "$SOURCE_ENV_FILE" -f "$COMPOSE_FILE" \
  down --remove-orphans -t 1 >/dev/null 2>&1 || true
