#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/mock-curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
url=""
payload=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -d|--data|--data-raw)
      payload=$2
      shift 2
      ;;
    http://*|https://*)
      url=$1
      shift
      ;;
    -H|--max-time)
      shift 2
      ;;
    *) shift ;;
  esac
done
printf '%s\t%s\n' "$url" "$payload" >>"$WARMUP_CALL_LOG"
case "$url" in
  */tokenize)
    PAYLOAD="$payload" python3 - <<'PY'
import json
import os

prompt = json.loads(os.environ["PAYLOAD"])["prompt"]
print(json.dumps({"count": len(prompt.split())}))
PY
    ;;
  *) printf '{}\n' ;;
esac
MOCK
chmod +x "$tmpdir/mock-curl"

export WARMUP_CURL="$tmpdir/mock-curl"
export WARMUP_CALL_LOG="$tmpdir/calls"
export DSPARK_WARMUP_BATCH_TOKENS=8192
export DSPARK_WARMUP_SPEC_TOKENS=3
export DSPARK_WARMUP_VISION=1

output=$("$SCRIPT_DIR/boot-shape-warmup.sh" http://127.0.0.1:8888 test-model)
grep -q 'boot-shape-warmup: 15/15 requests passed' <<<"$output"

CALL_LOG="$WARMUP_CALL_LOG" python3 - <<'PY'
import base64
import json
import os
import struct

with open(os.environ["CALL_LOG"], encoding="utf-8") as handle:
    rows = [line.rstrip("\n").split("\t", 1) for line in handle]

assert len(rows) == 22, len(rows)
assert sum(url.endswith("/tokenize") for url, _ in rows) == 6
assert sum(url.endswith("/v1/completions") for url, _ in rows) == 6
chat = [json.loads(payload) for url, payload in rows if url.endswith("/v1/chat/completions")]
assert len(chat) == 9, len(chat)

vision = [
    request for request in chat
    if isinstance(request["messages"][0]["content"], list)
]
assert len(vision) == 1
data_url = vision[0]["messages"][0]["content"][1]["image_url"]["url"]
png = base64.b64decode(data_url.split(",", 1)[1])
assert png[:8] == b"\x89PNG\r\n\x1a\n"
width, height = struct.unpack(">II", png[16:24])
assert (width, height) == (1920, 1080)

chunk = next(
    request for request in chat
    if "Warmup chunk-boundary." in request["messages"][0]["content"]
)
assert chunk["messages"][0]["content"].count("hello") == 9216
PY

: >"$WARMUP_CALL_LOG"
output=$(DSPARK_WARMUP_VISION=0 \
  "$SCRIPT_DIR/boot-shape-warmup.sh" http://127.0.0.1:8888 test-model)
grep -q 'boot-shape-warmup: 14/14 requests passed' <<<"$output"

if DSPARK_WARMUP_BATCH_TOKENS=0 \
    "$SCRIPT_DIR/boot-shape-warmup.sh" http://127.0.0.1:8888 test-model \
    >/dev/null 2>&1; then
  echo "warmup accepted an invalid zero batch size" >&2
  exit 1
fi

echo "Boot shape warmup behavior verified."
