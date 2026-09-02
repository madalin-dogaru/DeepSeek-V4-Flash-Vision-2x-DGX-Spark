#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: verify-official-vision-image.sh IMAGE}"
EXPECTED_VLLM="${EXPECTED_VLLM:-0.28.1rc1.dev137+g5ab628dd1}"
EXPECTED_FLASHINFER_COMMIT="${EXPECTED_FLASHINFER_COMMIT:-26fabfe93ab7e866b1a3b581ca6ba2b984d49706}"

docker image inspect "$IMAGE" >/dev/null

actual_commit="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "ai.dgx-spark.flashinfer.commit"}}')"
if [ "$actual_commit" != "$EXPECTED_FLASHINFER_COMMIT" ]; then
  echo "unexpected FlashInfer commit: $actual_commit" >&2
  exit 1
fi

docker run --rm --entrypoint python3 "$IMAGE" -c '
import importlib.metadata as metadata
import inspect
from pathlib import Path

import flashinfer

expected_vllm = "'"$EXPECTED_VLLM"'"
actual_vllm = metadata.version("vllm")
assert actual_vllm == expected_vllm, (actual_vllm, expected_vllm)

root = Path(inspect.getfile(flashinfer)).parent
required = (
    root / "mla" / "_sparse_mla_sm120.py",
    root / "mla" / "_sparse_mla_sm120_cpb.py",
    root / "mla" / "_sparse_mla_sm120_plan.py",
    root / "data" / "csrc" / "sparse_mla_sm120.cu",
    root / "data" / "include" / "flashinfer" / "attention" / "sparse_mla_sm120" / "model" / "model_type.h",
)
for path in required:
    assert path.is_file(), path

plan = (root / "mla" / "_sparse_mla_sm120_plan.py").read_text()
assert "_DecodeDispatchEnvelope" in plan

aot = Path("/usr/local/lib/python3.12/dist-packages/flashinfer_jit_cache/jit_cache/sparse_mla_sm120/sparse_mla_sm120.so")
assert not aot.exists(), aot
print(f"verified vLLM={actual_vllm} flashinfer_source={root}")
'

echo "Official DeepSeek Vision GB10 image verified: $IMAGE"
