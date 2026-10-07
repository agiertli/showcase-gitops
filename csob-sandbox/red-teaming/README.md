# Red Teaming — EvalHub / Garak

Red-teaming evaluation of LLM deployments using EvalHub with Garak on RHOAI 3.5.
Target model: Gemma 4 12B (vLLM on KServe), tested raw and with Wolf Defender guardrails.

## Quick Start

### 1. Deploy infrastructure

```bash
helm install evalhub-infra charts/evalhub-infra/ -n csob-sandbox --create-namespace
```

Deploys: S4 storage, PostgreSQL, DSPA pipelines, EvalHub CR, NetworkPolicy fix.
See [charts/evalhub-infra/README.md](charts/evalhub-infra/README.md) for configuration.

### 2. Submit scans

Each scan type has its own kustomize overlay:

```bash
# Single scan
oc apply -k scans/owasp-raw/

# All 5 scans at once
./scans/run-all.sh
```

See [scans/README.md](scans/README.md) for all scan types and customization.

### Available scan types

| Overlay | Benchmark | Provider | Model | Duration |
|---------|-----------|----------|-------|----------|
| `scans/owasp-raw` | OWASP LLM Top 10 | garak | Raw (gemma-pool) | ~2-4h |
| `scans/owasp-guardrailed` | OWASP LLM Top 10 | garak | Guardrailed (Wolf Defender) | ~2-4h |
| `scans/intents-raw` | Intents (SPO+TAP) | garak-kfp | Raw (gemma-pool) | ~4-6h |
| `scans/intents-guardrailed` | Intents (SPO+TAP) | garak-kfp | Guardrailed (Wolf Defender) | ~4-6h |
| `scans/intents-external-judge` | Intents (SPO only) | garak-kfp | Raw + qwen judge (RHDP MaaS) | ~30min |

## Directory structure

```
red-teaming/
├── charts/evalhub-infra/      # Helm chart — all EvalHub prerequisites
├── scans/                     # Kustomize overlays — one per scan type
│   ├── owasp-raw/
│   ├── owasp-guardrailed/
│   ├── intents-raw/
│   ├── intents-guardrailed/
│   ├── intents-external-judge/
│   └── run-all.sh
├── gemma-pool.yaml            # Target model InferenceService pool
├── wolf-gpu-runtime.yaml      # Wolf Defender ServingRuntime
├── granite-guardian-deployment.yaml  # Granite Guardian 8B deployment
├── 07-model-router-proxy.yaml # Model routing proxy (scale to 0 for raw scans)
├── engineering-findings.md    # Engineering bug report (6 findings)
├── engineering-findings.html  # Same report, styled HTML
├── csob-red-teaming-report.html  # ČSOB scan results report
├── peer_review/               # Peer review package for engineering
└── archive/                   # Superseded v1/v2 manifests and old scan artifacts
```

## Known issues

See [engineering-findings.md](engineering-findings.md) for details:

1. **DSPA NetworkPolicy blocks EvalHub** (CRITICAL) — fixed by Helm chart's NetworkPolicy
2. **MLflow runID propagation failure** (HIGH) — intents scans don't save to MLflow
3. **Job status poisoning** (HIGH) — Pipeline Runs shows "Complete" but Evaluations shows "Failed"
4. **UI navigation gap** (MEDIUM) — no cross-links between Evaluations, Runs, Artifacts views

## Results summary

| Scan | Raw ASR | Guardrailed ASR | Reduction |
|------|---------|-----------------|-----------|
| OWASP Top 10 | 24.67% | 4.88% (Wolf Defender) | 80.2% |
| Intents (SPO+TAP) | 0–2.63% | 0–2.63% | Minimal (model already safe) |
