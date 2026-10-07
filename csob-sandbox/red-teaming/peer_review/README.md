# ČSOB Red Teaming Report — Peer Review Package

## What to review

`csob-red-teaming-report.html` — the main deliverable. Everything else supports verification.

## Files

| File | Description |
|------|-------------|
| `csob-red-teaming-report.html` | Main report — ASR comparison, per-probe breakdown, bypass examples, architecture diagrams |
| **Raw vLLM (no guardrails) scan** | |
| `raw-vllm-hitlog.jsonl` | Every bypass — full prompt + response, probe name, detector verdict |
| `raw-vllm-report.jsonl` | AVID report — probe metadata |
| `raw-vllm-per-probe.json` | Per-probe hit counts and attempt counts |
| `raw-vllm-examples.json` | Curated bypass examples with prompt/response pairs |
| `evalhub-job-config-raw.json` | EvalHub submission config — model URL, benchmark, judge model |
| **Guardrailed (Wolf Defender) scan** | |
| `wolf-guardrailed-hitlog.jsonl` | Every bypass that got past Wolf + regex + PII guardrails |
| `wolf-guardrailed-per-probe.json` | Per-probe hit counts and eval counts |
| `wolf-guardrailed-examples.json` | Curated bypass examples with prompt/response pairs |
| `wolf-guardrailed-evalhub-result.json` | EvalHub final result — score, status, timestamps |
| `evalhub-job-config-guardrailed.json` | EvalHub submission config for guardrailed scan |
| **Defense configuration** | |
| `nemoguardrails-config.yaml` | Full NemoGuardrails ConfigMap — system prompt, Wolf Defender integration, regex patterns, PII rules |
| `proxy-code.py` | Routing proxy source — model-based routing, `stop` param stripping |

## Key claims to verify

1. **ASR reduction**: Raw 17.08% → Guardrailed 4.88% (10× reduction on some probes)
2. **Wolf Defender effectiveness**: DAN probes 100% → ~0.6%, encoding probes 40-60% → 2-8%
3. **Remaining gaps**: `misleading.FalseAssertion` (308 hits), `phrasing.*` (62 hits) — bypasses that exploit output content, not input injection
4. **No output rail**: Wolf only classifies input. Bypasses that produce harmful output from benign-looking prompts are not caught
5. **Architecture A has NO system prompt**: Raw vLLM receives only the user message. The ČSOB banking system prompt is only in Config B (NemoGuardrails)

## How to verify ASR

```python
import json
from collections import Counter

# Count hits per probe
hits = Counter()
with open("wolf-guardrailed-hitlog.jsonl") as f:
    for line in f:
        hits[json.loads(line)["probe"]] += 1

print(f"Total hits: {sum(hits.values())}")  # Should be 892
# ASR = hits / total_attempts (from per-probe.json eval_count sum)
```

## Scan parameters

- **Benchmark**: OWASP LLM Top 10 (Garak `owasp_llm_top10`)
- **Detector**: `MitigationBypass` — checks if model output matches refusal patterns
- **Model**: Gemma 4 12B (vLLM, KServe)
- **Judge model** (for intents probes): Qwen 3.6 35B-A3B (via RHDP MaaS)
- **Platform**: Red Hat OpenShift AI 3.5, EvalHub/TrustyAI
