#!/bin/bash
# MaaS API test script for qwen3-8b model
# Uses the passthrough Route (maas.apps...) which bridges *.apps DNS to the MaaS gateway.
# The gateway routes /v1/chat/completions to the model's vLLM backend via HTTPRoute.

MAAS_URL="https://maas.apps.ocp.4t49q.sandbox1217.opentlc.com"
API_KEY="sk-oai-ISKCqlkw50nsQIiT_jIwknpoWzroLBUrb0gCUJKgoKuWqSHBhg5uVL7OQgWq"
MODEL="qwen3-8b"

echo "=== Chat completion ==="
curl -sk -X POST "$MAAS_URL/rhoai-playground/$MODEL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"$MODEL\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What is OpenShift in one sentence?\"}],
    \"max_tokens\": 200,
    \"chat_template_kwargs\": {\"enable_thinking\": false}
  }" | python3 -m json.tool 2>/dev/null
echo ""
