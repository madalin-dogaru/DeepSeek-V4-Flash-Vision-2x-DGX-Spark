#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_IMAGE="${OFFICIAL_VISION_BASE_IMAGE:-vllm/vllm-openai@sha256:8568b4bbc821903d93a0a9c17dd80382fdc0ba78eaa128e3eb5cb71c3bf06b79}"
FLASHINFER_COMMIT="${OFFICIAL_VISION_FLASHINFER_COMMIT:-26fabfe93ab7e866b1a3b581ca6ba2b984d49706}"
FLASHINFER_ARCHIVE_SHA256="${OFFICIAL_VISION_FLASHINFER_ARCHIVE_SHA256:-e007f4611041cf4015224044fbe4b53a3074561626362accc542093c4757a5ad}"
IMAGE="${OFFICIAL_VISION_IMAGE:-local/deepseek-v4-flash-vision:vllm-5ab628dd1-fi-26fabfe-gb10}"
SYNC_WORKER=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--sync-worker]

Builds and verifies the digest-pinned official DeepSeek Vision GB10 image.
  --sync-worker  stream the verified image to WORKER_HOST after building
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --sync-worker) SYNC_WORKER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || docker pull "$BASE_IMAGE"

docker build \
  --file "$SCRIPT_DIR/recipe/official-vision/Dockerfile" \
  --build-arg "VLLM_BASE_IMAGE=$BASE_IMAGE" \
  --build-arg "FLASHINFER_COMMIT=$FLASHINFER_COMMIT" \
  --build-arg "FLASHINFER_ARCHIVE_SHA256=$FLASHINFER_ARCHIVE_SHA256" \
  --tag "$IMAGE" \
  "$SCRIPT_DIR"

EXPECTED_FLASHINFER_COMMIT="$FLASHINFER_COMMIT" \
  "$SCRIPT_DIR/scripts/verify-official-vision-image.sh" "$IMAGE"

if [ "$SYNC_WORKER" = "1" ]; then
  ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
  : "${WORKER_HOST:?WORKER_HOST must be set for --sync-worker}"
  echo "Streaming $IMAGE to $WORKER_HOST..."
  docker save "$IMAGE" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_HOST" docker load
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$WORKER_HOST" \
    "docker image inspect '$IMAGE' >/dev/null"
  echo "Worker image loaded and inspected: $WORKER_HOST/$IMAGE"
fi

echo "$IMAGE"
