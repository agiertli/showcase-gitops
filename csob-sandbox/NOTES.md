# CSOB Sandbox — NeMo Guardrails Reference Implementation

PVC-based model serving + NeMo Guardrails with ML-based prompt injection detection on RHOAI 3.5.1.

## Architecture

```
User → OCP Route → vLLM (gemma-4-12b)                         ← direct, no guardrails
User → OCP Route → NeMo Guardrails (+ classifier) → vLLM      ← with guardrails
```

- **LLM**: `RedHatAI/gemma-4-12B-it-FP8-Dynamic` (12B params, FP8, ~12.75 GiB VRAM)
- **GPU**: NVIDIA L4 (24GB)
- **Classifier**: `protectai/deberta-v3-base-prompt-injection-v2` (86M params, CPU-only, ~50ms inference)
- **Serving**: LLMInferenceService (`serving.kserve.io/v1alpha2`)
- **NeMo Guardrails**: Part of RHOAI (TrustyAI operator)

## Two Classifier Variants

Both variants use the same NeMo config, same guardrails rules, same classifier model. The difference is **where the classifier runs**:

### Variant A: Embedded Classifier (`guardrails/embedded-classifier/`)
- Classifier model loaded **in-process** inside the NeMo Guardrails pod
- Downloads from HuggingFace at startup (`engine: local`)
- Simpler — one pod does everything
- Requires HuggingFace access at pod startup time

### Variant B: External Classifier (`guardrails/external-classifier/`)
- Classifier served via **dedicated KServe InferenceService** using RHOAI's built-in HuggingFace Detector runtime
- Model loaded from PVC (`engine: fms`, calls `/api/v1/text/contents`)
- Air-gapped ready: HuggingFace → Nexus → PVC → KServe
- No internet required at runtime
- Model visible in RHOAI Dashboard (PVC has `opendatahub.io/dashboard: 'true'`)

## Folder Structure

```
csob-sandbox/
├── 00-namespace.yaml                       Namespace with dashboard labels
├── model-serving/                          LLM (Gemma 4 12B)
│   ├── 01-model-pvc.yaml                   30Gi PVC for model weights
│   ├── 02-download-job.yaml                Job: HuggingFace → PVC
│   ├── 03-llmis.yaml                       LLMInferenceService
│   ├── 04-route.yaml                       Manual Route (passthrough TLS)
│   └── 05-connection-type.yaml             PVC ConnectionType (Dashboard reference)
├── guardrails/
│   ├── common/                             Shared prerequisites
│   │   ├── 00-service-account.yaml         ServiceAccount
│   │   └── 01-role-binding.yaml            RoleBinding (view)
│   ├── embedded-classifier/                Variant A: in-process classifier
│   │   ├── 01-nemo-config.yaml             NeMo config (engine: local)
│   │   └── 02-nemo-guardrails.yaml         NemoGuardrails CR
│   └── external-classifier/                Variant B: KServe-served classifier
│       ├── 01-classifier-pvc.yaml          2Gi PVC for classifier model
│       ├── 02-download-job.yaml            Job: HuggingFace → PVC
│       ├── 03-classifier-inferenceservice.yaml  KServe InferenceService (HF Detector runtime)
│       ├── 04-nemo-config.yaml             NeMo config (engine: fms)
│       └── 05-nemo-guardrails.yaml         NemoGuardrails CR
├── tests/
│   ├── test-guardrails-report.sh           Test script (generates both reports)
│   ├── test-report-embedded.html           14/14 passed
│   └── test-report-external.html           14/14 passed
├── NOTES.md
└── run.sh                                  Ad-hoc prompt tester
```

## Deployment

```bash
# Prerequisites: RHOAI 3.5 installed, TrustyAI Managed in DSC, GPU node available

# 1. Namespace
oc apply -f 00-namespace.yaml --server-side

# 2. Model serving
oc apply -f model-serving/ --server-side --force-conflicts
oc wait --for=condition=complete job/download-gemma-4-12b -n csob-sandbox --timeout=600s

# 3. Guardrails common
oc apply -f guardrails/common/ --server-side

# 4a. Embedded classifier (pick one)
oc apply -f guardrails/embedded-classifier/ --server-side --force-conflicts

# 4b. External classifier (pick one or both)
oc apply -f guardrails/external-classifier/ --server-side --force-conflicts

# 5. Run tests
./tests/test-guardrails-report.sh both
```

## Guardrails — Three Defense Layers

| Layer | Type | What it catches | Latency |
|-------|------|-----------------|---------|
| ML Classifier | `hf_classifier` (ProtectAI DeBERTa) | Prompt injection, jailbreak attempts (including paraphrased) | ~50ms |
| Presidio PII | `sensitive_data_detection` | Credit cards, IBAN codes | ~10ms |
| Regex | `regex_detection` | Competitor names, system prompt extraction, security keywords, Czech national ID | ~0ms |

The classifier is the critical layer — regex can be bypassed with paraphrasing ("Forget everything you were told before"), but the ML model catches these with 99.99% confidence.

## Endpoints (auth disabled)

| Endpoint | Description |
|----------|-------------|
| `https://gemma-4-12b-csob-sandbox.apps.<domain>/v1/chat/completions` | Direct vLLM |
| `https://csob-guard-embedded-classifier-csob-sandbox.apps.<domain>/v1/chat/completions` | Embedded classifier |
| `https://csob-guard-external-classifier-csob-sandbox.apps.<domain>/v1/chat/completions` | External classifier |

## Key Findings

### NeMo does NOT support Czech language
The dialog engine uses the LLM for intent classification — English only. Czech prompts return "I don't know the answer to that." The input/output rails (regex, Presidio, classifier) work in any language. For Czech chatbot use cases, disable `dialog_engine` and use rails-only mode.

### HF Detector runtime — FMS API
RHOAI's built-in `guardrails-detector-huggingface-runtime` serves HuggingFace `AutoModelForSequenceClassification` models via the FMS Guardrails Detectors API: `POST /api/v1/text/contents`. NeMo connects to it via `engine: fms` in the `hf_classifier` config.

### NeMo config field names (RHOAI-bundled version)
The RHOAI-bundled NeMo uses `engine` (not `backend`), `model` (not `model_name`), `base_url` (not `endpoint`). The upstream Lemonade example uses different field names — it runs a different NeMo version.

### Volume name length limit
NemoGuardrails operator constructs volume names as `{nemoConfig.name}-{configMap.name}-volume`. Must be ≤63 chars total.

### LLMInferenceService does NOT create Routes
Requires AI Gateway (RHCL/Kuadrant). Without it, create a manual Route with `tls.termination: passthrough`.

### PVC ConnectionType — not in Deploy wizard
Dashboard "Deploy a model" only recognizes S3, OCI, and URI. PVC deployment is CLI/YAML only.

### enable-auth annotation
`security.opendatahub.io/enable-auth: "true"` adds OAuth proxy sidecar (port 8443, requires Bearer token). Set to `"false"` for simpler access (port 80, no auth, edge TLS).

## Bank Deployment Pattern (Air-Gapped)

For environments without internet access:
1. Download classifier model from HuggingFace to internal Nexus repository
2. Set `HF_ENDPOINT` env var in download Job to point to Nexus
3. Job downloads to PVC, KServe InferenceService serves from PVC
4. No internet access needed at runtime

## Red Teaming — Garak Risk Assessment (Tech Preview)

Automated safety testing via EvalHub + Garak `intents` benchmark. Runs the same attack suite against two endpoints to measure guardrails effectiveness.

### Architecture

```
                                    ┌─────────────────────────┐
                                    │   MaaS RHDP (external)  │
                                    │  qwen36-35b-a3b (judge) │
                                    │  gpt-oss-120b (SDG)     │
                                    └──────────┬──────────────┘
                                               │
EvalHub → DSPA (KFP pipeline) ─── Garak scan ──┤
                                               │
                          ┌────────────────────┤
                          ▼                    ▼
              Raw vLLM endpoint      GuardRails endpoint
              (gemma-4-12b)          (NeMo + classifier + gemma-4-12b)
```

### What it measures

- **Attack Success Rate (ASR)**: % of test prompts that bypassed safety controls. Lower = better.
- Per-strategy breakdown: baseline, SPO (System Prompt Override), SPO variants
- Per-intent breakdown: illegal activity, hate speech, malware, violence, fraud, etc.

### Expected outcome

| Endpoint | Expected ASR | Why |
|----------|-------------|-----|
| Raw vLLM | Higher | gemma-4-12b has built-in safety training but no external guardrails |
| GuardRails | Near-zero | ML classifier (Wolf Defender) catches prompt injection before LLM sees it |

### Deployment

```bash
# 1. Deploy MinIO (if not already running)
oc apply -f ../argo-apps/rhoai-config/minio-namespace.yaml --server-side
oc apply -f ../argo-apps/rhoai-config/minio.yaml --server-side

# 2. Create MinIO bucket
oc exec -n minio deploy/minio -- mc alias set local http://localhost:9000 minio minio123
oc exec -n minio deploy/minio -- mc mb local/garak-pipeline --ignore-existing

# 3. Apply red-teaming manifests
oc apply -f red-teaming/00-namespace-labels.yaml --server-side
oc apply -f red-teaming/01-maas-rhdp-api-key.yaml --server-side
oc apply -f red-teaming/02-gemma-api-key.yaml --server-side
oc apply -f red-teaming/03-minio-s3-secret.yaml --server-side
oc apply -f red-teaming/04-evalhub-postgres.yaml --server-side
oc apply -f red-teaming/05-evalhub-cr.yaml --server-side
# Wait for EvalHub pod to be Running
oc apply -f red-teaming/06-dspa.yaml --server-side
# Wait for DSPA to be Ready

# 4. Patch API key with real value from .env
source .env
oc patch secret maas-rhdp-api-key -n csob-sandbox --type merge \
  -p "{\"stringData\":{\"API_KEY\":\"$MAAS_RHDP_API_KEY\"}}"

# 5. Run scans
./red-teaming/run-scans.sh
```

### Folder Structure

```
red-teaming/
├── 00-namespace-labels.yaml          EvalHub tenant label
├── 01-maas-rhdp-api-key.yaml         API key for judge/SDG models (REPLACE_ME)
├── 02-gemma-api-key.yaml             API key for target model (DUMMY — auth disabled)
├── 03-minio-s3-secret.yaml           S3 credentials for pipeline artifacts
├── 04-evalhub-postgres.yaml          PostgreSQL for EvalHub
├── 05-evalhub-cr.yaml                EvalHub custom resource
├── 06-dspa.yaml                      Data Science Pipelines Application
├── intents-scan-raw.json             Scan config — raw vLLM endpoint
├── intents-scan-guardrailed.json     Scan config — guardrailed endpoint
└── run-scans.sh                      Submit both scans to EvalHub
```

### Configuration notes

- **Judge model**: `qwen36-35b-a3b` via MaaS RHDP (no rate limits, direct vLLM)
- **SDG model**: `gpt-oss-120b` via MaaS RHDP (LiteLLM proxy to Vertex AI, may rate-limit)
- **Strategies**: Baseline + SPO only (translation and TAP disabled — no attacker model, no Helsinki-NLP downloads)
- **Samples**: 10 per intent (`sdg_num_samples: 10`) — increase for production runs
- **Experiment**: both runs grouped under `guardrails-comparison` for side-by-side results

## GPU Requirements

| Model | VRAM | Min GPU | AWS Instance |
|-------|------|---------|-------------|
| gemma-4-12B-it-FP8-Dynamic | ~12.75 GiB | L4 (24GB) | g6.8xlarge |
| Classifier (DeBERTa 86M) | CPU only | — | — |
