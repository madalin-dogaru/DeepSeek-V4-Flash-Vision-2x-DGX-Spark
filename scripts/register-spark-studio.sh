#!/usr/bin/env bash
set -Eeuo pipefail

STUDIO_URL="${SPARK_STUDIO_URL:-http://127.0.0.1:7860}"
ENDPOINT_URL="${DEEPSEEK_ENDPOINT_URL:-http://127.0.0.1:8888}"
NAME="${SPARK_STUDIO_MODEL_NAME:-deepseek-v4-flash-vision-exp}"
ENGINE="${SPARK_STUDIO_ENGINE:-vllm}"
TIMEOUT="${SPARK_STUDIO_TIMEOUT:-10}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Register an already-running DeepSeek endpoint with Spark Studio.
This does not start, stop, or modify the model runtime.

Options:
  --studio-url URL    Spark Studio root URL (default: $STUDIO_URL)
  --endpoint-url URL  OpenAI-compatible endpoint root (default: $ENDPOINT_URL)
  --name NAME         Label displayed by Spark Studio (default: $NAME)
  --engine ENGINE     Spark Studio engine type (default: $ENGINE)
  --timeout SECONDS   HTTP timeout (default: $TIMEOUT)
  -h, --help          Show this help
EOF
}

need_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    echo "$1 requires a value" >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --studio-url)
      need_value "$@"
      STUDIO_URL="$2"
      shift 2
      ;;
    --endpoint-url)
      need_value "$@"
      ENDPOINT_URL="$2"
      shift 2
      ;;
    --name)
      need_value "$@"
      NAME="$2"
      shift 2
      ;;
    --engine)
      need_value "$@"
      ENGINE="$2"
      shift 2
      ;;
    --timeout)
      need_value "$@"
      TIMEOUT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 1
  }
done

case "$TIMEOUT" in
  ''|*[!0-9]*) echo "timeout must be a positive integer" >&2; exit 2 ;;
esac
[ "$TIMEOUT" -gt 0 ] || { echo "timeout must be a positive integer" >&2; exit 2; }

STUDIO_URL="${STUDIO_URL%/}"
ENDPOINT_URL="${ENDPOINT_URL%/}"
case "$ENDPOINT_URL" in
  */v1) ENDPOINT_URL="${ENDPOINT_URL%/v1}" ;;
esac

for pair in "Spark Studio:$STUDIO_URL" "model endpoint:$ENDPOINT_URL"; do
  label="${pair%%:*}"
  url="${pair#*:}"
  case "$url" in
    http://*|https://*) ;;
    *) echo "$label URL must begin with http:// or https://: $url" >&2; exit 2 ;;
  esac
done

models_json="$(curl --fail --silent --show-error --max-time "$TIMEOUT" \
  "$ENDPOINT_URL/v1/models")" || {
  echo "The model endpoint did not allow an unauthenticated GET of /v1/models." >&2
  echo "Spark Studio external registration currently cannot attach an API key." >&2
  exit 1
}
jq -e '.data | type == "array"' >/dev/null <<<"$models_json" || {
  echo "The model endpoint returned an invalid OpenAI /v1/models response." >&2
  exit 1
}

runs_json="$(curl --fail --silent --show-error --max-time "$TIMEOUT" \
  "$STUDIO_URL/api/runs")" || {
  echo "Spark Studio is not reachable at $STUDIO_URL" >&2
  exit 1
}
jq -e 'type == "array"' >/dev/null <<<"$runs_json" || {
  echo "Spark Studio returned an invalid /api/runs response." >&2
  exit 1
}

existing_id="$(jq -r \
  --arg engine "$ENGINE" \
  --arg name "$NAME" \
  --arg url "$ENDPOINT_URL" \
  '.[] | select(.status == "running" and .engine == $engine and .label == $name and ((.url // "") | rtrimstr("/")) == $url) | .id' \
  <<<"$runs_json" | head -n 1)"

if [ -n "$existing_id" ]; then
  echo "Already registered with Spark Studio: $NAME ($existing_id)"
  echo "Endpoint: $ENDPOINT_URL"
  exit 0
fi

payload="$(jq -nc \
  --arg engine "$ENGINE" \
  --arg name "$NAME" \
  --arg url "$ENDPOINT_URL" \
  '{engine: $engine, name: $name, url: $url}')"

response="$(curl --fail --silent --show-error --max-time "$TIMEOUT" \
  -X POST "$STUDIO_URL/api/external" \
  -H 'Content-Type: application/json' \
  --data "$payload")" || {
  echo "Spark Studio rejected the external endpoint registration." >&2
  exit 1
}

run_id="$(jq -er '.id' <<<"$response")" || {
  echo "Spark Studio registered the endpoint but returned no run ID." >&2
  exit 1
}

echo "Registered with Spark Studio: $NAME ($run_id)"
echo "Endpoint: $ENDPOINT_URL"
echo "Runtime ownership remains external; Spark Studio will not start or stop it."
