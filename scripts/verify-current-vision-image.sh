#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE="${1:?usage: verify-current-vision-image.sh IMAGE}"
EXPECTED_VLLM_COMMIT="${EXPECTED_VLLM_COMMIT:-1356635d837c4ef002ec98c1a0296e7ff60be3c1}"
EXPECTED_VLLM_VERSION="${EXPECTED_VLLM_VERSION:-0.28.1rc1.dev317+g1356635d8}"
EXPECTED_FLASHINFER_COMMIT="${EXPECTED_FLASHINFER_COMMIT:-26fabfe93ab7e866b1a3b581ca6ba2b984d49706}"
EXPECTED_VLLM_PATCH_COMMIT="${EXPECTED_VLLM_PATCH_COMMIT:-a5f98b4ce2b926da08d6c13527d842d2410be21e}"
EXPECTED_VLLM_PATCH_SHA256="${EXPECTED_VLLM_PATCH_SHA256:-4fecb840fcd985eeada0538202f920e9293d8ecb7ce9c0cb8337ed7703cff4d4}"
REQUIRE_ADAPTIVE_VERIFICATION="${REQUIRE_ADAPTIVE_VERIFICATION:-false}"

case "$REQUIRE_ADAPTIVE_VERIFICATION" in
  true|false) ;;
  *) echo "REQUIRE_ADAPTIVE_VERIFICATION must be true or false" >&2; exit 2 ;;
esac

docker image inspect "$IMAGE" >/dev/null

label_value() {
  local suffix="$1" value
  value="$(docker image inspect "$IMAGE" \
    --format "{{index .Config.Labels \"ai.dgx-spark.${suffix}\"}}")"
  if [ -z "$value" ]; then
    value="$(docker image inspect "$IMAGE" \
      --format "{{index .Config.Labels \"ai.nyx.${suffix}\"}}")"
  fi
  printf '%s' "$value"
}

test "$(docker image inspect "$IMAGE" --format '{{.Architecture}}')" = "arm64"
test "$(label_value vllm.commit)" = "$EXPECTED_VLLM_COMMIT"
test "$(label_value flashinfer.commit)" = "$EXPECTED_FLASHINFER_COMMIT"
test "$(label_value vllm.patch.pr54631)" = "$EXPECTED_VLLM_PATCH_COMMIT"
test "$(label_value vllm.patch.pr54631.sha256)" = "$EXPECTED_VLLM_PATCH_SHA256"

docker run --rm \
  --env "EXPECTED_VLLM_VERSION=$EXPECTED_VLLM_VERSION" \
  --entrypoint python3 "$IMAGE" -c '
import importlib.metadata as metadata
import inspect
import os
from pathlib import Path

import flashinfer
from vllm.config.speculative import SpeculativeConfig
from vllm.models.deepseek_v4.nvidia.flashinfer_sparse import (
    DeepseekSparseSWAFlashInferMetadataBuilder,
    DeepseekV4FlashInferSparseMLAMetadataBuilder,
)
from vllm.models.deepseek_v4.nvidia.vl_model import (
    DeepseekV4ForConditionalGeneration,
)
from vllm.v1.attention.backend import AttentionCGSupport

expected = os.environ["EXPECTED_VLLM_VERSION"]
actual = metadata.version("vllm")
assert actual == expected, (actual, expected)
assert hasattr(SpeculativeConfig, "enable_adaptive_verification")
assert DeepseekV4ForConditionalGeneration is not None
assert (
    DeepseekV4FlashInferSparseMLAMetadataBuilder._cudagraph_support
    is AttentionCGSupport.ALWAYS
)
assert (
    DeepseekSparseSWAFlashInferMetadataBuilder._cudagraph_support
    is AttentionCGSupport.ALWAYS
)

root = Path(inspect.getfile(flashinfer)).parent
for path in (
    root / "mla" / "_sparse_mla_sm120.py",
    root / "mla" / "_sparse_mla_sm120_cpb.py",
    root / "mla" / "_sparse_mla_sm120_plan.py",
    root / "data" / "csrc" / "sparse_mla_sm120.cu",
):
    assert path.is_file(), path
print(
    f"verified vLLM={actual} vision=present "
    f"adaptive_api=present flashinfer={root}"
)
'

docker run --rm \
  --mount "type=bind,src=$SCRIPT_DIR/verify-vllm-pr54631.py,dst=/tmp/verify-vllm-pr54631.py,readonly" \
  --entrypoint python3 "$IMAGE" /tmp/verify-vllm-pr54631.py

adaptive_indexer_support="$(docker run --rm --gpus all --entrypoint python3 "$IMAGE" -c '
from vllm.v1.attention.backends.mla.indexer import DeepseekV4IndexerBackend

print(str(DeepseekV4IndexerBackend.supports_device_cpu_query_lens_mismatch()).lower())
' 2>/dev/null)"
case "$adaptive_indexer_support" in
  true|false) ;;
  *) echo "could not determine DeepSeek V4 adaptive-indexer support" >&2; exit 1 ;;
esac
if [ "$REQUIRE_ADAPTIVE_VERIFICATION" = "true" ] && [ "$adaptive_indexer_support" != "true" ]; then
  echo "adaptive verification is not supported by the DeepSeek V4 indexer on this GPU" >&2
  exit 1
fi
echo "DeepSeek V4 adaptive-indexer support on this GPU: $adaptive_indexer_support"

check_output="$(docker run --rm --entrypoint uv "$IMAGE" pip check 2>&1 || true)"
printf '%s\n' "$check_output"
test "$(printf '%s\n' "$check_output" | grep -c '^The package')" -eq 2
platform_warning="The package \`nvidia-cusparselt-cu13\` was built for a different platform"
torch_warning="The package \`torch\` requires \`nvidia-nccl-cu13==2.29.7 ; sys_platform == 'linux'\`, but \`2.30.7\` is installed"
printf '%s\n' "$check_output" | grep -Fqx "$platform_warning"
printf '%s\n' "$check_output" | grep -Fqx "$torch_warning"
echo "Current DeepSeek Vision GB10 image verified: $IMAGE"
