#!/usr/bin/env bash
# Exercise the request shapes used by the single-session Vision profile.
# Failure is reported to the launcher but remains non-fatal to model startup.
set -u

BASE_URL="${1:-http://127.0.0.1:8888}"
MODEL="${2:-deepseek-v4-flash-vision-exp}"
CURL_BIN="${WARMUP_CURL:-curl}"
REQ_TIMEOUT="${DSPARK_WARMUP_REQ_TIMEOUT:-240}"
BATCH_TOKENS="${DSPARK_WARMUP_BATCH_TOKENS:-8192}"
SPEC_TOKENS="${DSPARK_WARMUP_SPEC_TOKENS:-3}"
WARMUP_VISION="${DSPARK_WARMUP_VISION:-1}"

case "$REQ_TIMEOUT:$BATCH_TOKENS" in
  *[!0-9:]*|0:*|*:0)
    echo "boot-shape-warmup: timeout and batch size must be positive integers" >&2
    exit 1
    ;;
esac
case "$SPEC_TOKENS" in
  3|5) ;;
  *) echo "boot-shape-warmup: speculative token count must be 3 or 5" >&2; exit 1 ;;
esac
case "$WARMUP_VISION" in
  0|1) ;;
  *) echo "boot-shape-warmup: DSPARK_WARMUP_VISION must be 0 or 1" >&2; exit 1 ;;
esac

AUTH_ARGS=()
if [ -n "${DSPARK_WARMUP_BEARER:-}" ]; then
  AUTH_ARGS=(-H "Authorization: Bearer ${DSPARK_WARMUP_BEARER}")
elif [ -n "${VLLM_API_KEY:-}" ]; then
  AUTH_ARGS=(-H "Authorization: Bearer ${VLLM_API_KEY}")
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
errors="$tmpdir/errors"
total=0
passed=0

record_request() {
  local endpoint=$1 payload=$2 label=$3 started elapsed
  total=$((total + 1))
  started=$(date +%s)
  if "$CURL_BIN" -fsS --max-time "$REQ_TIMEOUT" "${AUTH_ARGS[@]}" \
      "$BASE_URL$endpoint" -H 'Content-Type: application/json' \
      -d "$payload" >/dev/null 2>>"$errors"; then
    passed=$((passed + 1))
    elapsed=$(( $(date +%s) - started ))
    echo "  $label: ok (${elapsed}s)"
  else
    elapsed=$(( $(date +%s) - started ))
    echo "  $label: FAILED (${elapsed}s)" >&2
  fi
}

repeat_word() {
  local count=$1 result="hello" i
  for ((i = 1; i < count; i++)); do result="$result hello"; done
  printf '%s' "$result"
}

next_pow2() {
  local n=$1 value=1
  while [ "$value" -lt "$n" ]; do value=$((value * 2)); done
  printf '%s' "$value"
}

warm_ladder_rung() {
  local count=$1 prompt response actual block payload
  prompt=$(repeat_word "$count")
  block=$(next_pow2 $((count + 1 + SPEC_TOKENS)))
  if ! response=$("$CURL_BIN" -fsS --max-time 30 "${AUTH_ARGS[@]}" \
      "$BASE_URL/tokenize" -H 'Content-Type: application/json' \
      -d '{"model":"'"$MODEL"'","prompt":"'"$prompt"'"}' 2>>"$errors"); then
    total=$((total + 1))
    echo "  ladder $count tokens -> block $block: tokenize FAILED" >&2
    return
  fi
  actual=$(printf '%s' "$response" | python3 -c \
    'import json,sys; print(json.load(sys.stdin).get("count", ""))' 2>>"$errors")
  if [ "$actual" != "$count" ]; then
    total=$((total + 1))
    echo "  ladder $count tokens -> block $block: tokenizer returned ${actual:-unknown}" >&2
    return
  fi
  payload='{"model":"'"$MODEL"'","prompt":"'"$prompt"'","max_tokens":1,"temperature":0}'
  record_request /v1/completions "$payload" "ladder $count tokens -> block $block"
}

warm_chat() {
  local label=$1 words=$2 profile=$3 prompt payload
  prompt="Warmup $label. $(repeat_word "$words") Reply with OK."
  case "$profile" in
    default)
      payload='{"model":"'"$MODEL"'","messages":[{"role":"user","content":"'"$prompt"'"}],"temperature":0}'
      ;;
    sampling-k)
      payload='{"model":"'"$MODEL"'","messages":[{"role":"user","content":"'"$prompt"'"}],"max_tokens":24,"temperature":0.8,"top_k":40,"chat_template_kwargs":{"thinking":true,"reasoning_effort":"low"}}'
      ;;
    sampling-p)
      payload='{"model":"'"$MODEL"'","messages":[{"role":"user","content":"'"$prompt"'"}],"max_tokens":24,"temperature":0.8,"top_p":0.9,"chat_template_kwargs":{"thinking":true,"reasoning_effort":"low"}}'
      ;;
    sampling-kp)
      payload='{"model":"'"$MODEL"'","messages":[{"role":"user","content":"'"$prompt"'"}],"max_tokens":24,"temperature":0.8,"top_k":40,"top_p":0.9,"chat_template_kwargs":{"thinking":true,"reasoning_effort":"low"}}'
      ;;
    no-thinking)
      payload='{"model":"'"$MODEL"'","messages":[{"role":"user","content":"'"$prompt"'"}],"max_tokens":24,"temperature":0,"chat_template_kwargs":{"thinking":false,"reasoning_effort":"low"}}'
      ;;
    *)
      payload='{"model":"'"$MODEL"'","messages":[{"role":"user","content":"'"$prompt"'"}],"max_tokens":24,"temperature":0,"chat_template_kwargs":{"thinking":true,"reasoning_effort":"low"}}'
      ;;
  esac
  record_request /v1/chat/completions "$payload" "$label"
}

make_vision_data_url() {
  python3 - <<'PY'
import base64
import struct
import zlib

width, height = 1920, 1080
colors = ((35, 210, 185), (235, 165, 45), (30, 45, 70))
rows = []
for y in range(height):
    blocks = []
    for x in range(0, width, 120):
        color = colors[((x // 120) + (y // 120)) % len(colors)]
        blocks.append(bytes(color) * min(120, width - x))
    rows.append(b"\x00" + b"".join(blocks))

def chunk(kind, data):
    crc = zlib.crc32(kind + data) & 0xffffffff
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", crc)

png = b"\x89PNG\r\n\x1a\n"
png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
png += chunk(b"IDAT", zlib.compress(b"".join(rows), 6))
png += chunk(b"IEND", b"")
print("data:image/png;base64," + base64.b64encode(png).decode("ascii"))
PY
}

warm_vision() {
  local data_url payload
  if ! data_url=$(make_vision_data_url); then
    total=$((total + 1))
    echo "  native vision 1920x1080: image generation FAILED" >&2
    return
  fi
  payload='{"model":"'"$MODEL"'","messages":[{"role":"user","content":[{"type":"text","text":"Reply with one word describing the dominant pattern."},{"type":"image_url","image_url":{"url":"'"$data_url"'"}}]}],"max_tokens":8,"temperature":0,"chat_template_kwargs":{"thinking":false,"reasoning_effort":"low"}}'
  record_request /v1/chat/completions "$payload" "native vision 1920x1080"
}

if ! "$CURL_BIN" -fsS --max-time 10 "${AUTH_ARGS[@]}" \
    "$BASE_URL/v1/models" >/dev/null 2>&1; then
  echo "boot-shape-warmup: API is not reachable at $BASE_URL" >&2
  exit 1
fi

echo "boot-shape-warmup: exercising text, sampler, long-prefill, and vision paths"
for rung in 1 6 20 45 100 200; do warm_ladder_rung "$rung"; done
warm_chat bounded 300 bounded
warm_chat client-default 8 default
warm_chat top-k 8 sampling-k
warm_chat top-p 8 sampling-p
warm_chat top-k-plus-top-p 8 sampling-kp
warm_chat medium-prefill 2600 bounded
warm_chat chunk-boundary $((BATCH_TOKENS + BATCH_TOKENS / 8)) bounded
warm_chat no-thinking 300 no-thinking
if [ "$WARMUP_VISION" = "1" ]; then warm_vision; fi

echo "boot-shape-warmup: $passed/$total requests passed"
if [ "$passed" -ne "$total" ]; then
  sed -n '1,8p' "$errors" >&2 2>/dev/null || true
  exit 1
fi
