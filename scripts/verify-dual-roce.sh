#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env.dspark}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "Cannot read environment file: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

for command in ibdev2netdev ping; do
  command -v "$command" >/dev/null || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

IFS=',' read -r -a hcas <<<"${NCCL_IB_HCA:-}"
if [[ ${#hcas[@]} -ne 2 ]]; then
  echo "NCCL_IB_HCA must contain exactly two comma-separated RoCE devices." >&2
  exit 1
fi

peer_ips=()
if [[ -n ${ROCE_PEER_IPS:-} ]]; then
  IFS=',' read -r -a peer_ips <<<"$ROCE_PEER_IPS"
  if [[ ${#peer_ips[@]} -ne 2 ]]; then
    echo "ROCE_PEER_IPS must contain two peer addresses in NCCL_IB_HCA order." >&2
    exit 1
  fi
fi

mapping="$(ibdev2netdev)"
for index in "${!hcas[@]}"; do
  hca="${hcas[$index]}"
  netdev="$(awk -v hca="$hca" '$1 == hca && $4 == "==>" { print $5; exit }' <<<"$mapping")"
  state="$(awk -v hca="$hca" '$1 == hca && $4 == "==>" { print $6; exit }' <<<"$mapping")"

  if [[ -z $netdev || $state != "(Up)" ]]; then
    echo "$hca is missing or not active: ${netdev:-unmapped} ${state:-unknown}" >&2
    exit 1
  fi

  mtu="$(<"/sys/class/net/$netdev/mtu")"
  operstate="$(<"/sys/class/net/$netdev/operstate")"
  if [[ $operstate != "up" || $mtu -lt 9000 ]]; then
    echo "$hca -> $netdev is not ready: state=$operstate mtu=$mtu" >&2
    exit 1
  fi

  printf 'OK  %s -> %s  state=%s  mtu=%s\n' "$hca" "$netdev" "$operstate" "$mtu"

  if [[ ${#peer_ips[@]} -eq 2 ]]; then
    peer="${peer_ips[$index]}"
    ping -I "$netdev" -M do -s 8972 -c 3 -W 2 "$peer" >/dev/null
    printf 'OK  %s -> %s  jumbo payload=8972\n' "$netdev" "$peer"
  fi
done

echo "Dual-path RoCE validation passed."
