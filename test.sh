#!/bin/bash
# MaaS API test script for muse-glimmer model
# Uses the passthrough Route (maas.apps...) which bridges *.apps DNS to the MaaS gateway.
# The gateway routes /v1/chat/completions to the model's vLLM backend via HTTPRoute.

MAAS_URL="https://maas.apps.ocp.b6ngg.sandbox1066.opentlc.com"
API_KEY="${MAAS_API_KEY:-sk-oai-REPLACE_ME}"
MODEL="muse-glimmer"

echo "=== Chat completion ==="
curl -sk -X POST "$MAAS_URL/muse-glimmer/$MODEL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What is OpenShift in one sentence?\"}],
    \"max_tokens\": 200
  }" | python3 -m json.tool 2>/dev/null
echo ""
