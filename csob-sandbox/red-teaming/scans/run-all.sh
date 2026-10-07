#!/bin/bash
# Submit all 5 EvalHub red-teaming scans.
# Usage: ./run-all.sh [namespace]
set -euo pipefail

NS="${1:-csob-sandbox}"
DIR="$(cd "$(dirname "$0")" && pwd)"

OVERLAYS=(owasp-raw owasp-guardrailed intents-raw intents-guardrailed intents-external-judge)
JOB_NAMES=(owasp-raw-scan owasp-guardrailed-scan intents-raw-scan intents-guardrailed-scan intents-extjudge-scan)

for i in "${!OVERLAYS[@]}"; do
  overlay="${OVERLAYS[$i]}"
  job="${JOB_NAMES[$i]}"
  echo "--- Submitting: $overlay ---"
  oc delete job "$job" -n "$NS" --ignore-not-found 2>/dev/null || true
  oc apply -k "$DIR/$overlay/"
  echo ""
done

echo "All scans submitted. Monitor progress:"
echo "  oc get jobs -n $NS"
echo ""
echo "View logs:"
for job in "${JOB_NAMES[@]}"; do
  echo "  oc logs job/$job -n $NS"
done
