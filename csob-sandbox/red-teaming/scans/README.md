# EvalHub Scan Overlays

Kustomize overlays for submitting red-teaming scans to EvalHub. Each overlay is a self-contained scan configuration — one `payload.json` with the EvalHub API request body, one Job that curls it.

## Prerequisites

- EvalHub infrastructure deployed (see `charts/evalhub-infra/`)
- Target model serving (gemma-pool or csob-guard-external-classifier)
- `oc` logged in to the cluster

## Available scans

| Overlay | Benchmark | Provider | Model | Duration |
|---------|-----------|----------|-------|----------|
| `owasp-raw` | OWASP LLM Top 10 | garak | Raw (gemma-pool) | ~2-4 hours |
| `owasp-guardrailed` | OWASP LLM Top 10 | garak | Guardrailed (Wolf Defender) | ~2-4 hours |
| `intents-raw` | Intents (SPO+TAP) | garak-kfp | Raw (gemma-pool) | ~4-6 hours |
| `intents-guardrailed` | Intents (SPO+TAP) | garak-kfp | Guardrailed (Wolf Defender) | ~4-6 hours |
| `intents-external-judge` | Intents (SPO only) | garak-kfp | Raw + qwen judge (RHDP MaaS) | ~30 min |

## Run a single scan

```bash
# Delete old job if exists, then apply
oc delete job owasp-raw-scan -n csob-sandbox --ignore-not-found
oc apply -k scans/owasp-raw/
```

## Run all 5 scans

```bash
chmod +x scans/run-all.sh
./scans/run-all.sh
```

## Examples

### OWASP Top 10 — raw model (no guardrails)

```bash
oc delete job owasp-raw-scan -n csob-sandbox --ignore-not-found
oc apply -k scans/owasp-raw/

# Check job status
oc logs job/owasp-raw-scan -n csob-sandbox

# Monitor in EvalHub UI → Evaluations tab
```

### OWASP Top 10 — guardrailed (Wolf Defender / NemoGuardrails)

```bash
oc delete job owasp-guardrailed-scan -n csob-sandbox --ignore-not-found
oc apply -k scans/owasp-guardrailed/

oc logs job/owasp-guardrailed-scan -n csob-sandbox
```

### Intents — raw model (built-in safety only)

```bash
oc delete job intents-raw-scan -n csob-sandbox --ignore-not-found
oc apply -k scans/intents-raw/

oc logs job/intents-raw-scan -n csob-sandbox
```

### Intents — guardrailed (Wolf Defender)

```bash
oc delete job intents-guardrailed-scan -n csob-sandbox --ignore-not-found
oc apply -k scans/intents-guardrailed/

oc logs job/intents-guardrailed-scan -n csob-sandbox
```

### Intents — external judge model (qwen via RHDP MaaS)

Minimal iterations (1 sample, 1 probe, 1 parallel attempt) to avoid RHDP rate limiting.
Demonstrates external judge model capability without running a full scan.

```bash
oc delete job intents-extjudge-scan -n csob-sandbox --ignore-not-found
oc apply -k scans/intents-external-judge/

# Job name uses shorter prefix: intents-extjudge-scan
oc logs job/intents-extjudge-scan -n csob-sandbox
```

## Customizing a scan

Each overlay's `payload.json` is the raw EvalHub API payload. Edit it directly:

- **Change target model**: modify `model.url` and `model.name`
- **Change experiment**: modify `experiment.name` (MUST be set for MLflow integration)
- **Change probes**: modify `garak_config.plugins.probe_spec` (comma-separated list)
- **Change parallelism**: modify `garak_config.system.parallel_attempts`
- **Change SDG samples**: modify `sdg_num_samples` (intents only)

## Architecture

```
scans/
├── base/                      # Shared Job template
│   ├── kustomization.yaml
│   └── job.yaml               # Curls EvalHub API with mounted payload
├── owasp-raw/                 # Overlay per scan type
│   ├── kustomization.yaml     # namePrefix + configMapGenerator
│   └── payload.json           # EvalHub API request body
├── owasp-guardrailed/
├── intents-raw/
├── intents-guardrailed/
├── intents-external-judge/
├── run-all.sh                 # Submit all 5 scans
└── README.md
```

Each overlay uses `namePrefix` to create uniquely named Jobs and ConfigMaps.
The `configMapGenerator` creates a ConfigMap from `payload.json` with `disableNameSuffixHash: true`
so the Job's volume reference matches.

## Troubleshooting

**Job stays Pending**: check if the `ubi-minimal` image can be pulled:
```bash
oc get events -n csob-sandbox --field-selector reason=Failed
```

**HTTP 403 from EvalHub**: kube-rbac-proxy requires `create` on `mlflow.kubeflow.org/experiments`. Apply the RBAC fix from `charts/evalhub-infra/` (included in the scan-rbac template) or manually:
```bash
oc create role evalhub-mlflow-experiment-create -n csob-sandbox \
  --verb=create,get,list --resource=experiments --resource-group=mlflow.kubeflow.org
oc create rolebinding evalhub-mlflow-experiment-create-binding -n csob-sandbox \
  --role=evalhub-mlflow-experiment-create --group=system:serviceaccounts:csob-sandbox
```

**EvalHub returns 400**: verify `X-Tenant` header matches namespace and `X-User` is set.

**Intents scan stuck as "running"**: the DSPA NetworkPolicy bug — apply the fix from `charts/evalhub-infra/`:
```bash
helm upgrade evalhub-infra charts/evalhub-infra/ -n csob-sandbox
```

**Scan shows "Failed" in UI but pipeline completed**: known bug (see `engineering-findings.md`, Finding #3).
The Pipeline Runs view at `Pipelines → Runs` shows the actual pipeline status and ASR.
Raw results are in S3 under `garak-pipeline` bucket (accessible via S4 UI on port 5000 or `aws s3 ls`).
For HTML reports, download from S3: `aws --endpoint-url http://s4-service...:7480 s3 cp s3://garak-pipeline/evalhub-garak-<id>/report.html .`
