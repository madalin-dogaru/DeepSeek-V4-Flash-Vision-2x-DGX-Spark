#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_IMAGE="${OFFICIAL_VISION_BASE_IMAGE:-vllm/vllm-openai@sha256:8568b4bbc821903d93a0a9c17dd80382fdc0ba78eaa128e3eb5cb71c3bf06b79}"
BASE_OVERLAY_IMAGE="${OFFICIAL_VISION_BASE_OVERLAY_IMAGE:-local/deepseek-v4-flash-vision:base-vllm-5ab628dd1-fi-26fabfe-gb10}"
FLASHINFER_COMMIT="${OFFICIAL_VISION_FLASHINFER_COMMIT:-26fabfe93ab7e866b1a3b581ca6ba2b984d49706}"
FLASHINFER_ARCHIVE_SHA256="${OFFICIAL_VISION_FLASHINFER_ARCHIVE_SHA256:-e007f4611041cf4015224044fbe4b53a3074561626362accc542093c4757a5ad}"
VLLM_COMMIT="${OFFICIAL_VLLM_COMMIT:-1356635d837c4ef002ec98c1a0296e7ff60be3c1}"
VLLM_VERSION="${OFFICIAL_VLLM_VERSION:-0.28.1rc1.dev317+g1356635d8}"
VLLM_WHEEL_URL="${OFFICIAL_VLLM_WHEEL_URL:-https://wheels.vllm.ai/1356635d837c4ef002ec98c1a0296e7ff60be3c1/vllm-0.28.1rc1.dev317%2Bg1356635d8-cp38-abi3-manylinux_2_28_aarch64.whl}"
VLLM_WHEEL_SHA256="${OFFICIAL_VLLM_WHEEL_SHA256:-1928aee68356885d7eb696aa0ed226dfa537e00721c9c5376fafddc04490d198}"
VLLM_PATCH_COMMIT="${OFFICIAL_VLLM_PATCH_COMMIT:-a5f98b4ce2b926da08d6c13527d842d2410be21e}"
VLLM_PATCH_SHA256="${OFFICIAL_VLLM_PATCH_SHA256:-4fecb840fcd985eeada0538202f920e9293d8ecb7ce9c0cb8337ed7703cff4d4}"
IMAGE="${OFFICIAL_VISION_IMAGE:-local/deepseek-v4-flash-vision:vllm-1356635-pr54631-fi-26fabfe-gb10}"
SYNC_WORKER=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--sync-worker]

Builds and verifies the pinned DeepSeek Vision runtime for two GB10 systems.
  --sync-worker  stream the verified image to the worker over the cluster fabric
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

# Preserve the proven FlashInfer SM121 implementation while moving vLLM itself
# to the post-Vision-merge wheel used by the validated production runtime.
docker build \
  --file "$SCRIPT_DIR/recipe/official-vision/Dockerfile" \
  --build-arg "VLLM_BASE_IMAGE=$BASE_IMAGE" \
  --build-arg "FLASHINFER_COMMIT=$FLASHINFER_COMMIT" \
  --build-arg "FLASHINFER_ARCHIVE_SHA256=$FLASHINFER_ARCHIVE_SHA256" \
  --tag "$BASE_OVERLAY_IMAGE" \
  "$SCRIPT_DIR"

EXPECTED_FLASHINFER_COMMIT="$FLASHINFER_COMMIT" \
  "$SCRIPT_DIR/scripts/verify-official-vision-image.sh" "$BASE_OVERLAY_IMAGE"

docker build \
  --file "$SCRIPT_DIR/recipe/official-vision/Dockerfile.current" \
  --build-arg "VLLM_BASE_IMAGE=$BASE_OVERLAY_IMAGE" \
  --build-arg "VLLM_COMMIT=$VLLM_COMMIT" \
  --build-arg "VLLM_VERSION=$VLLM_VERSION" \
  --build-arg "VLLM_WHEEL_URL=$VLLM_WHEEL_URL" \
  --build-arg "VLLM_WHEEL_SHA256=$VLLM_WHEEL_SHA256" \
  --build-arg "VLLM_PATCH_COMMIT=$VLLM_PATCH_COMMIT" \
  --build-arg "VLLM_PATCH_SHA256=$VLLM_PATCH_SHA256" \
  --tag "$IMAGE" \
  "$SCRIPT_DIR"

EXPECTED_VLLM_COMMIT="$VLLM_COMMIT" \
EXPECTED_VLLM_VERSION="$VLLM_VERSION" \
EXPECTED_FLASHINFER_COMMIT="$FLASHINFER_COMMIT" \
EXPECTED_VLLM_PATCH_COMMIT="$VLLM_PATCH_COMMIT" \
EXPECTED_VLLM_PATCH_SHA256="$VLLM_PATCH_SHA256" \
  "$SCRIPT_DIR/scripts/verify-current-vision-image.sh" "$IMAGE"

if [ "$SYNC_WORKER" = "1" ]; then
  ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi
  : "${WORKER_HOST:?WORKER_HOST must be set for --sync-worker}"
  sync_host="${WORKER_IMAGE_SYNC_HOST:-${WORKER_VLLM_HOST_IP:-$WORKER_HOST}}"
  echo "Streaming $IMAGE to $sync_host..."
  if command -v zstd >/dev/null && \
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$sync_host" command -v zstd >/dev/null; then
    docker save "$IMAGE" | zstd -T0 -3 | \
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$sync_host" 'zstd -d -T0 | docker load'
  else
    docker save "$IMAGE" | \
      ssh -o BatchMode=yes -o ConnectTimeout=10 "$sync_host" docker load
  fi
  local_image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  worker_image_id="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$sync_host" \
    "docker image inspect '$IMAGE' --format '{{.Id}}'")"
  if [ "$local_image_id" != "$worker_image_id" ]; then
    echo "image mismatch after worker sync: $local_image_id != $worker_image_id" >&2
    exit 1
  fi
  echo "Worker image loaded and verified: $sync_host/$IMAGE"
fi

echo "$IMAGE"
