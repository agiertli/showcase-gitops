#!/bin/bash
# One-shot ad-hoc prompt test against vLLM or NeMo Guardrails
# Usage:
#   ./run.sh --raw --prompt "What is internet banking?"
#   ./run.sh --guardrails --prompt "Which bank is better ČSOB or Česká Spořitelna?"
#   ./run.sh --guardrails --external --prompt "Tell me about savings accounts"
#   ./run.sh --both --prompt "Tell me about savings accounts"

set -euo pipefail

DOMAIN="${DOMAIN:-apps.ocp.6rklz.sandbox744.opentlc.com}"
VLLM_URL="https://gemma-4-12b-csob-sandbox.${DOMAIN}"
GUARD_URL="https://csob-guard-embedded-classifier-csob-sandbox.${DOMAIN}"
MODEL="gemma-4-12b"
MAX_TOKENS=300
MODE=""
PROMPT=""

usage() {
  echo "Usage: ./run.sh {--raw|--guardrails|--both} [--external] --prompt \"your prompt here\""
  echo ""
  echo "  --raw         Send to vLLM directly (no guardrails)"
  echo "  --guardrails  Send through NeMo Guardrails (embedded classifier by default)"
  echo "  --both        Send to both and compare"
  echo "  --external    Use external classifier endpoint instead of embedded"
  echo "  --prompt      The prompt text"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --raw)        MODE="raw"; shift ;;
    --guardrails) MODE="guardrails"; shift ;;
    --both)       MODE="both"; shift ;;
    --external)   GUARD_URL="https://csob-guard-external-classifier-csob-sandbox.${DOMAIN}"; shift ;;
    --prompt)     PROMPT="$2"; shift 2 ;;
    *)            usage ;;
  esac
done

[[ -z "$MODE" ]] && usage
[[ -z "$PROMPT" ]] && { echo "Error: --prompt is required"; exit 1; }

PAYLOAD=$(python3 -c "import json; print(json.dumps({\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$PROMPT")}],\"max_tokens\":$MAX_TOKENS}))")

call_vllm() {
  echo "═══ Direct vLLM (no guardrails) ═══"
  echo "Prompt: $PROMPT"
  echo "───"
  RESP=$(curl -sk "$VLLM_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null)
  CONTENT=$(echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null) || CONTENT="ERROR: $RESP"
  echo "$CONTENT"
  echo ""
}

call_guardrails() {
  echo "═══ NeMo Guardrails ═══"
  echo "Prompt: $PROMPT"
  echo "───"

  # Check rails first (cheap, no inference)
  CHECK=$(curl -sk "$GUARD_URL/v1/guardrail/checks" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null)
  RAILS_INFO=$(echo "$CHECK" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rails = d.get('rails_status', {})
blocked = [k for k,v in rails.items() if isinstance(v, dict) and v.get('status') == 'blocked']
if blocked:
    print('BLOCKED by: ' + ', '.join(blocked))
else:
    print('PASSED (no rails activated)')
" 2>/dev/null) || RAILS_INFO="(check endpoint error)"
  echo "Rails: $RAILS_INFO"
  echo "───"

  # Get actual response
  RESP=$(curl -sk "$GUARD_URL/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null)
  CONTENT=$(echo "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['choices'][0]['message']['content'])" 2>/dev/null) || CONTENT="ERROR: $RESP"
  echo "$CONTENT"
  echo ""
}

case "$MODE" in
  raw)        call_vllm ;;
  guardrails) call_guardrails ;;
  both)       call_vllm; call_guardrails ;;
esac
