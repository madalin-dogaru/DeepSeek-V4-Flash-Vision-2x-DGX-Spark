#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.official-vision.yml"
EXPECTED_REVISION="e46e16bf6035c6f317eb2ac7458eb0362926d402"
export EXPECTED_REVISION

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

NODE_RANK=0 HEADLESS='' VLLM_HOST_IP="$VLLM_HOST_IP" DSPARK_RESTART_POLICY=no \
  docker compose -p deepseek-v4-flash --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" config --format json \
  | python3 -c '
import json
import os
import sys

config = json.load(sys.stdin)
service = config["services"]["vllm-dspark"]
command = service["command"][2]
runtime_command = command.replace("$$", "$")
expected_revision = os.environ["EXPECTED_REVISION"]

assert service["image"] == "local/deepseek-v4-flash-vision:vllm-5ab628dd1-fi-26fabfe-gb10"
assert service["environment"]["DSPARK_MODEL_OFFICIAL"] == "deepseek-ai/DeepSeek-V4-Flash-Vision-Exp"
assert service["environment"]["DSPARK_REVISION"] == expected_revision
required = (
    "--enable-expert-parallel",
    "--kv-cache-dtype fp8",
    "--max-model-len \"1048576\"",
    "--max-num-seqs 1",
    "\"num_speculative_tokens\":%s",
    "\"enable_adaptive_verification\":false",
    "--tokenizer-mode deepseek_v4",
    "--tool-call-parser deepseek_v4",
    "--reasoning-parser deepseek_v4",
    "--no-enable-flashinfer-autotune",
    "--nnodes 2",
    "--node-rank \"0\"",
)
for value in required:
    assert value in command, value
assert "--revision \"${DSPARK_REVISION}\"" in runtime_command
assert "\"revision\":\"%s\"" in runtime_command
assert "${DSPARK_MODEL_OFFICIAL}" in runtime_command
assert "${DSPARK_REVISION}" in runtime_command
assert "\"enable_adaptive_verification\":true" not in command
assert "--enable-flashinfer-autotune" not in command
assert (
    service["environment"]["FLASHINFER_WORKSPACE_BASE"]
    == "/cache/huggingface/flashinfer-official-4802-gb10-stable"
)
assert service["environment"]["NCCL_IB_HCA"] == "rocep1s0f0,roceP2p1s0f0"
assert service["environment"]["NCCL_IB_MERGE_NICS"] == "1"

rendered = json.dumps(config).lower()
for forbidden in ("hotfix-dsv4-vision-exp", "nvfp4_ds_mla", "qwen"):
    assert forbidden not in rendered, forbidden
'

missing_revision_env="$(mktemp)"
trap 'rm -f "$missing_revision_env"' EXIT
grep -v '^DSPARK_REVISION=' "$ENV_FILE" > "$missing_revision_env"
if env -u DSPARK_REVISION NODE_RANK=0 HEADLESS='' VLLM_HOST_IP="$VLLM_HOST_IP" \
  DSPARK_RESTART_POLICY=no docker compose -p deepseek-v4-flash \
    --env-file "$missing_revision_env" -f "$COMPOSE_FILE" config --quiet \
    >/dev/null 2>&1; then
  echo "compose profile accepted a missing DSPARK_REVISION" >&2
  exit 1
fi

NODE_RANK=0 HEADLESS='' VLLM_HOST_IP="$VLLM_HOST_IP" DSPARK_RESTART_POLICY=no \
  docker compose -p deepseek-v4-flash --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" config --format json \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["vllm-dspark"]["command"][2].replace("$$", "$"))' \
  | bash -n

NODE_RANK=1 HEADLESS=1 VLLM_HOST_IP="$WORKER_VLLM_HOST_IP" DSPARK_RESTART_POLICY=no \
  docker compose -p deepseek-v4-flash --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" config --format json \
  | python3 -c '
import json
import os
import sys

service = json.load(sys.stdin)["services"]["vllm-dspark"]
command = service["command"][2]
assert "--node-rank \"1\"" in command
assert command.rstrip().endswith("--headless")
assert service["environment"]["VLLM_HOST_IP"] == "'"$WORKER_VLLM_HOST_IP"'"
assert service["environment"]["HEADLESS"] == "1"
assert service["environment"]["DSPARK_REVISION"] == os.environ["EXPECTED_REVISION"]
'

echo "Official DeepSeek Vision compose profile verified."
