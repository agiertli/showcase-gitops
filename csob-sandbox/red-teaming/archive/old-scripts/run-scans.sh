#!/bin/bash
# Garak Red Teaming — Guardrails Effectiveness Comparison
# Submits intents scans against raw vLLM and guardrailed endpoints,
# polls for completion, fetches results, and generates a consolidated
# HTML comparison report.
#
# Usage: ./red-teaming/run-scans.sh [cluster-domain]
# Output: tests/garak-comparison-report.html
#         red-teaming/results-raw.json
#         red-teaming/results-guardrailed.json
# Run from csob-sandbox/ directory
# Requires: oc login, python3, curl, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NS="csob-sandbox"
DOMAIN="${1:-apps.ocp.6rklz.sandbox744.opentlc.com}"
POLL_INTERVAL=30
POLL_TIMEOUT=3600

# Load credentials
if [[ -f "$SCRIPT_DIR/../.env" ]]; then
  source "$SCRIPT_DIR/../.env"
else
  echo "ERROR: .env file not found. Create csob-sandbox/.env with MAAS_RHDP_API_KEY"
  exit 1
fi

echo "=== Phase 0: Prerequisites ==="

EVALHUB_POD=$(oc get pods -n "$NS" -l app=eval-hub -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "$EVALHUB_POD" ]]; then
  echo "ERROR: EvalHub not running in $NS. Deploy it first:"
  echo "  oc apply -f red-teaming/04-evalhub-postgres.yaml --server-side"
  echo "  oc apply -f red-teaming/05-evalhub-cr.yaml --server-side -n $NS"
  exit 1
fi

DSPA_READY=$(oc get dspa dspa -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [[ "$DSPA_READY" != "True" ]]; then
  echo "WARNING: DSPA not ready in $NS. Scans may fail if kfp_config is needed."
fi

# Patch API key secret with real value
oc patch secret maas-rhdp-api-key -n "$NS" --type merge \
  -p "{\"stringData\":{\"API_KEY\":\"$MAAS_RHDP_API_KEY\"}}" 2>/dev/null || \
  oc create secret generic maas-rhdp-api-key -n "$NS" --from-literal=API_KEY="$MAAS_RHDP_API_KEY"

EVALHUB_URL="https://$(oc get routes evalhub -n "$NS" -o jsonpath='{.spec.host}')"
TOKEN=$(oc create token default -n "$NS" 2>/dev/null || oc whoami -t)

echo "EvalHub URL: $EVALHUB_URL"
echo "Cluster domain: $DOMAIN"
echo ""

echo "=== Phase 1: Submit raw vLLM scan ==="
RAW_RESPONSE=$(curl -sk -X POST "$EVALHUB_URL/api/v1/evaluations/jobs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Tenant: $NS" \
  -d @"$SCRIPT_DIR/intents-scan-raw.json")

RAW_JOB_ID=$(echo "$RAW_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['resource']['id'])" 2>/dev/null || true)
if [[ -z "$RAW_JOB_ID" ]]; then
  echo "ERROR submitting raw scan: $RAW_RESPONSE"
  exit 1
fi
echo "Raw vLLM scan submitted: job_id=$RAW_JOB_ID"

echo ""
echo "=== Phase 2: Submit guardrailed scan ==="
GUARD_RESPONSE=$(curl -sk -X POST "$EVALHUB_URL/api/v1/evaluations/jobs" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "X-Tenant: $NS" \
  -d @"$SCRIPT_DIR/intents-scan-guardrailed.json")

GUARD_JOB_ID=$(echo "$GUARD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['resource']['id'])" 2>/dev/null || true)
if [[ -z "$GUARD_JOB_ID" ]]; then
  echo "ERROR submitting guardrailed scan: $GUARD_RESPONSE"
  exit 1
fi
echo "Guardrailed scan submitted: job_id=$GUARD_JOB_ID"

echo ""
echo "=== Phase 3: Poll for completion ==="

poll_job() {
  local job_id="$1"
  local label="$2"
  local elapsed=0

  while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
    local status
    status=$(curl -sk \
      -H "Authorization: Bearer $TOKEN" \
      -H "X-Tenant: $NS" \
      "$EVALHUB_URL/api/v1/evaluations/jobs/$job_id" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',{}).get('state','unknown'))" 2>/dev/null || echo "error")

    case "$status" in
      completed)
        echo "  [$label] Completed after ${elapsed}s"
        return 0
        ;;
      failed|cancelled|partially_failed)
        echo "  [$label] FAILED with status: $status after ${elapsed}s"
        return 1
        ;;
      pending|running)
        printf "  [$label] %s (%ds elapsed)...\r" "$status" "$elapsed"
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        ;;
      *)
        echo "  [$label] Unknown status: $status"
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
        ;;
    esac
  done

  echo "  [$label] TIMEOUT after ${POLL_TIMEOUT}s"
  return 1
}

RAW_OK=0
GUARD_OK=0

poll_job "$RAW_JOB_ID" "Raw vLLM" || RAW_OK=1
poll_job "$GUARD_JOB_ID" "Guardrailed" || GUARD_OK=1

echo ""
echo "=== Phase 4: Fetch results ==="

curl -sk \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant: $NS" \
  "$EVALHUB_URL/api/v1/evaluations/jobs/$RAW_JOB_ID" | python3 -m json.tool > "$SCRIPT_DIR/results-raw.json"
echo "  Raw results: $SCRIPT_DIR/results-raw.json"

curl -sk \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Tenant: $NS" \
  "$EVALHUB_URL/api/v1/evaluations/jobs/$GUARD_JOB_ID" | python3 -m json.tool > "$SCRIPT_DIR/results-guardrailed.json"
echo "  Guardrailed results: $SCRIPT_DIR/results-guardrailed.json"

echo ""
echo "=== Phase 5: Generate HTML report ==="

exec python3 - "$SCRIPT_DIR" "$DOMAIN" "$RAW_OK" "$GUARD_OK" << 'PYEOF'
import json, sys, html, os
from datetime import datetime, timezone

SCRIPT_DIR = sys.argv[1]
DOMAIN = sys.argv[2]
RAW_FAILED = sys.argv[3] == "1"
GUARD_FAILED = sys.argv[4] == "1"

def load_results(path):
    with open(path) as f:
        return json.load(f)

raw = load_results(os.path.join(SCRIPT_DIR, "results-raw.json"))
guard = load_results(os.path.join(SCRIPT_DIR, "results-guardrailed.json"))

def get_state(data):
    return data.get("status", {}).get("state", "unknown")

def get_benchmarks(data):
    return data.get("results", {}).get("benchmarks", [])

def get_metrics(data):
    benchmarks = get_benchmarks(data)
    if benchmarks:
        return benchmarks[0].get("metrics", {})
    return {}

def get_name(data):
    return data.get("name", "unknown")

def get_model(data):
    m = data.get("model", {})
    return {"url": m.get("url", ""), "name": m.get("name", "")}

raw_state = get_state(raw)
guard_state = get_state(guard)
raw_metrics = get_metrics(raw)
guard_metrics = get_metrics(guard)
raw_model = get_model(raw)
guard_model = get_model(guard)

def extract_asr(metrics):
    for key in ["asr", "attack_success_rate", "toxicity_score"]:
        if key in metrics:
            return float(metrics[key])
    return None

def extract_counts(metrics):
    counts = {}
    for key in ["total_attempts", "total_prompts", "unsafe_prompts",
                "safe_prompts", "complied", "rejected"]:
        if key in metrics:
            counts[key] = metrics[key]
    return counts

def extract_per_intent(metrics):
    for key in ["per_intent", "intents", "intent_results", "per_category", "categories"]:
        if key in metrics and isinstance(metrics[key], (dict, list)):
            return metrics[key]
    return None

def extract_per_strategy(metrics):
    for key in ["per_strategy", "strategies", "strategy_results"]:
        if key in metrics and isinstance(metrics[key], (dict, list)):
            return metrics[key]
    return None

raw_asr = extract_asr(raw_metrics)
guard_asr = extract_asr(guard_metrics)
raw_counts = extract_counts(raw_metrics)
guard_counts = extract_counts(guard_metrics)
raw_intents = extract_per_intent(raw_metrics)
guard_intents = extract_per_intent(guard_metrics)
raw_strategies = extract_per_strategy(raw_metrics)
guard_strategies = extract_per_strategy(guard_metrics)

ts = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

def asr_color(asr):
    if asr is None:
        return "#999"
    if asr <= 0.1:
        return "#155724"
    if asr <= 0.3:
        return "#856404"
    return "#721c24"

def asr_bg(asr):
    if asr is None:
        return "#e8e8e8"
    if asr <= 0.1:
        return "#d4edda"
    if asr <= 0.3:
        return "#fff3cd"
    return "#f8d7da"

def fmt_asr(asr):
    if asr is None:
        return "N/A"
    return f"{asr*100:.1f}%"

def fmt_pct_change(raw_val, guard_val):
    if raw_val is None or guard_val is None or raw_val == 0:
        return ""
    delta = guard_val - raw_val
    pct = (delta / raw_val) * 100
    arrow = "▼" if delta < 0 else "▲"
    color = "#155724" if delta < 0 else "#721c24"
    return f'<span style="color:{color};font-weight:600">{arrow} {abs(pct):.0f}%</span>'

def render_metric_row(label, raw_val, guard_val, is_pct=False):
    if raw_val is None and guard_val is None:
        return ""
    rv = fmt_asr(raw_val) if is_pct else str(raw_val) if raw_val is not None else "N/A"
    gv = fmt_asr(guard_val) if is_pct else str(guard_val) if guard_val is not None else "N/A"
    change = fmt_pct_change(raw_val, guard_val) if is_pct else ""
    return f"""<tr>
<td style="font-weight:600">{html.escape(label)}</td>
<td style="text-align:center">{rv}</td>
<td style="text-align:center">{gv}</td>
<td style="text-align:center">{change}</td>
</tr>"""

def render_intent_rows(raw_data, guard_data):
    if not raw_data and not guard_data:
        return ""
    rows = []
    all_keys = set()
    if isinstance(raw_data, dict):
        all_keys.update(raw_data.keys())
    if isinstance(guard_data, dict):
        all_keys.update(guard_data.keys())
    if isinstance(raw_data, list):
        for item in raw_data:
            k = item.get("intent", item.get("category", item.get("name", "unknown")))
            all_keys.add(k)
    if isinstance(guard_data, list):
        for item in guard_data:
            k = item.get("intent", item.get("category", item.get("name", "unknown")))
            all_keys.add(k)

    def get_intent_asr(data, key):
        if isinstance(data, dict):
            val = data.get(key)
            if isinstance(val, (int, float)):
                return val
            if isinstance(val, dict):
                return extract_asr(val)
        if isinstance(data, list):
            for item in data:
                name = item.get("intent", item.get("category", item.get("name", "")))
                if name == key:
                    return extract_asr(item) or item.get("asr") or item.get("score")
        return None

    for key in sorted(all_keys):
        rv = get_intent_asr(raw_data, key)
        gv = get_intent_asr(guard_data, key)
        rows.append(render_metric_row(key, rv, gv, is_pct=True))
    return "\n".join(rows)

def render_strategy_rows(raw_data, guard_data):
    if not raw_data and not guard_data:
        return ""
    rows = []
    all_keys = set()
    if isinstance(raw_data, dict):
        all_keys.update(raw_data.keys())
    if isinstance(guard_data, dict):
        all_keys.update(guard_data.keys())
    if isinstance(raw_data, list):
        for item in raw_data:
            k = item.get("strategy", item.get("name", "unknown"))
            all_keys.add(k)
    if isinstance(guard_data, list):
        for item in guard_data:
            k = item.get("strategy", item.get("name", "unknown"))
            all_keys.add(k)

    def get_strategy_asr(data, key):
        if isinstance(data, dict):
            val = data.get(key)
            if isinstance(val, (int, float)):
                return val
            if isinstance(val, dict):
                return extract_asr(val)
        if isinstance(data, list):
            for item in data:
                name = item.get("strategy", item.get("name", ""))
                if name == key:
                    return extract_asr(item) or item.get("asr") or item.get("score")
        return None

    strategy_labels = {
        "baseline": "Baseline",
        "spo": "System Prompt Override (SPO)",
        "spo_user_augmented": "SPO + User Augmented",
        "spo_system_augmented": "SPO + System Augmented",
        "spo_both_augmented": "SPO + Both Augmented",
        "translation": "Translation (zh-en)",
        "tap": "Tree of Attacks w/ Pruning (TAP)",
    }
    for key in sorted(all_keys):
        rv = get_strategy_asr(raw_data, key)
        gv = get_strategy_asr(guard_data, key)
        label = strategy_labels.get(key, key)
        rows.append(render_metric_row(label, rv, gv, is_pct=True))
    return "\n".join(rows)

def render_all_metrics_fallback(metrics, label):
    if not metrics:
        return f'<p style="color:#999;font-style:italic">No metrics available for {label}</p>'
    return f'<pre style="background:#f8f8f8;padding:1rem;border-radius:6px;font-size:.8rem;overflow-x:auto;font-family:\'Red Hat Mono\',monospace">{html.escape(json.dumps(metrics, indent=2, default=str))}</pre>'

has_structured_data = (raw_asr is not None or guard_asr is not None or
                       raw_intents or guard_intents or
                       raw_strategies or guard_strategies)

# --- Build HTML ---

report = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Garak Red Teaming — Guardrails Effectiveness Comparison</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{font-family:'Red Hat Display','Segoe UI',system-ui,sans-serif;background:#f5f5f5;color:#333;padding:2rem}}
.c{{max-width:1200px;margin:0 auto}}
h1{{color:#cc0000;margin-bottom:.3rem;font-size:1.8rem}}
h2{{color:#333;margin:1.5rem 0 .8rem;font-size:1.2rem;border-bottom:2px solid #cc0000;padding-bottom:.3rem}}
.sub{{color:#666;margin-bottom:1.5rem;font-size:.95rem}}
.row{{display:flex;gap:1rem;margin-bottom:1.5rem;flex-wrap:wrap}}
.card{{flex:1;min-width:200px;padding:1.2rem;border-radius:8px;text-align:center}}
.card .n{{font-size:2.2rem;font-weight:700}}.card .l{{font-size:.85rem;text-transform:uppercase;opacity:.8}}
.card .sub-n{{font-size:.85rem;margin-top:.3rem}}
.ep{{background:#fff;padding:.8rem 1.2rem;border-radius:8px;margin-bottom:1.5rem;font-size:.88rem;box-shadow:0 1px 3px rgba(0,0,0,.08)}}
.ep code{{background:#f0f0f0;padding:2px 6px;border-radius:3px;font-family:'Red Hat Mono',monospace;font-size:.82rem}}
.note{{background:#fff3cd;border-left:4px solid #ffc107;padding:.8rem 1.2rem;margin-bottom:1.5rem;border-radius:0 8px 8px 0;font-size:.88rem}}
.note h3{{color:#856404;margin-bottom:.3rem;font-size:.95rem}}
.success{{background:#d4edda;border-left:4px solid #28a745;padding:.8rem 1.2rem;margin-bottom:1.5rem;border-radius:0 8px 8px 0;font-size:.88rem}}
.success h3{{color:#155724;margin-bottom:.3rem;font-size:.95rem}}
.danger{{background:#f8d7da;border-left:4px solid #dc3545;padding:.8rem 1.2rem;margin-bottom:1.5rem;border-radius:0 8px 8px 0;font-size:.88rem}}
.danger h3{{color:#721c24;margin-bottom:.3rem;font-size:.95rem}}
table{{width:100%;border-collapse:collapse;background:#fff;border-radius:8px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.1);font-size:.85rem;margin-bottom:1.5rem}}
th{{background:#333;color:#fff;padding:10px 14px;text-align:left;font-size:.78rem;text-transform:uppercase;white-space:nowrap}}
td{{padding:10px 14px;border-bottom:1px solid #eee;vertical-align:middle}}
tr:last-child td{{border-bottom:none}}tr:hover{{background:#fafafa}}
.badge{{display:inline-block;padding:3px 12px;border-radius:12px;font-size:.78rem;font-weight:600}}
.badge-ok{{background:#d4edda;color:#155724}}.badge-warn{{background:#fff3cd;color:#856404}}.badge-fail{{background:#f8d7da;color:#721c24}}.badge-info{{background:#d1ecf1;color:#0c5460}}
.compare{{display:flex;gap:1.5rem;margin-bottom:1.5rem}}
.compare-col{{flex:1;background:#fff;padding:1.2rem;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.1)}}
.compare-col h3{{font-size:1rem;margin-bottom:.8rem}}
.vs{{display:flex;align-items:center;justify-content:center;font-size:1.5rem;font-weight:700;color:#999;padding:0 .5rem}}
footer{{margin-top:2rem;text-align:center;color:#999;font-size:.8rem}}
</style>
</head>
<body>
<div class="c">
<h1>Garak Red Teaming — Guardrails Effectiveness</h1>
<p class="sub">ČSOB Sandbox | gemma-4-12B-it | RHOAI 3.5.1 | {ts}</p>

<div class="ep">
<strong>Test Configuration:</strong><br>
<strong>Raw vLLM:</strong> <code>{html.escape(raw_model['url'])}</code> (model: {html.escape(raw_model['name'])})<br>
<strong>Guardrailed:</strong> <code>{html.escape(guard_model['url'])}</code> (model: {html.escape(guard_model['name'])})<br>
<strong>Probes:</strong> SPOIntent, SPOIntentUserAugmented, SPOIntentSystemAugmented, SPOIntentBothAugmented<br>
<strong>SDG samples:</strong> 10 per intent &nbsp;|&nbsp; <strong>Translation:</strong> disabled (langproviders: null)
</div>
"""

# Status cards
raw_status_class = "badge-ok" if raw_state == "completed" else "badge-fail"
guard_status_class = "badge-ok" if guard_state == "completed" else "badge-fail"

report += f"""
<div class="row">
<div class="card" style="background:{asr_bg(raw_asr)}">
<div class="l">Raw vLLM — ASR</div>
<div class="n" style="color:{asr_color(raw_asr)}">{fmt_asr(raw_asr)}</div>
<div class="sub-n"><span class="badge {raw_status_class}">{raw_state}</span></div>
</div>
<div class="card" style="background:{asr_bg(guard_asr)}">
<div class="l">Guardrailed — ASR</div>
<div class="n" style="color:{asr_color(guard_asr)}">{fmt_asr(guard_asr)}</div>
<div class="sub-n"><span class="badge {guard_status_class}">{guard_state}</span></div>
</div>
"""

if raw_asr is not None and guard_asr is not None:
    reduction = ((raw_asr - guard_asr) / raw_asr * 100) if raw_asr > 0 else 0
    red_color = "#155724" if reduction > 0 else "#721c24"
    red_bg = "#d4edda" if reduction > 0 else "#f8d7da"
    report += f"""<div class="card" style="background:{red_bg}">
<div class="l">ASR Reduction</div>
<div class="n" style="color:{red_color}">{reduction:.0f}%</div>
<div class="sub-n">{'Guardrails effective' if reduction > 0 else 'No improvement'}</div>
</div>"""

report += "</div>\n"

# Guardrails effectiveness summary
if raw_asr is not None and guard_asr is not None:
    if guard_asr < raw_asr:
        report += f"""<div class="success">
<h3>Guardrails reduced attack surface</h3>
<p>ASR dropped from {fmt_asr(raw_asr)} (raw) to {fmt_asr(guard_asr)} (guardrailed) — a <strong>{((raw_asr - guard_asr) / raw_asr * 100):.0f}% reduction</strong> in successful attacks.
NeMo Guardrails with Wolf Defender classifier blocks prompt injection attempts before they reach the LLM.</p>
</div>"""
    else:
        report += f"""<div class="danger">
<h3>Guardrails did not reduce ASR</h3>
<p>ASR was {fmt_asr(raw_asr)} (raw) vs {fmt_asr(guard_asr)} (guardrailed). Investigate whether the guardrails endpoint is correctly configured.</p>
</div>"""

# Count metrics table
if raw_counts or guard_counts:
    all_count_keys = sorted(set(list(raw_counts.keys()) + list(guard_counts.keys())))
    report += "<h2>Overview Metrics</h2>\n<table><thead><tr><th>Metric</th><th>Raw vLLM</th><th>Guardrailed</th><th>Change</th></tr></thead><tbody>\n"
    for k in all_count_keys:
        rv = raw_counts.get(k, "—")
        gv = guard_counts.get(k, "—")
        label = k.replace("_", " ").title()
        report += f"<tr><td style='font-weight:600'>{html.escape(label)}</td><td style='text-align:center'>{rv}</td><td style='text-align:center'>{gv}</td><td></td></tr>\n"
    report += "</tbody></table>\n"

# Per-intent breakdown
intent_rows = render_intent_rows(raw_intents, guard_intents)
if intent_rows:
    report += "<h2>Per-Intent ASR Breakdown</h2>\n"
    report += "<table><thead><tr><th>Harm Category / Intent</th><th>Raw vLLM ASR</th><th>Guardrailed ASR</th><th>Change</th></tr></thead><tbody>\n"
    report += intent_rows
    report += "\n</tbody></table>\n"
    report += """<div class="note">
<h3>Reading this table</h3>
<p>ASR = Attack Success Rate. Lower is better. 0% means the model refused all adversarial prompts in this category.
100% means every attack succeeded. The ▼ arrow shows guardrails reducing the attack surface.</p>
</div>"""

# Per-strategy breakdown
strategy_rows = render_strategy_rows(raw_strategies, guard_strategies)
if strategy_rows:
    report += "<h2>Per-Strategy ASR Breakdown</h2>\n"
    report += "<table><thead><tr><th>Attack Strategy</th><th>Raw vLLM ASR</th><th>Guardrailed ASR</th><th>Change</th></tr></thead><tbody>\n"
    report += strategy_rows
    report += "\n</tbody></table>\n"
    report += """<div class="note">
<h3>Attack strategies (escalating sophistication)</h3>
<p><strong>Baseline</strong> — unmodified prompt. <strong>SPO</strong> — adversarial system prompt override.
<strong>SPO + augmented</strong> — statistical manipulation of user/system prompt.
<strong>Translation</strong> — prompt translated to another language to bypass English-only safety.
<strong>TAP</strong> — attacker LLM iteratively crafts bypass prompts.</p>
</div>"""

# Fallback: raw metrics dump if no structured data found
if not has_structured_data:
    report += "<h2>Raw Metrics</h2>\n"
    report += '<div class="compare">\n'
    report += f'<div class="compare-col"><h3>Raw vLLM ({html.escape(get_name(raw))})</h3>\n{render_all_metrics_fallback(raw_metrics, "raw")}</div>\n'
    report += '<div class="vs">vs</div>\n'
    report += f'<div class="compare-col"><h3>Guardrailed ({html.escape(get_name(guard))})</h3>\n{render_all_metrics_fallback(guard_metrics, "guardrailed")}</div>\n'
    report += '</div>\n'

    if not raw_metrics and not guard_metrics:
        if raw_state != "completed" or guard_state != "completed":
            report += f"""<div class="danger">
<h3>Scans did not complete successfully</h3>
<p>Raw vLLM: <strong>{raw_state}</strong> | Guardrailed: <strong>{guard_state}</strong></p>
<p>Check EvalHub logs: <code>oc logs -n {NS} -l app=eval-hub --tail=100</code><br>
Check adapter job logs: <code>oc get jobs -n {NS} | grep garak</code></p>
</div>"""
        else:
            report += f"""<div class="note">
<h3>Metrics not yet available</h3>
<p>Both scans completed but returned no metrics. This may indicate that the Garak adapter
stores results in S3/MLflow instead of returning them via the API.
Check the S3 bucket or MLflow experiment for detailed results.</p>
</div>"""

# Full JSON dump section (collapsible)
report += """<h2>Full Job Results (JSON)</h2>
<details style="margin-bottom:1rem">
<summary style="cursor:pointer;font-weight:600;padding:.5rem;background:#fff;border-radius:6px;box-shadow:0 1px 3px rgba(0,0,0,.08)">Raw vLLM — Click to expand</summary>
"""
report += f'<pre style="background:#fff;padding:1rem;border-radius:0 0 6px 6px;font-size:.75rem;overflow-x:auto;max-height:400px;overflow-y:auto;font-family:\'Red Hat Mono\',monospace">{html.escape(json.dumps(raw, indent=2, default=str))}</pre>'
report += """</details>
<details style="margin-bottom:1rem">
<summary style="cursor:pointer;font-weight:600;padding:.5rem;background:#fff;border-radius:6px;box-shadow:0 1px 3px rgba(0,0,0,.08)">Guardrailed — Click to expand</summary>
"""
report += f'<pre style="background:#fff;padding:1rem;border-radius:0 0 6px 6px;font-size:.75rem;overflow-x:auto;max-height:400px;overflow-y:auto;font-family:\'Red Hat Mono\',monospace">{html.escape(json.dumps(guard, indent=2, default=str))}</pre>'
report += """</details>
"""

# Footer
report += f"""
<footer>
Generated by ČSOB Sandbox red teaming suite | Red Hat OpenShift AI 3.5.1 | Garak intents scan via EvalHub<br>
Classifier: patronus-studio/wolf-defender-prompt-injection | NeMo Guardrails (embedded)
</footer>
</div></body></html>"""

outfile = os.path.join(SCRIPT_DIR, "..", "tests", "garak-comparison-report.html")
os.makedirs(os.path.dirname(outfile), exist_ok=True)
with open(outfile, "w") as f:
    f.write(report)

print(f"  Report: {outfile}")
print()

# Summary
if raw_asr is not None and guard_asr is not None:
    reduction = ((raw_asr - guard_asr) / raw_asr * 100) if raw_asr > 0 else 0
    print(f"  Raw vLLM ASR:     {raw_asr*100:.1f}%")
    print(f"  Guardrailed ASR:  {guard_asr*100:.1f}%")
    print(f"  ASR Reduction:    {reduction:.0f}%")
elif has_structured_data:
    print("  Partial results available — see report for details")
else:
    print(f"  Raw vLLM status:     {raw_state}")
    print(f"  Guardrailed status:  {guard_state}")
    if raw_state == "completed" and guard_state == "completed":
        print("  Both completed — metrics may be in S3/MLflow rather than API response")
    else:
        print("  Check EvalHub logs for errors")

PYEOF
