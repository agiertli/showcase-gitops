# Project Rules

## Repository Purpose

This repo provides composable, feature-by-feature GitOps manifests for layering RHOAI capabilities onto an **existing** RHOAI installation. It does NOT install the RHOAI operator itself. Solution architects pick the layers they need and apply them — via ArgoCD or manually with `oc apply`.

## Agent Deployment Guide

This repo assumes RHOAI is already installed on the cluster. When a user opens a conversation in this directory asking to deploy or configure RHOAI features, **start by presenting the feature menu below and ask which features to enable**. Do not assume — let the user pick.

### Feature Menu (present this to the user)
Ask the user which features they want enabled:

1. **Base Config** (recommended — always) — Model Registry, Model Catalog, GenAI Playground, KServe, MinIO model storage
2. **Model Serving** — Deploy models on GPU. Ask which models:
   - `muse-glimmer` — RedHatAI/Muse-Glimmer-30B-FP8 (multimodal, tool calling, reasoning)
   - `qwen3-8b` — Qwen3-8B
   - `qwen3-27b` — Qwen3-27B
   - `thinkingcap-27b` — ThinkingCap-27B
3. **MaaS** (Models-as-a-Service) — API gateway, auth, rate limiting, subscriptions (heavy — installs Kuadrant, OTel, Tempo, COO)
4. **MLflow** — Experiment tracking and model tracing
5. **Observability** — GPU metrics, MonitoringStack, dashboards

Also ask:
- Do they need **GPU nodes provisioned**? If yes: how many, what instance type (e.g., `g6e.8xlarge`)?
- What is the **cluster domain**? (needed for MaaS routing — e.g., `apps.ocp.example.com`)

### What lives where

| Layer | Directory | Key files | Depends on |
|-------|-----------|-----------|------------|
| Base Config | `argo-apps/rhoai-config/` | `dsc-base.yaml`, `dashboard-config.yaml`, `minio.yaml`, `minio-namespace.yaml` | RHOAI operator |
| Model Serving | `argo-apps/rhoai-playground/` | `muse-glimmer-*.yaml`, `qwen3-*.yaml`, `thinkingcap-*.yaml` | Base Config |
| MaaS | `argo-apps/rhoai-maas/` | Kustomize — apply with `oc apply -k`. Update `cluster-config.yaml` with cluster domain first | Base Config |
| MLflow | `argo-apps/rhoai-mlflow/` | `dsc-mlflow-patch.yaml`, `mlflow.yaml` | Base Config |
| Observability | `argo-apps/rhoai-observability/` | Monitoring stack, GPU metrics | Base Config + MaaS |

### Deployment notes
- **Base Config is always first** — it patches the DSC and dashboard. Other layers build on it
- **Model Serving**: each model needs a GPU node. Do NOT deploy all models — only what the user asks for. Each model has its own `*-inferenceservice.yaml`
- **MaaS cluster-specific values**: before applying `argo-apps/rhoai-maas/`, update `cluster-config.yaml`: set `MAAS_HOST` to `maas.apps.<cluster-domain>` and `MAAS_ENDPOINT_OVERRIDE` to `https://maas.apps.<cluster-domain>/muse-glimmer/muse-glimmer`
- **GPU nodes**: if provisioning, create a MachineSet with `nvidia.com/gpu=:NoSchedule` taint. Wait for nodes to be Ready and NVIDIA GPU Operator DaemonSet pods running before deploying models
- **MinIO** is in the `minio` namespace. Model storage configs reference `minio-service.minio.svc.cluster.local:9000`
- **Reference docs**: always check `docs/` folder first for RHOAI product documentation PDFs. docs.redhat.com is blocked

### Example Prompt
Users can start a Claude Code session in this directory with a prompt like:

> I'm logged into an OpenShift cluster as admin with RHOAI installed. Help me deploy RHOAI features from this repo.

The agent should then present the feature menu above and ask the user to select which features to enable, how many GPU nodes to provision, and what the cluster domain is.

## Operator Installation
- Every operator MUST be installed in its own dedicated namespace
- Never install multiple operators into a shared namespace (e.g., `openshift-operators`)
- For each operator, create: (1) a dedicated Namespace, (2) an OperatorGroup, (3) the Subscription — all in that namespace

## Documentation
- Always check the local `docs/` folder first for Red Hat product documentation PDFs
- docs.redhat.com is blocked — never attempt to WebFetch from it
- If a relevant doc is missing from `docs/`, ask the user to provide the PDF

## MaaS (Models-as-a-Service)
- **TLS**: The Gateway must use the `cert-manager-ingress-cert` secret (ZeroSSL wildcard), NOT the internal `maas-gateway-tls` (service-serving CA, untrusted externally)
- **Routing**: MaaS uses path-based routing — the base URL is `/muse-glimmer/muse-glimmer/v1`, NOT just `/v1`. Model name in request body is `muse-glimmer` (the LLMInferenceService name), NOT the HuggingFace ID
- **Direct route**: `muse-glimmer-direct` Route in `muse-glimmer` namespace bypasses MaaS for direct vLLM access (passthrough TLS, no API key needed)

## Model Serving — Muse-Glimmer
- **Model**: RedHatAI/Muse-Glimmer-30B-FP8-block, served via vLLM on KServe
- **Multimodal**: Supports vision (image+text). Accepts `image_url` content blocks in OpenAI chat format — both base64 and URL-based images work
- **Tool calling**: Supports `--enable-auto-tool-choice --tool-call-parser=muse_glimmer --reasoning-parser=muse_glimmer`
- **Reasoning model**: Output often splits between `content` (final answer) and `reasoning` (chain-of-thought). Use `max_tokens >= 512` to get both

## Observability Dashboard (Tech Preview)
- **OTel collector is operator-managed**: RHOAI operator reconciles any changes to the OTelCollector CR instantly — do NOT try to patch it. Workaround by creating parallel scrape paths
- **DCGM GPU metrics**: The OTel collector DROPS `DCGM_FI_DEV_GPU_UTIL`. Fix: create a `monitoring.rhobs/v1` PodMonitor that scrapes the DCGM exporter directly (port 9400, `nvidia-gpu-operator` namespace)
- **Namespace labeling**: OTel collector in `redhat-ods-monitoring` causes all re-exported metrics to get `namespace=redhat-ods-monitoring`. Fix: set `honorLabels: true` on the ServiceMonitor scraping the OTel Prometheus exporter — this preserves the original `namespace=muse-glimmer` label
- **Platform metrics**: MonitoringStack Prometheus has no kube/node metrics by default. Fix: create a ServiceMonitor with `/federate` path targeting `openshift-monitoring` Prometheus (needs `cluster-monitoring-view` ClusterRoleBinding)
- **MonitoringStack API group**: MonitoringStack uses `monitoring.rhobs/v1` for its ServiceMonitors/PodMonitors. KServe-created monitors use `monitoring.coreos.com/v1` (platform Prometheus only). Don't confuse them
- **Recording rules on counters**: Never use `label_replace` with the same metric name on counters — it creates new series with no history, zeroing `increase()` calculations. This is unfixable
- **MaaS Usage/Observability tab (Tech Preview)**: Requires three things: (1) Kuadrant CR `spec.observability.enable: true`, (2) Tenant CR `spec.telemetry.enabled: true` with metric capture settings, (3) MaaSSubscription MUST have `tokenMetadata.costCenter` and `tokenMetadata.organizationId` set — without these, the WASM shim fails with `CelError::Resolve { NoSuchKey("costCenter") }` and Limitador receives no usage data. Limitador emits `authorized_hits`, `authorized_calls`, `limited_calls` with subscription/model/user labels. Dashboard uses Perses + Thanos Querier. See doc section 1.14

## MLflow Tracing
- **Application-side only**: MLflow tracing requires client-side instrumentation (`mlflow.openai.autolog()` or `mlflow.langchain.autolog()`). No server-side config needed — MLflow server 3.10+ supports tracing OOTB
- **Async flush**: Always call `mlflow.flush_trace_async_logging(terminate=True)` before script exit, plus a short `time.sleep(3)` — otherwise traces stay "in progress"
- **Workspace**: Set `mlflow.set_workspace("muse-glimmer")` to route experiments to the correct namespace

## Sensitive Files (never commit)
- `.maas-api-key` — MaaS API key
- `test-maas.sh` — contains API key
- `test-mlflow-tracing-*.py` — may contain endpoints
- `test-muse-glimmer-vision.py` — contains API key
- `docs/` — RHOAI product documentation PDFs (committed to git for agentic coding reference)
