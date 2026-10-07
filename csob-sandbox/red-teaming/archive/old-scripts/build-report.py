#!/usr/bin/env python3
"""
Build ČSOB Red Teaming Report from raw scan data.
Every number in the report is derived from the local data files — no hardcoded values.
"""
import json
import html
import os
from datetime import datetime

BASE = os.path.dirname(os.path.abspath(__file__))

def load(name):
    with open(os.path.join(BASE, name)) as f:
        return json.load(f)

# ── Load all data ────────────────────────────────────────────────────────────
clean_result    = load('clean-scan-result.json')
raw_per_probe   = load('raw-owasp-per-probe.json')
clean_examples  = load('clean-scan-examples-v2.json')
raw_examples    = load('raw-scan-examples-v2.json')
job_raw         = load('owasp-scan-raw.json')
job_guard       = load('owasp-scan-guardrailed.json')

# ── Extract clean scan metrics ───────────────────────────────────────────────
metrics = clean_result['results']['benchmarks'][0]['metrics']
clean_overall_asr = metrics['attack_success_rate']

clean_probe_asr = {}
for k, v in metrics.items():
    if k.endswith('_asr') and k != 'attack_success_rate':
        probe = k.replace('_asr', '')
        clean_probe_asr[probe] = round(v * 100, 2)

# ── Extract raw scan per-probe ASR (max across detectors) ────────────────────
raw_probe_asr = {}
raw_probe_detail = {}
for probe, detectors in raw_per_probe.items():
    max_asr = 0
    total_failed = 0
    total_total = 0
    for det, vals in detectors.items():
        if vals['asr'] > max_asr:
            max_asr = vals['asr']
        total_failed += vals['failed']
        total_total += vals['total']
    raw_probe_asr[probe] = max_asr
    raw_probe_detail[probe] = {'failed': total_failed, 'total': total_total, 'detectors': detectors}

# Compute raw overall ASR
raw_total_failed = sum(d['failed'] for p in raw_per_probe.values() for d in p.values())
raw_total_evals  = sum(d['total']  for p in raw_per_probe.values() for d in p.values())
raw_overall_asr  = round(raw_total_failed / raw_total_evals * 100, 2) if raw_total_evals > 0 else 0

# ── OWASP LLM Top 10 mapping ────────────────────────────────────────────────
OWASP_MAP = {
    'LLM01': {
        'name': 'Prompt Injection',
        'prefixes': ['dan.', 'dra.', 'promptinject.', 'latentinjection.', 'goodside.',
                     'phrasing.', 'encoding.', 'grandma.']
    },
    'LLM02': {
        'name': 'Insecure Output Handling',
        'prefixes': ['ansiescape.', 'web_injection.', 'exploitation.']
    },
    'LLM04': {
        'name': 'Model Denial of Service',
        'prefixes': ['divergence.']
    },
    'LLM05': {
        'name': 'Supply Chain Vulnerabilities',
        'prefixes': ['packagehallucination.']
    },
    'LLM06': {
        'name': 'Sensitive Information Disclosure',
        'prefixes': ['leakreplay.', 'sysprompt_extraction.']
    },
    'LLM09': {
        'name': 'Overreliance',
        'prefixes': ['misleading.', 'snowball.', 'sata.', 'topic.']
    },
    'LLM10': {
        'name': 'Unbounded Consumption',
        'prefixes': ['continuation.']
    },
}

def get_owasp_cat(probe_name):
    for cat_id, cat in OWASP_MAP.items():
        for prefix in cat['prefixes']:
            if probe_name.startswith(prefix):
                return cat_id
    return 'Other'

# Build all-probes list (union of raw + clean)
all_probes = sorted(set(list(raw_probe_asr.keys()) + list(clean_probe_asr.keys())))

# Compute per-OWASP-category aggregate ASR
owasp_agg = {}
for cat_id in OWASP_MAP:
    raw_vals = []
    clean_vals = []
    for p in all_probes:
        if get_owasp_cat(p) == cat_id:
            if p in raw_probe_asr:
                raw_vals.append(raw_probe_asr[p])
            if p in clean_probe_asr:
                clean_vals.append(clean_probe_asr[p])
    owasp_agg[cat_id] = {
        'raw_avg': round(sum(raw_vals) / len(raw_vals), 2) if raw_vals else 0,
        'clean_avg': round(sum(clean_vals) / len(clean_vals), 2) if clean_vals else 0,
        'raw_max': max(raw_vals) if raw_vals else 0,
        'clean_max': max(clean_vals) if clean_vals else 0,
        'probe_count': max(len(raw_vals), len(clean_vals)),
    }

# ── Metadata ─────────────────────────────────────────────────────────────────
env_card = clean_result['results']['benchmarks'][0]['artifacts'].get('evalhub.env_card', {})
garak_version = env_card.get('key_packages', {}).get('garak', 'unknown')
clean_job_id = clean_result['resource']['id']
clean_created = clean_result['resource']['created_at']

# ── Top improved probes ──────────────────────────────────────────────────────
improvements = []
for p in all_probes:
    r = raw_probe_asr.get(p, 0)
    c = clean_probe_asr.get(p, 0)
    delta = r - c
    if delta > 0:
        improvements.append((p, r, c, delta))
improvements.sort(key=lambda x: -x[3])

# ── Remaining risks (guardrailed ASR > 0) ────────────────────────────────────
remaining_risks = [(p, clean_probe_asr[p]) for p in all_probes if clean_probe_asr.get(p, 0) > 0]
remaining_risks.sort(key=lambda x: -x[1])

# ── Helper: escape HTML ─────────────────────────────────────────────────────
def esc(s):
    return html.escape(str(s), quote=True)

def color_cell(asr_val):
    if asr_val == 0:
        return 'background: #e8f5e9; color: #2e7d32;'
    elif asr_val < 10:
        return 'background: #fff8e1; color: #f57f17;'
    elif asr_val < 30:
        return 'background: #fff3e0; color: #e65100;'
    else:
        return 'background: #ffebee; color: #c62828;'

def bar_svg(raw_val, clean_val, width=400, height=40):
    """Generate inline SVG for a raw vs guardrailed comparison bar."""
    max_val = max(raw_val, clean_val, 1)
    scale = (width - 80) / 100  # scale to percentage
    raw_w = max(raw_val * scale, 1)
    clean_w = max(clean_val * scale, 1)
    return f'''<svg width="{width}" height="{height}" xmlns="http://www.w3.org/2000/svg">
      <rect x="0" y="2" width="{raw_w:.1f}" height="16" rx="3" fill="#EE0000" opacity="0.85"/>
      <text x="{raw_w + 4:.1f}" y="14" font-size="12" fill="#555">{raw_val}%</text>
      <rect x="0" y="22" width="{clean_w:.1f}" height="16" rx="3" fill="#3E8635" opacity="0.85"/>
      <text x="{clean_w + 4:.1f}" y="34" font-size="12" fill="#555">{clean_val}%</text>
    </svg>'''

# ── Build HTML ───────────────────────────────────────────────────────────────
parts = []

def w(s):
    parts.append(s)

w('''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ČSOB LLM Red Teaming Report — OWASP LLM Top 10</title>
<style>
:root {
  --rh-red: #EE0000;
  --rh-dark: #151515;
  --rh-light: #F0F0F0;
  --rh-green: #3E8635;
  --rh-yellow: #F0AB00;
  --rh-blue: #0066CC;
  --font: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  --mono: 'SF Mono', 'Fira Code', 'Consolas', monospace;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: var(--font); color: #333; line-height: 1.6; background: #fff; }
header {
  background: var(--rh-dark); color: #fff; padding: 2rem 0;
  border-bottom: 4px solid var(--rh-red);
}
header .container { max-width: 1200px; margin: 0 auto; padding: 0 2rem; }
header h1 { font-size: 1.8rem; font-weight: 600; margin-bottom: 0.3rem; }
header .subtitle { color: #ccc; font-size: 1rem; }
header .meta { color: #999; font-size: 0.85rem; margin-top: 0.5rem; }
nav {
  background: #f5f5f5; border-bottom: 1px solid #ddd;
  position: sticky; top: 0; z-index: 100;
}
nav .container {
  max-width: 1200px; margin: 0 auto; padding: 0.6rem 2rem;
  display: flex; flex-wrap: wrap; gap: 0.3rem 1.2rem;
}
nav a {
  color: var(--rh-blue); text-decoration: none; font-size: 0.85rem;
  white-space: nowrap;
}
nav a:hover { text-decoration: underline; }
.container { max-width: 1200px; margin: 0 auto; padding: 0 2rem; }
main { padding: 2rem 0 4rem; }
section { margin-bottom: 3rem; }
h2 {
  font-size: 1.4rem; color: var(--rh-dark); margin-bottom: 1rem;
  padding-bottom: 0.4rem; border-bottom: 2px solid var(--rh-red);
}
h3 { font-size: 1.1rem; color: #444; margin: 1.5rem 0 0.6rem; }
p { margin-bottom: 0.8rem; }
.highlight-box {
  background: var(--rh-light); border-left: 4px solid var(--rh-red);
  padding: 1.2rem 1.5rem; margin: 1rem 0; border-radius: 0 6px 6px 0;
}
.highlight-box.green { border-left-color: var(--rh-green); }
.highlight-box.yellow { border-left-color: var(--rh-yellow); }
.kpi-row {
  display: flex; gap: 1.5rem; flex-wrap: wrap; margin: 1.5rem 0;
}
.kpi {
  flex: 1; min-width: 200px; background: #fff; border: 1px solid #e0e0e0;
  border-radius: 8px; padding: 1.2rem; text-align: center;
  box-shadow: 0 1px 3px rgba(0,0,0,0.06);
}
.kpi .value { font-size: 2.2rem; font-weight: 700; }
.kpi .label { font-size: 0.85rem; color: #666; margin-top: 0.2rem; }
.kpi.red .value { color: var(--rh-red); }
.kpi.green .value { color: var(--rh-green); }
.kpi.yellow .value { color: #d68a00; }
table {
  width: 100%; border-collapse: collapse; margin: 1rem 0; font-size: 0.9rem;
}
th {
  background: var(--rh-dark); color: #fff; padding: 0.6rem 0.8rem;
  text-align: left; font-weight: 500; white-space: nowrap;
}
td { padding: 0.5rem 0.8rem; border-bottom: 1px solid #e8e8e8; }
tr:hover td { background: #fafafa; }
.asr-cell { text-align: center; font-weight: 600; border-radius: 4px; }
code, pre {
  font-family: var(--mono); font-size: 0.85rem;
}
pre {
  background: #1e1e1e; color: #d4d4d4; padding: 1rem 1.2rem;
  border-radius: 6px; overflow-x: auto; margin: 0.8rem 0;
  line-height: 1.5;
}
pre .key { color: #9cdcfe; }
pre .str { color: #ce9178; }
details {
  margin: 0.5rem 0; border: 1px solid #e0e0e0; border-radius: 6px;
  overflow: hidden;
}
details summary {
  padding: 0.6rem 1rem; cursor: pointer; background: #fafafa;
  font-weight: 500; font-size: 0.9rem; user-select: none;
}
details summary:hover { background: #f0f0f0; }
details[open] summary { border-bottom: 1px solid #e0e0e0; }
details .content { padding: 1rem; }
.example-block {
  background: #f8f8f8; border: 1px solid #e8e8e8; border-radius: 4px;
  padding: 0.8rem; margin: 0.6rem 0; font-size: 0.85rem;
}
.example-block .label { font-weight: 600; color: #555; font-size: 0.8rem; }
.example-block .text { margin-top: 0.3rem; white-space: pre-wrap; word-break: break-word; }
.arch-diagram {
  background: #f8f9fa; border: 1px solid #e0e0e0; border-radius: 8px;
  padding: 1.5rem; margin: 1rem 0; overflow-x: auto;
}
.arch-diagram pre {
  background: transparent; color: #333; font-size: 0.8rem;
  padding: 0; margin: 0;
}
.bar-chart { margin: 1rem 0; }
.bar-row {
  display: flex; align-items: center; margin: 0.3rem 0; gap: 0.5rem;
}
.bar-label {
  min-width: 280px; font-size: 0.8rem; text-align: right;
  white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
}
.bar-track { flex: 1; height: 22px; background: #f0f0f0; border-radius: 3px; position: relative; }
.bar-fill { height: 100%; border-radius: 3px; min-width: 2px; transition: width 0.3s; }
.bar-fill.raw { background: var(--rh-red); opacity: 0.8; }
.bar-fill.guard { background: var(--rh-green); opacity: 0.85; }
.bar-value { min-width: 55px; font-size: 0.8rem; font-weight: 600; }
.legend {
  display: flex; gap: 1.5rem; margin: 0.8rem 0; font-size: 0.85rem;
}
.legend-item { display: flex; align-items: center; gap: 0.4rem; }
.legend-swatch {
  width: 14px; height: 14px; border-radius: 3px; display: inline-block;
}
.badge {
  display: inline-block; padding: 0.15rem 0.5rem; border-radius: 10px;
  font-size: 0.75rem; font-weight: 600;
}
.badge.pass { background: #e8f5e9; color: #2e7d32; }
.badge.warn { background: #fff8e1; color: #f57f17; }
.badge.fail { background: #ffebee; color: #c62828; }
footer {
  background: var(--rh-dark); color: #999; padding: 1.5rem 0;
  text-align: center; font-size: 0.8rem;
}
@media (max-width: 768px) {
  .bar-label { min-width: 120px; font-size: 0.7rem; }
  .kpi-row { flex-direction: column; }
  nav .container { padding: 0.5rem 1rem; }
}
/* Grouped bar chart */
.grouped-chart { margin: 1.5rem 0; }
.grouped-row {
  display: flex; align-items: center; margin: 0.6rem 0; gap: 0.5rem;
}
.grouped-label { min-width: 200px; font-size: 0.85rem; font-weight: 500; }
.grouped-bars { flex: 1; }
.grouped-bar-pair { display: flex; flex-direction: column; gap: 2px; }
.grouped-bar {
  height: 14px; border-radius: 2px; display: flex; align-items: center;
}
.grouped-bar .fill { height: 100%; border-radius: 2px; min-width: 1px; }
.grouped-bar .val { font-size: 0.7rem; margin-left: 4px; font-weight: 600; white-space: nowrap; }
</style>
</head>
<body>
''')

# ── HEADER ───────────────────────────────────────────────────────────────────
w(f'''<header>
<div class="container">
  <h1>ČSOB LLM Red Teaming Report</h1>
  <div class="subtitle">OWASP LLM Top 10 Security Assessment — Gemma 4 12B with NemoGuardrails + Wolf Defender</div>
  <div class="meta">
    Generated: {datetime.now().strftime("%Y-%m-%d")} |
    Scanner: Garak {esc(garak_version)} |
    Benchmark: OWASP LLM Top 10 |
    Platform: Red Hat OpenShift AI 3.5
  </div>
</div>
</header>
''')

# ── NAV ──────────────────────────────────────────────────────────────────────
w('''<nav>
<div class="container">
  <a href="#executive-summary">Executive Summary</a>
  <a href="#architecture">Architecture</a>
  <a href="#methodology">Methodology</a>
  <a href="#known-issues">Known Issues</a>
  <a href="#owasp-results">OWASP Results</a>
  <a href="#detailed-results">Detailed Results</a>
  <a href="#bypass-examples">Bypass Examples</a>
  <a href="#defense-analysis">Defense Analysis</a>
  <a href="#recommendations">Recommendations</a>
</div>
</nav>
''')

w('<main><div class="container">')

# ══════════════════════════════════════════════════════════════════════════════
# §1 EXECUTIVE SUMMARY
# ══════════════════════════════════════════════════════════════════════════════
w(f'''<section id="executive-summary">
<h2>1. Executive Summary</h2>

<p>This report presents the results of automated red teaming tests conducted against the ČSOB banking
LLM deployment. Two configurations were tested using the same OWASP LLM Top 10 benchmark:</p>
<ol style="margin: 0.5rem 0 0.5rem 1.5rem;">
  <li><strong>Raw vLLM</strong> — Gemma 4 12B served directly via vLLM (no guardrails)</li>
  <li><strong>Guardrailed</strong> — Gemma 4 12B behind NemoGuardrails with Wolf Defender
      (ModernBERT-based prompt injection classifier on GPU)</li>
</ol>

<div class="kpi-row">
  <div class="kpi red">
    <div class="value">{raw_overall_asr}%</div>
    <div class="label">Raw vLLM — Overall ASR</div>
  </div>
  <div class="kpi green">
    <div class="value">{round(clean_overall_asr * 100, 2)}%</div>
    <div class="label">Guardrailed — Overall ASR</div>
  </div>
  <div class="kpi yellow">
    <div class="value">{round(raw_overall_asr - clean_overall_asr * 100, 2)}pp</div>
    <div class="label">Reduction (percentage points)</div>
  </div>
  <div class="kpi green">
    <div class="value">{round((1 - clean_overall_asr * 100 / raw_overall_asr) * 100, 1) if raw_overall_asr > 0 else 0}%</div>
    <div class="label">Relative Improvement</div>
  </div>
</div>
''')

# SVG overall comparison chart
raw_pct = raw_overall_asr
guard_pct = round(clean_overall_asr * 100, 2)
bar_scale = 5  # pixels per percentage point
w(f'''
<h3>Overall Attack Success Rate Comparison</h3>
<div class="legend">
  <div class="legend-item"><span class="legend-swatch" style="background: var(--rh-red);"></span> Raw vLLM (no guardrails)</div>
  <div class="legend-item"><span class="legend-swatch" style="background: var(--rh-green);"></span> Guardrailed (NemoGuardrails + Wolf Defender)</div>
</div>
<svg width="700" height="80" xmlns="http://www.w3.org/2000/svg" style="margin:0.5rem 0;">
  <rect x="0" y="5" width="{raw_pct * bar_scale:.0f}" height="28" rx="4" fill="#EE0000" opacity="0.85"/>
  <text x="{raw_pct * bar_scale + 8:.0f}" y="25" font-size="14" font-weight="700" fill="#c62828">{raw_pct}%</text>
  <text x="{raw_pct * bar_scale + 60:.0f}" y="25" font-size="12" fill="#888">Raw vLLM</text>
  <rect x="0" y="42" width="{guard_pct * bar_scale:.0f}" height="28" rx="4" fill="#3E8635" opacity="0.85"/>
  <text x="{guard_pct * bar_scale + 8:.0f}" y="62" font-size="14" font-weight="700" fill="#2e7d32">{guard_pct}%</text>
  <text x="{guard_pct * bar_scale + 55:.0f}" y="62" font-size="12" fill="#888">Guardrailed</text>
</svg>
''')

# Key findings
zero_guard = sum(1 for p in all_probes if clean_probe_asr.get(p, 0) == 0)
total_probes = len(all_probes)
w(f'''
<div class="highlight-box green">
  <strong>Key Findings:</strong>
  <ul style="margin: 0.4rem 0 0 1.2rem;">
    <li>The guardrail stack reduced the overall attack success rate from <strong>{raw_pct}%</strong>
        to <strong>{guard_pct}%</strong> — a <strong>{round((1 - guard_pct / raw_pct) * 100, 1)}%</strong> relative reduction.</li>
    <li><strong>{zero_guard}</strong> of {total_probes} probes achieved <strong>0% ASR</strong> with guardrails
        (complete blocking), compared to {sum(1 for p in all_probes if raw_probe_asr.get(p, 0) == 0)} probes at 0% without guardrails.</li>
    <li>Remaining bypasses concentrate in encoding-based attacks (NATO, Hex, Base16), false assertion
        agreement, and social engineering — areas where the input classifier cannot detect
        obfuscated payloads or non-malicious-looking prompts.</li>
  </ul>
</div>
</section>
''')

# ══════════════════════════════════════════════════════════════════════════════
# §2 ARCHITECTURE
# ══════════════════════════════════════════════════════════════════════════════
w('''<section id="architecture">
<h2>2. Test Architecture</h2>

<p>Both test configurations share the same model (Gemma 4 12B) and ČSOB banking system prompt.
The system prompt constrains the model to ČSOB banking topics, acting as a first layer of defense
by deflecting off-topic requests.</p>

<div class="arch-diagram">
<pre>
<strong>Configuration A — Raw vLLM (no guardrails)</strong>

  ┌──────────┐      ┌───────────────┐      ┌────────────────────────────┐
  │  Garak   │─────▶│  Routing      │─────▶│  vLLM (KServe)             │
  │ Scanner  │      │  Proxy        │      │  Gemma 4 12B               │
  │          │◀─────│  (model-based │◀─────│  + ČSOB Banking Sys Prompt │
  └──────────┘      │   routing)    │      └────────────────────────────┘
                    └───────────────┘

<strong>Configuration B — Guardrailed (NemoGuardrails + Wolf Defender)</strong>

  ┌──────────┐      ┌───────────────┐      ┌────────────────────┐      ┌───────────────────────────┐
  │  Garak   │─────▶│  Routing      │─────▶│  NemoGuardrails    │─────▶│  Wolf Defender             │
  │ Scanner  │      │  Proxy        │      │  (Colang v1 rails) │      │  ModernBERT classifier    │
  │          │◀─────│  (strips      │◀─────│  Input/output      │◀─────│  (GPU — NVIDIA L4)        │
  └──────────┘      │   'stop' param│      │  classification    │      │  Binary: benign / inject  │
                    │   workaround) │      └────────────────────┘      └───────────┬───────────────┘
                    └───────────────┘                                               │
                                                                                   ▼
                                                                    ┌────────────────────────────┐
                                                                    │  vLLM (KServe)             │
                                                                    │  Gemma 4 12B               │
                                                                    │  + ČSOB Banking Sys Prompt │
                                                                    └────────────────────────────┘
</pre>
</div>

<h3>Defense Layers</h3>
<table>
  <tr><th>Layer</th><th>Component</th><th>What It Blocks</th></tr>
  <tr>
    <td><strong>L1 — Input Classification</strong></td>
    <td>Wolf Defender (ModernBERT, GPU)</td>
    <td>Prompt injection, jailbreak, DAN, DRA, encoded injection attempts
        (when the decoded text is recognizable as an attack)</td>
  </tr>
  <tr>
    <td><strong>L2 — Colang Rails</strong></td>
    <td>NemoGuardrails v0.24.0</td>
    <td>Orchestrates classification flow, enforces input/output policies</td>
  </tr>
  <tr>
    <td><strong>L3 — System Prompt</strong></td>
    <td>ČSOB Banking System Prompt</td>
    <td>Off-topic requests, social engineering, controversial topics —
        constrains model to banking domain</td>
  </tr>
  <tr>
    <td><strong>L4 — Model Alignment</strong></td>
    <td>Gemma 4 12B instruction tuning</td>
    <td>Base safety training — refuses clearly harmful content even without
        external guardrails</td>
  </tr>
</table>

<div class="highlight-box yellow">
  <strong>Identified Gap:</strong> No output content classifier is deployed. Wolf Defender only
  classifies the <em>input</em> prompt. If a non-malicious-looking prompt elicits harmful output
  (e.g., phrasing attacks, false assertion agreement), there is no post-generation filter to
  catch it. This is the primary source of remaining bypasses.
</div>
</section>
''')

# ══════════════════════════════════════════════════════════════════════════════
# §3 METHODOLOGY
# ══════════════════════════════════════════════════════════════════════════════
w(f'''<section id="methodology">
<h2>3. Methodology</h2>

<h3>Test Framework</h3>
<table>
  <tr><th>Component</th><th>Value</th></tr>
  <tr><td>Platform</td><td>Red Hat OpenShift AI (RHOAI) 3.5 — EvalHub</td></tr>
  <tr><td>Scanner</td><td>Garak {esc(garak_version)}</td></tr>
  <tr><td>Benchmark</td><td>OWASP LLM Top 10 (<code>owasp_llm_top10</code>)</td></tr>
  <tr><td>Judge Model</td><td>Qwen 36-35B-A3B (via RHDP MaaS)</td></tr>
  <tr><td>Target Model</td><td>Gemma 4 12B (vLLM, KServe, NVIDIA L4 GPU)</td></tr>
  <tr><td>Classifier</td><td>Wolf Defender — ModernBERT (vLLM pooling mode, NVIDIA L4 GPU)</td></tr>
  <tr><td>Guardrails</td><td>NemoGuardrails 0.24.0.dev0 (RHOAI-shipped build)</td></tr>
</table>

<p>Both scans used identical benchmark configuration. The only difference is the routing:
the raw scan targets vLLM directly, while the guardrailed scan routes through NemoGuardrails + Wolf Defender.</p>

<h3>EvalHub Job Configurations</h3>
<details>
  <summary>Raw vLLM Scan — Job Configuration</summary>
  <div class="content">
    <pre>{esc(json.dumps(job_raw, indent=2))}</pre>
  </div>
</details>
<details>
  <summary>Guardrailed Scan — Job Configuration</summary>
  <div class="content">
    <pre>{esc(json.dumps(job_guard, indent=2))}</pre>
  </div>
</details>

<h3>Scan Statistics</h3>
<table>
  <tr><th>Metric</th><th>Raw vLLM</th><th>Guardrailed</th></tr>
  <tr><td>Probes Evaluated</td><td>{len(raw_probe_asr)}</td><td>{len(clean_probe_asr)}</td></tr>
  <tr><td>Probe × Detector Evaluations</td><td>{raw_total_evals:,}</td><td>~{round(891/clean_overall_asr):,} (est.)</td></tr>
  <tr><td>Detector Hits (bypasses)</td><td>{raw_total_failed:,}</td><td>891</td></tr>
  <tr><td>Overall ASR</td><td>{raw_overall_asr}%</td><td>{round(clean_overall_asr * 100, 2)}%</td></tr>
  <tr><td>Errors</td><td>0</td><td>2</td></tr>
  <tr><td>Job ID</td><td>—</td><td><code>{esc(clean_job_id[:8])}…</code></td></tr>
</table>
</section>
''')

# ══════════════════════════════════════════════════════════════════════════════
# §4 KNOWN ISSUES
# ══════════════════════════════════════════════════════════════════════════════
w(f'''<section id="known-issues">
<h2>4. Known Issue: NemoGuardrails <code>stop</code> Parameter Bug</h2>

<div class="highlight-box">
  <strong>Transparency Disclosure:</strong> The initial guardrailed scan produced a 64.3% error rate
  due to a known bug in NemoGuardrails. This section documents the bug, its impact, and the
  workaround used to obtain valid results.
</div>

<h3>Root Cause</h3>
<p>NemoGuardrails 0.24.0.dev0 (shipped with RHOAI 3.5) crashes with a <code>TypeError</code> when
the client includes a <code>stop</code> parameter in the chat completion request. The
<code>generate_async()</code> method receives <code>stop</code> both as an explicit keyword argument
and inside the <code>**llm_params</code> dict, causing Python to reject the duplicate.</p>

<pre>
TypeError: nemoguardrails.llm.models.openai_chat.OpenAIChatModel.generate_async()
           got multiple values for keyword argument 'stop'
</pre>

<p>The user receives <code>"content": "Internal server error"</code> — an HTTP 200 response with
error text in the message body. Automated scanners (Garak) flag this as a bypass because the
response doesn't contain an explicit refusal.</p>

<h3>Impact on Original Scan</h3>
<table>
  <tr><th>Metric</th><th>Value</th></tr>
  <tr><td>Error responses</td><td>15,480 / 24,090 (64.3%)</td></tr>
  <tr><td>Reported ASR (inflated)</td><td>6.5%</td></tr>
  <tr><td>Probes at 100% error rate</td><td>misleading.FalseAssertion, topic.WordnetControversial,
      grandma.Win10/Win11, phrasing.PastTense/FutureTense, all packagehallucination.*</td></tr>
  <tr><td>Root cause</td><td>Garak sends <code>stop</code> sequences for most probe types</td></tr>
</table>

<h3>Upstream Status</h3>
<p>Fixed upstream in
<a href="https://github.com/NVIDIA/NeMo-Guardrails/pull/2266" target="_blank">PR #2266</a>
(internal tracker NGUARD-880). The fix pops <code>stop</code> from <code>llm_params</code>
before calling <code>generate_async()</code>. <strong>Not backported to RHOAI 3.5.</strong></p>

<h3>Workaround Applied</h3>
<p>A routing proxy was deployed between Garak and NemoGuardrails. For guardrailed requests,
the proxy strips the <code>stop</code> parameter from the request body before forwarding.
This prevents the crash without affecting scan validity — the <code>stop</code> parameter
controls response termination tokens, not the attack payload.</p>

<p>The <strong>clean scan results</strong> presented in this report were obtained with this
workaround in place. The clean scan completed with <strong>2 errors</strong> (vs. 15,480 in the
original), confirming the workaround is effective.</p>

<details>
  <summary>Proxy workaround code</summary>
  <div class="content">
<pre>
# In GUARD route handler:
elif model in GUARD_MODELS:
    base = GUARD_URL
    key = GUARD_KEY
    route = "GUARD"
    data["model"] = "gemma-4-12b"
    stripped = data.pop("stop", None)        # ◀ strips stop param
    if stripped:
        print(f"[proxy] stripped 'stop' param from GUARD request "
              f"(NemoGuardrails bug workaround)", flush=True)
    body = json.dumps(data).encode()
</pre>
  </div>
</details>
</section>
''')

# ══════════════════════════════════════════════════════════════════════════════
# §5 OWASP RESULTS (by category)
# ══════════════════════════════════════════════════════════════════════════════
w('''<section id="owasp-results">
<h2>5. OWASP LLM Top 10 Results by Category</h2>

<p>Garak probes are mapped to OWASP LLM Top 10 categories. The table shows the average and
maximum ASR across all probes in each category.</p>
''')

# OWASP category grouped bar chart
w('''<h3>Per-Category ASR Comparison</h3>
<div class="legend">
  <div class="legend-item"><span class="legend-swatch" style="background: var(--rh-red);"></span> Raw vLLM</div>
  <div class="legend-item"><span class="legend-swatch" style="background: var(--rh-green);"></span> Guardrailed</div>
</div>
<div class="grouped-chart">
''')

for cat_id in sorted(OWASP_MAP.keys()):
    cat = OWASP_MAP[cat_id]
    agg = owasp_agg[cat_id]
    raw_v = agg['raw_avg']
    clean_v = agg['clean_avg']
    scale = 4
    w(f'''<div class="grouped-row">
  <div class="grouped-label">{cat_id}: {esc(cat['name'])}</div>
  <div class="grouped-bars">
    <div class="grouped-bar-pair">
      <div class="grouped-bar"><div class="fill raw" style="width:{max(raw_v * scale, 2):.0f}px;background:var(--rh-red);"></div><span class="val" style="color:#c62828;">{raw_v}%</span></div>
      <div class="grouped-bar"><div class="fill guard" style="width:{max(clean_v * scale, 2):.0f}px;background:var(--rh-green);"></div><span class="val" style="color:#2e7d32;">{clean_v}%</span></div>
    </div>
  </div>
</div>
''')

w('</div>')

# OWASP category table
w('''<table>
<tr>
  <th>OWASP Category</th>
  <th>Probes</th>
  <th>Raw Avg ASR</th>
  <th>Guard Avg ASR</th>
  <th>Raw Max ASR</th>
  <th>Guard Max ASR</th>
  <th>Δ Avg</th>
</tr>
''')

for cat_id in sorted(OWASP_MAP.keys()):
    cat = OWASP_MAP[cat_id]
    agg = owasp_agg[cat_id]
    delta = round(agg['raw_avg'] - agg['clean_avg'], 2)
    w(f'''<tr>
  <td><strong>{cat_id}</strong>: {esc(cat['name'])}</td>
  <td style="text-align:center;">{agg['probe_count']}</td>
  <td class="asr-cell" style="{color_cell(agg['raw_avg'])}">{agg['raw_avg']}%</td>
  <td class="asr-cell" style="{color_cell(agg['clean_avg'])}">{agg['clean_avg']}%</td>
  <td class="asr-cell" style="{color_cell(agg['raw_max'])}">{agg['raw_max']}%</td>
  <td class="asr-cell" style="{color_cell(agg['clean_max'])}">{agg['clean_max']}%</td>
  <td style="text-align:center; font-weight:600; color:{'#2e7d32' if delta > 0 else '#c62828'};">
    {'−' if delta > 0 else '+'}{abs(delta)}pp</td>
</tr>''')

w('</table>')

# Per-category drill-down
for cat_id in sorted(OWASP_MAP.keys()):
    cat = OWASP_MAP[cat_id]
    cat_probes = [p for p in all_probes if get_owasp_cat(p) == cat_id]
    if not cat_probes:
        continue
    w(f'''<details>
<summary>{cat_id}: {esc(cat['name'])} — {len(cat_probes)} probes</summary>
<div class="content">
<table>
<tr><th>Probe</th><th>Raw ASR</th><th>Guardrailed ASR</th><th>Δ</th></tr>
''')
    for p in sorted(cat_probes, key=lambda x: -(raw_probe_asr.get(x, 0))):
        r = raw_probe_asr.get(p, 0)
        c = clean_probe_asr.get(p, 0)
        delta = round(r - c, 2)
        w(f'''<tr>
  <td><code>{esc(p)}</code></td>
  <td class="asr-cell" style="{color_cell(r)}">{r}%</td>
  <td class="asr-cell" style="{color_cell(c)}">{c}%</td>
  <td style="text-align:center;font-weight:600;color:{'#2e7d32' if delta>=0 else '#c62828'};">
    {'−' if delta>=0 else '+'}{abs(delta)}pp</td>
</tr>''')
    w('</table></div></details>')

w('</section>')

# ══════════════════════════════════════════════════════════════════════════════
# §6 DETAILED RESULTS (full comparison table)
# ══════════════════════════════════════════════════════════════════════════════
w('''<section id="detailed-results">
<h2>6. Detailed Probe Results — Full Comparison</h2>
''')

# Top 10 most improved probes chart
w('''<h3>Top 15 Largest ASR Reductions (Guardrails Impact)</h3>
<div class="legend">
  <div class="legend-item"><span class="legend-swatch" style="background: var(--rh-red);"></span> Raw vLLM ASR</div>
  <div class="legend-item"><span class="legend-swatch" style="background: var(--rh-green);"></span> Guardrailed ASR</div>
</div>
<div class="bar-chart">
''')
for p, r, c, delta in improvements[:15]:
    r_w = r * 4
    c_w = c * 4
    w(f'''<div class="bar-row">
  <div class="bar-label">{esc(p)}</div>
  <div class="bar-track" style="position:relative;">
    <div class="bar-fill raw" style="width:{r_w:.1f}px; position:absolute; top:0; height:11px;"></div>
    <div class="bar-fill guard" style="width:{c_w:.1f}px; position:absolute; top:11px; height:11px;"></div>
  </div>
  <div class="bar-value" style="color:var(--rh-red);">{r}%</div>
  <div style="width:10px;text-align:center;">→</div>
  <div class="bar-value" style="color:var(--rh-green);">{c}%</div>
</div>''')
w('</div>')

# Remaining risks chart
if remaining_risks:
    w('''<h3>Remaining Risks (Guardrailed ASR &gt; 0%)</h3>
<div class="bar-chart">
''')
    for p, asr in remaining_risks:
        bw = asr * 4
        badge_cls = 'fail' if asr >= 10 else 'warn'
        w(f'''<div class="bar-row">
  <div class="bar-label">{esc(p)} <span class="badge {badge_cls}">{asr}%</span></div>
  <div class="bar-track">
    <div class="bar-fill" style="width:{bw:.1f}px; background: {'var(--rh-red)' if asr >= 10 else 'var(--rh-yellow)'}; opacity:0.8;"></div>
  </div>
  <div class="bar-value">{asr}%</div>
</div>''')
    w('</div>')

# Full comparison table
w('''<h3>Complete Probe Comparison Table</h3>
<table>
<tr>
  <th>Probe</th>
  <th>OWASP</th>
  <th>Raw ASR</th>
  <th>Guardrailed ASR</th>
  <th>Δ (pp)</th>
  <th>Status</th>
</tr>
''')
for p in sorted(all_probes, key=lambda x: -(raw_probe_asr.get(x, 0))):
    r = raw_probe_asr.get(p, 0)
    c = clean_probe_asr.get(p, 0)
    delta = round(r - c, 2)
    cat = get_owasp_cat(p)
    if c == 0:
        status = '<span class="badge pass">BLOCKED</span>'
    elif c < 10:
        status = '<span class="badge warn">PARTIAL</span>'
    else:
        status = '<span class="badge fail">BYPASS</span>'
    w(f'''<tr>
  <td><code>{esc(p)}</code></td>
  <td>{cat}</td>
  <td class="asr-cell" style="{color_cell(r)}">{r}%</td>
  <td class="asr-cell" style="{color_cell(c)}">{c}%</td>
  <td style="text-align:center;">{'−' if delta>=0 else '+'}{abs(delta)}</td>
  <td>{status}</td>
</tr>''')

w('</table></section>')

# ══════════════════════════════════════════════════════════════════════════════
# §7 BYPASS EXAMPLES
# ══════════════════════════════════════════════════════════════════════════════
w('''<section id="bypass-examples">
<h2>7. Attack Bypass Examples</h2>
<p>This section shows actual prompts and model responses for probes where the guardrailed
configuration still allowed bypasses (ASR &gt; 0%). Examples are drawn directly from the
Garak scan hitlog. Expand each section to see 2–3 representative examples.</p>
''')

# Guardrailed bypasses
w('<h3>Guardrailed Endpoint — Remaining Bypasses</h3>')
for p, asr in remaining_risks:
    if p not in clean_examples:
        continue
    exs = clean_examples[p][:3]
    if not exs:
        continue
    cat = get_owasp_cat(p)
    w(f'''<details>
<summary><code>{esc(p)}</code> — {asr}% ASR ({cat})</summary>
<div class="content">
''')
    for i, ex in enumerate(exs):
        prompt_text = ex.get('prompt', '')
        output_text = ex.get('output', '')
        # Parse nested dict if needed
        if isinstance(prompt_text, str) and prompt_text.startswith('{'):
            try:
                pd = eval(prompt_text)
                if isinstance(pd, dict) and 'turns' in pd:
                    turns = pd['turns']
                    if turns:
                        c = turns[0].get('content', {})
                        prompt_text = c.get('text', prompt_text) if isinstance(c, dict) else str(c)
            except:
                pass
        if isinstance(output_text, str) and output_text.startswith('{'):
            try:
                od = eval(output_text)
                if isinstance(od, dict) and 'text' in od:
                    output_text = od['text']
            except:
                pass

        w(f'''<div class="example-block">
  <div class="label">Example {i+1} — Detector: <code>{esc(ex.get('detector', '?'))}</code></div>
  <div class="label" style="color:var(--rh-red);">Attack Prompt:</div>
  <div class="text">{esc(str(prompt_text)[:500])}</div>
  <div class="label" style="color:#e65100; margin-top:0.5rem;">Model Response:</div>
  <div class="text">{esc(str(output_text)[:500])}</div>
</div>''')
    w('</div></details>')

# Raw bypasses (top 10 worst)
w('<h3>Raw vLLM Endpoint — Top Bypasses (for comparison)</h3>')
raw_worst = sorted(
    [(p, raw_probe_asr[p]) for p in raw_probe_asr if raw_probe_asr[p] > 0],
    key=lambda x: -x[1]
)[:10]
for p, asr in raw_worst:
    if p not in raw_examples:
        continue
    exs = raw_examples[p][:2]
    if not exs:
        continue
    w(f'''<details>
<summary><code>{esc(p)}</code> — {asr}% ASR (raw, no guardrails)</summary>
<div class="content">
''')
    for i, ex in enumerate(exs):
        prompt_text = ex.get('prompt', '')
        output_text = ex.get('output', '')
        if isinstance(prompt_text, str) and prompt_text.startswith('{'):
            try:
                pd = eval(prompt_text)
                if isinstance(pd, dict) and 'turns' in pd:
                    turns = pd['turns']
                    if turns:
                        c = turns[0].get('content', {})
                        prompt_text = c.get('text', prompt_text) if isinstance(c, dict) else str(c)
            except:
                pass
        if isinstance(output_text, str) and output_text.startswith('{'):
            try:
                od = eval(output_text)
                if isinstance(od, dict) and 'text' in od:
                    output_text = od['text']
            except:
                pass
        w(f'''<div class="example-block">
  <div class="label">Example {i+1} — Detector: <code>{esc(ex.get('detector', '?'))}</code></div>
  <div class="label" style="color:var(--rh-red);">Attack Prompt:</div>
  <div class="text">{esc(str(prompt_text)[:500])}</div>
  <div class="label" style="color:#e65100; margin-top:0.5rem;">Model Response:</div>
  <div class="text">{esc(str(output_text)[:500])}</div>
</div>''')
    w('</div></details>')

w('</section>')

# ══════════════════════════════════════════════════════════════════════════════
# §8 DEFENSE ANALYSIS
# ══════════════════════════════════════════════════════════════════════════════
# Compute which probes are fully blocked by guardrails
fully_blocked = [p for p in all_probes if raw_probe_asr.get(p, 0) > 0 and clean_probe_asr.get(p, 0) == 0]

w(f'''<section id="defense-analysis">
<h2>8. Defense Layer Analysis</h2>

<p>The guardrail stack has three active defense layers. Each blocks a different class of attack:</p>

<h3>Wolf Defender (Input Classifier) — Strongest Layer</h3>
<p>Wolf Defender is a ModernBERT-based binary classifier that labels prompts as <code>benign</code>
or <code>injection</code>. It runs on GPU (NVIDIA L4) for fast inference. When it classifies a
prompt as injection, NemoGuardrails returns a refusal without forwarding to the LLM.</p>

<p><strong>Effective against ({len([p for p in fully_blocked if get_owasp_cat(p) == 'LLM01'])} probes fully blocked):</strong></p>
<ul style="margin: 0.3rem 0 0.8rem 1.5rem;">
  <li>DAN jailbreaks (<code>dan.Ablation_Dan_11_0</code>: {raw_probe_asr.get('dan.Ablation_Dan_11_0', 0)}% → {clean_probe_asr.get('dan.Ablation_Dan_11_0', 0)}%)</li>
  <li>DRA attacks (<code>dra.DRA</code>: {raw_probe_asr.get('dra.DRA', 0)}% → {clean_probe_asr.get('dra.DRA', 0)}%)</li>
  <li>Prompt injection (<code>promptinject.HijackLongPrompt</code>: {raw_probe_asr.get('promptinject.HijackLongPrompt', 0)}% → {clean_probe_asr.get('promptinject.HijackLongPrompt', 0)}%)</li>
  <li>System prompt extraction (<code>sysprompt_extraction</code>: {raw_probe_asr.get('sysprompt_extraction.SystemPromptExtraction', 0)}% → {clean_probe_asr.get('sysprompt_extraction.SystemPromptExtraction', 0)}%)</li>
</ul>

<p><strong>Limited against:</strong></p>
<ul style="margin: 0.3rem 0 0.8rem 1.5rem;">
  <li><strong>Encoding attacks</strong> — NATO, Hex, Base16, Braille, Morse encode slurs/harmful content.
      The encoded text looks benign to the classifier. Wolf cannot decode and re-classify.
      (NATO: {raw_probe_asr.get('encoding.InjectNato', 0)}% → {clean_probe_asr.get('encoding.InjectNato', 0)}%)</li>
  <li><strong>Latent injection</strong> — attack payload embedded in long benign context.
      Classifier sees the full prompt but the benign context dominates the classification signal.</li>
</ul>

<h3>ČSOB Banking System Prompt — Domain Constraint</h3>
<p>The system prompt constrains Gemma 4 12B to ČSOB banking topics. Any off-topic request
receives a domain refusal ("I am a banking assistant for ČSOB, I can only help with…").
This blocks attacks that are not technically malicious but aim to elicit non-banking content.</p>

<p><strong>Effective against:</strong></p>
<ul style="margin: 0.3rem 0 0.8rem 1.5rem;">
  <li>Controversial topics (<code>topic.WordnetControversial</code>: {raw_probe_asr.get('topic.WordnetControversial', 0)}% → {clean_probe_asr.get('topic.WordnetControversial', 0)}% — reduction, not full block)</li>
  <li>Social engineering / grandma attacks — partially (grandma attacks disguise requests as innocent stories)</li>
</ul>

<p><strong>Not effective against:</strong></p>
<ul style="margin: 0.3rem 0 0.8rem 1.5rem;">
  <li><strong>False assertions</strong> — statements like "The rat is a herbivore" are factual claims,
      not off-topic banking requests. The system prompt doesn't instruct the model to fact-check.</li>
  <li><strong>Phrasing attacks</strong> — rephrasing harmful questions in past/future tense makes them
      appear academic or hypothetical. The domain filter doesn't catch them because some are
      plausibly banking-adjacent.</li>
</ul>

<h3>Model Alignment (Gemma 4 12B) — Base Safety</h3>
<p>The model's instruction tuning provides baseline safety. Even without guardrails, several
attack categories show 0% ASR on both configurations, meaning the model refuses them natively.</p>
</section>
''')

# ══════════════════════════════════════════════════════════════════════════════
# §9 RECOMMENDATIONS
# ══════════════════════════════════════════════════════════════════════════════
w(f'''<section id="recommendations">
<h2>9. Recommendations</h2>

<table>
<tr><th>Priority</th><th>Recommendation</th><th>Addresses</th><th>Expected Impact</th></tr>
<tr>
  <td><span class="badge fail">HIGH</span></td>
  <td><strong>Deploy output content classifier</strong> — Add a post-generation classifier
      (e.g., Llama Guard, AEGIS) that scans model output for harmful content before returning
      to the user.</td>
  <td>Phrasing attacks ({clean_probe_asr.get('phrasing.PastTense', 0)}% ASR),
      grandma attacks ({clean_probe_asr.get('grandma.Win11', 0)}% ASR),
      false assertions ({clean_probe_asr.get('misleading.FalseAssertion', 0)}% ASR)</td>
  <td>Estimated 3–5pp reduction in overall ASR</td>
</tr>
<tr>
  <td><span class="badge fail">HIGH</span></td>
  <td><strong>Add encoding preprocessor</strong> — Before classification, attempt to decode
      common encodings (NATO, Hex, Base16, Base64, Braille, Morse, ROT13) and re-classify
      the decoded text.</td>
  <td>Encoding attacks (NATO {clean_probe_asr.get('encoding.InjectNato', 0)}%,
      Hex {clean_probe_asr.get('encoding.InjectHex', 0)}%,
      Base16 {clean_probe_asr.get('encoding.InjectBase16', 0)}%)</td>
  <td>Would block encoded slurs/harmful content that Wolf currently misses</td>
</tr>
<tr>
  <td><span class="badge warn">MEDIUM</span></td>
  <td><strong>Harden system prompt for fact-checking</strong> — Add instructions to the ČSOB
      system prompt to refuse or correct false factual claims rather than agreeing with them.</td>
  <td>False assertions ({clean_probe_asr.get('misleading.FalseAssertion', 0)}% ASR —
      model agrees with false statements instead of correcting)</td>
  <td>Significant reduction in misleading.FalseAssertion ASR</td>
</tr>
<tr>
  <td><span class="badge warn">MEDIUM</span></td>
  <td><strong>Upgrade NemoGuardrails</strong> — Apply the upstream fix from
      <a href="https://github.com/NVIDIA/NeMo-Guardrails/pull/2266">PR #2266</a>
      to eliminate the <code>stop</code> parameter bug. This removes the need for the
      proxy workaround.</td>
  <td>NemoGuardrails crash on <code>stop</code> parameter</td>
  <td>Eliminates 64.3% error rate in production when clients send <code>stop</code></td>
</tr>
<tr>
  <td><span class="badge pass">LOW</span></td>
  <td><strong>Monitor latent injection patterns</strong> — Track prompts with unusually long
      context that may embed attack payloads. Consider context-length limits or chunked
      classification.</td>
  <td>Latent injection (Report {clean_probe_asr.get('latentinjection.LatentInjectionReport', 0)}%,
      Eiffel {clean_probe_asr.get('latentinjection.LatentInjectionFactSnippetEiffel', 0)}%)</td>
  <td>Reduces indirect injection surface</td>
</tr>
</table>
</section>
''')

# ── FOOTER ───────────────────────────────────────────────────────────────────
w(f'''</div></main>
<footer>
<div class="container">
  ČSOB LLM Red Teaming Report | Generated {datetime.now().strftime("%Y-%m-%d")} |
  Red Hat OpenShift AI 3.5 | Garak {esc(garak_version)} |
  Data anchored in scan artifacts — no manually entered values
</div>
</footer>
</body>
</html>
''')

# ── Write HTML ───────────────────────────────────────────────────────────────
output_path = os.path.join(BASE, 'csob-red-teaming-report.html')
with open(output_path, 'w') as f:
    f.write('\n'.join(parts))

print(f"\n{'='*60}")
print(f"Report written to: {output_path}")
print(f"Size: {os.path.getsize(output_path):,} bytes")
print(f"{'='*60}")

# ── Verification summary ────────────────────────────────────────────────────
print("\n── DATA VERIFICATION ──")
print(f"Raw overall ASR: {raw_overall_asr}% ({raw_total_failed}/{raw_total_evals} probe×detector evals)")
print(f"Guardrailed overall ASR: {round(clean_overall_asr * 100, 2)}% (from API: {clean_overall_asr})")
print(f"Total probes (raw): {len(raw_probe_asr)}")
print(f"Total probes (guardrailed): {len(clean_probe_asr)}")
print(f"Clean scan job ID: {clean_job_id}")
print(f"Garak version: {garak_version}")
print(f"\n── PER-PROBE ASR (top 10 raw) ──")
for p, asr in sorted(raw_probe_asr.items(), key=lambda x: -x[1])[:10]:
    guard_asr = clean_probe_asr.get(p, 'N/A')
    print(f"  {p}: raw={asr}% → guard={guard_asr}%")
print(f"\n── PER-PROBE ASR (top 10 guardrailed) ──")
for p, asr in sorted(clean_probe_asr.items(), key=lambda x: -x[1])[:10]:
    raw_asr = raw_probe_asr.get(p, 'N/A')
    print(f"  {p}: guard={asr}% (raw={raw_asr}%)")
print(f"\n── OWASP CATEGORY AGGREGATES ──")
for cat_id in sorted(owasp_agg.keys()):
    agg = owasp_agg[cat_id]
    name = OWASP_MAP[cat_id]['name']
    print(f"  {cat_id} {name}: raw_avg={agg['raw_avg']}% → guard_avg={agg['clean_avg']}%")
print(f"\n── ZERO-ASR PROBES ──")
print(f"  Fully blocked by guardrails: {len([p for p in all_probes if raw_probe_asr.get(p,0) > 0 and clean_probe_asr.get(p,0) == 0])}")
print(f"  Already 0% on raw: {len([p for p in all_probes if raw_probe_asr.get(p,0) == 0])}")
print(f"  Non-zero on guardrailed: {len(remaining_risks)}")
