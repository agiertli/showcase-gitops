#!/usr/bin/env bash
# Usage:
#   export MAAS_URL="https://maas.apps.ocp.example.com"
#   export API_KEY="sk-..."
#   ./stress-test.sh [waves] [concurrent]   # defaults: 10 waves, 100 concurrent
set -euo pipefail

MAAS_URL="${MAAS_URL:?Set MAAS_URL (e.g. https://maas.apps.ocp.example.com)}"
API_KEY="${API_KEY:?Set API_KEY}"
MODEL="${MODEL:-muse-glimmer}"
WAVES="${1:-10}"
CONCURRENT="${2:-100}"

send_request() {
  curl -s -o /dev/null -w "%{http_code}" \
    "${MAAS_URL}/muse-glimmer/muse-glimmer/v1/chat/completions" \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word.\"}],\"max_tokens\":10}"
}

echo "Starting ${WAVES} waves of ${CONCURRENT} concurrent requests..."
total_ok=0
total_fail=0

for w in $(seq 1 "$WAVES"); do
  echo "=== Wave ${w}/${WAVES} ==="
  pids=()
  codes=()
  for i in $(seq 1 "$CONCURRENT"); do
    send_request &
    pids+=($!)
  done

  ok=0; fail=0
  for pid in "${pids[@]}"; do
    code=$(wait "$pid" 2>/dev/null && echo "200" || echo "err")
    if [[ "$code" == "200" ]]; then ((ok++)); else ((fail++)); fi
  done
  echo "  OK: ${ok}  Failed: ${fail}"
  total_ok=$((total_ok + ok))
  total_fail=$((total_fail + fail))
done

echo "=== Done: ${total_ok} succeeded, ${total_fail} failed out of $((WAVES * CONCURRENT)) ==="
