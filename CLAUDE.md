# Project Rules

## Repository Purpose

This repo provides composable, feature-by-feature GitOps manifests for layering RHOAI capabilities onto an **existing** RHOAI installation. It does NOT install the RHOAI operator itself. Solution architects pick the layers they need and apply them — via ArgoCD or manually with `oc apply`.

## Agent Deployment Guide

This repo assumes RHOAI is already installed on the cluster. When a user opens a conversation in this directory asking to deploy or configure RHOAI features, **start by presenting the feature menu below and ask which features to enable**. Do not assume — let the user pick.

### Feature Menu (present this to the user)
Ask the user which features they want enabled:

1. **Base Config** (recommended — always) — Model Registry, Model Catalog, GenAI Playground, KServe, MinIO model storage
2. **Model Serving** — Deploy models on GPU. Ask which models:
   - `muse-glimmer` — RedHatAI/Muse-Glimmer-30B-FP8 (multimodal, tool calling, reasoning) — **requires L40S (48GB) or A100; L4 (24GB) is too small**
   - `qwen3-8b` — Qwen3-8B — fits on L4 (24GB)
   - `qwen3-27b` — Qwen3-27B — requires L40S (48GB) or A100
   - `thinkingcap-27b` — ThinkingCap-27B — requires L40S (48GB) or A100
3. **Observability** — COO, OTel, Tempo operators; DSCI monitoring; GPU metrics, MonitoringStack, dashboards
4. **MaaS** (Models-as-a-Service) — API gateway, auth, rate limiting, subscriptions (installs Kuadrant/RHCL)
5. **MLflow** — Experiment tracking and model tracing

Also ask:
- Do they need **GPU nodes provisioned**? If yes: how many, what instance type?
  - **IMPORTANT**: Validate GPU type against selected models. `g6` instances (NVIDIA L4, 24GB VRAM) can only run `qwen3-8b`. Models 27B+ (muse-glimmer, qwen3-27b, thinkingcap-27b) need `g6e` (NVIDIA L40S, 48GB VRAM), `p4d`/`p5` (A100/H100), or equivalent. **Warn if the user selects a 27B+ model with g6 nodes** — it will OOM at model load.
- What is the **cluster domain**? (needed for MaaS routing — e.g., `apps.ocp.example.com`)

### What lives where

| Layer | Directory | Key files | Depends on |
|-------|-----------|-----------|------------|
| Base Config | `argo-apps/rhoai-config/` | `dsc-base.yaml`, `dashboard-config.yaml`, `dashboard-llmis-rbac.yaml`, `minio.yaml` | RHOAI operator |
| Model Serving | `argo-apps/rhoai-playground/` | `muse-glimmer-*.yaml`, `qwen3-*.yaml`, `thinkingcap-*.yaml` | Base Config |
| Observability | `argo-apps/rhoai-observability/` | Kustomize — `oc apply -k`. Installs COO/OTel/Tempo, enables DSCI monitoring, GPU metrics, dashboards | Base Config |
| MaaS | `argo-apps/rhoai-maas/` | Kustomize — `oc apply -k`. Update `cluster-config.yaml` with cluster domain first. Installs Kuadrant/RHCL | Base Config (Observability recommended for usage dashboard) |
| MLflow | `argo-apps/rhoai-mlflow/` | `dsc-mlflow-patch.yaml`, `mlflow.yaml` | Base Config |

### Deployment notes
- **Base Config is always first** — it patches the DSC and dashboard. Other layers build on it
- **MaaS recommends Observability** — the MaaS usage dashboard requires COO/OTel/Tempo from `rhoai-observability/`. If the user selects MaaS without Observability, warn them the usage dashboard won't work but core API gateway/auth/rate-limiting will. If they want the full experience, apply observability first, then MaaS
- **Model Serving**: each model needs a GPU node. Do NOT deploy all models — only what the user asks for. Each model has its own `*-inferenceservice.yaml`
- **MaaS cluster-specific values**: before applying `argo-apps/rhoai-maas/`, update `cluster-config.yaml`: set `MAAS_HOST` to `maas.apps.<cluster-domain>` and `MAAS_ENDPOINT_OVERRIDE` to `https://maas.apps.<cluster-domain>/<model-namespace>/<model-name>` (e.g. `/muse-glimmer/muse-glimmer` or `/rhoai-playground/qwen3-8b`)
- **MaaS model-specific resources**: `maas-subscription.yaml` and `maas-auth-policy.yaml` default to `muse-glimmer`. When deploying a different model, patch these post-apply: `oc patch maassubscription demo-subscription -n models-as-a-service --type merge -p '{"spec":{"modelRefs":[{"name":"MODEL","namespace":"NS",...}]}}'` and same for `maasauthpolicy demo-auth-policy`
- **GPU nodes**: if provisioning, create a MachineSet with `nvidia.com/gpu=:NoSchedule` taint. Wait for nodes to be Ready and NVIDIA GPU Operator DaemonSet pods running before deploying models
- **MinIO** is in the `minio` namespace. Model storage configs reference `minio-service.minio.svc.cluster.local:9000`
- **Reference docs**: always check `docs/` folder first for RHOAI product documentation PDFs. docs.redhat.com is blocked

### Helper script: `deploy.sh`
A bash script is available at the repo root for batch deployment. Usage: `./deploy.sh --base --model qwen3-8b --observability --maas apps.ocp.example.com`. It handles operator ordering, InstallPlan approval, CRD waiting, and workarounds. **However, Claude should be the orchestrator** — the script is a tool, not the entrypoint. Claude should present the feature menu, gather user inputs, then execute step-by-step, monitoring for errors and applying workarounds adaptively. The script cannot handle diagnostic loops (e.g. "Monitoring CR stuck in Error → diagnose root cause → apply fix → restart operator → verify").

### Example Prompt
Users can start a Claude Code session in this directory with a prompt like:

> I'm logged into an OpenShift cluster as admin with RHOAI installed. Help me deploy RHOAI features from this repo.

The agent should then present the feature menu above and ask the user to select which features to enable, how many GPU nodes to provision, and what the cluster domain is.

### Autonomous Deployment Procedure

After gathering user selections, follow this exact sequence. At each step, **verify success before proceeding**. If a step fails, diagnose and fix — do not blindly retry.

#### Phase 1: Base Config
```bash
oc apply -f argo-apps/rhoai-config/ --server-side --force-conflicts
```
Verify: `oc get dsc,dsci` shows resources.

#### Phase 2: Model Serving (if selected)
1. Create namespace: `oc apply -f argo-apps/rhoai-playground/namespace.yaml --server-side`
2. For muse-glimmer only: also apply `muse-glimmer-namespace.yaml`, `muse-glimmer-storage.yaml`, `muse-glimmer-serving-runtime.yaml`
3. Ensure a `nvidia-gpu` HardwareProfile exists in `redhat-ods-applications` (required for LLMInferenceService in 3.5)
4. Apply InferenceService: `oc apply -f argo-apps/rhoai-playground/<model>-inferenceservice.yaml --server-side --force-conflicts`
5. Verify: `oc get llminferenceservice -A` shows the model, `oc get pods -n <model-ns>` shows predictor pod starting
6. OGX Playground is deployed automatically by Phase 4 (MaaS) — do not create LlamaStack distribution manually

#### Phase 3: Observability (if selected) — ORDER MATTERS
This is the trickiest phase. Multiple RHOAI 3.4.3 + COO 1.5.1 bugs require workarounds.

**Step 3a: Install operators**
```bash
for op in coo otel tempo; do
  oc apply -f argo-apps/rhoai-observability/${op}-namespace.yaml --server-side
  oc apply -f argo-apps/rhoai-observability/${op}-operatorgroup.yaml --server-side
  oc apply -f argo-apps/rhoai-observability/${op}-subscription.yaml --server-side
done
```

**Step 3b: Auto-approve InstallPlans**
Loop until approved in each namespace: `cluster-observability-operator`, `openshift-opentelemetry-operator`, `openshift-tempo-operator`.
```bash
oc get installplan -n <ns> -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"\n"}{end}'
oc patch installplan <name> -n <ns> --type merge -p '{"spec":{"approved":true}}'
```

**Step 3c: Wait for operator CSVs**
Wait for all three CSVs to reach `Succeeded` phase.

**Step 3d: Apply DSCI monitoring + dashboard config**
```bash
oc apply -f argo-apps/rhoai-observability/dsci-monitoring-patch.yaml --server-side --force-conflicts
oc apply -f argo-apps/rhoai-observability/dashboard-config-patch.yaml --server-side --force-conflicts
oc apply -f argo-apps/rhoai-observability/user-workload-monitoring.yaml --server-side
```

**Step 3e: Bootstrap PersesDatasource fixes (CRITICAL)**
Wait for `persesdatasources.perses.dev` CRD, then:
```bash
oc apply --server-side --force-conflicts -f argo-apps/rhoai-observability/cluster-prometheus-datasource-fix.yaml
oc apply --server-side --force-conflicts -f argo-apps/rhoai-observability/tempo-datasource-fix.yaml
```
These fix RHOAI 3.4.3 + COO 1.5.1 bugs where the operator omits `caCert.namespace` from PersesDatasource resources.

**Step 3f: Restart RHOAI operator**
```bash
oc delete pod -n redhat-ods-operator -l name=rhods-operator --wait=false
```
Wait 30-60 seconds. Do NOT use `oc rollout restart` — it doesn't work for this operator.

**Step 3g: Fix prometheus-web-tls-ca Secret**
RHOAI creates a ConfigMap but COO Prometheus expects a Secret. Check and fix:
```bash
# Wait for ConfigMap to appear
oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring
# If Secret doesn't exist, create from ConfigMap
oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring -o jsonpath='{.data.service-ca\.crt}' | \
  oc create secret generic prometheus-web-tls-ca -n redhat-ods-monitoring --from-file=service-ca.crt=/dev/stdin
```

**Step 3h: Wait for MonitoringStack CRD, apply monitors**
```bash
# Wait for CRDs
oc get crd monitoringstacks.monitoring.rhobs
oc get crd servicemonitors.monitoring.rhobs
```
Then apply remaining resources:
```bash
oc apply -f argo-apps/rhoai-observability/perses-coo-networkpolicy.yaml --server-side
oc apply -f argo-apps/rhoai-observability/prometheus-thanos-networkpolicy.yaml --server-side
# monitoring.rhobs resources
for f in otel-collector-rbac.yaml otel-collector-servicemonitor.yaml otel-collector-cluster-servicemonitor.yaml \
         dcgm-exporter-cluster-podmonitor.yaml observability-monitors.yaml; do
  oc apply -f argo-apps/rhoai-observability/$f --server-side --force-conflicts
done
# GPU recording rule (monitoring.coreos.com/v1 — platform Prometheus)
oc apply -f argo-apps/rhoai-observability/accelerator-gpu-metrics.yaml --server-side
```

**Step 3i: Verify Monitoring CR is Ready**
```bash
oc get monitoring -n redhat-ods-monitoring -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}'
```
If `False`: check status message, likely tempo-datasource issue. Re-apply fixes from 3e, restart operator again. Loop until Ready or escalate to user.

When Ready, verify PrometheusRules were created: `oc get prometheusrules -n redhat-ods-monitoring` should show ~13 rules.

#### Phase 4: MaaS (if selected)
1. Update `argo-apps/rhoai-maas/cluster-config.yaml`: set `MAAS_HOST` to `maas.apps.<cluster-domain>` and `MAAS_ENDPOINT_OVERRIDE` to `https://maas.apps.<cluster-domain>` (base URL only, no model path)
2. Install RHCL operator (namespace, operatorgroup, subscription), approve InstallPlan
3. Wait for RHCL CSV, wait for `kuadrants.kuadrant.io` CRD
4. Apply kustomize: `oc kustomize argo-apps/rhoai-maas | oc apply --server-side --force-conflicts -f -`
5. Patch subscription and auth policy for the deployed model (see "MaaS model-specific resources" above)
6. Enable OdhDashboardConfig: `oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type merge -p '{"spec":{"dashboardConfig":{"modelAsService":true,"vLLMDeploymentOnMaaS":true}}}'`
7. Wait for OGX pods (`lsd-genai-playground`, `genai-pgvector`) to be Running in model namespace
8. Patch `llama-stack-config` ConfigMap: change publisher-style paths to namespace-based paths (see "OGX Playground Path Bug")
9. Create MaaS API key and set `VLLM_API_TOKEN_1` / `VLLM_API_TOKEN_2` env vars on OGXServer to the key value
10. Set Gateway listener hostname for maas-api: `oc patch gateway maas-default-gateway -n openshift-ingress --type json -p '[{"op":"add","path":"/spec/listeners/0/hostname","value":"maas.apps.<cluster-domain>"}]'`
11. Verify: `oc get maassubscription,maasauthpolicy -n models-as-a-service`, test Playground UI, verify API keys page loads

#### Phase 5: MLflow (if selected)
```bash
oc apply -f argo-apps/rhoai-mlflow/ --server-side --force-conflicts
```
Wait for `mlflow` pod (2/2 Running) in `redhat-ods-applications`. The `mlflow-ui` pod may log "no MLflow CR found" initially — it discovers the CR via polling (30s interval). First page load can take 60s+ while discovery completes. Subsequent loads are fast.

Verify: `oc get pods -n redhat-ods-applications | grep mlflow` shows `mlflow` (2/2 Running), `mlflow-ui` (1/1 Running), `mlflow-operator-controller-manager` (1/1 Running). Dashboard URL: `https://rh-ai.apps.<cluster-domain>/mlflow/`

### OGX Config (Playground)

OGX auto-generates the `llama-stack-config` ConfigMap and `lsd-genai-playground` deployment when `ogx: Managed` is set in the DSC. **Do not create these manually.** After OGX deploys, patch the ConfigMap to fix the publisher-path bug (see "OGX Playground Path Bug" above).

- **OGXServer distribution**: Use `rh` (not `remote-vllm` or `starter`). `rh-dev` is a deprecated alias for `rh` and triggers a warning
- **OCI registry auth**: OGX operator pulls image labels from `registry.redhat.io` to resolve the base config. If this fails (HTTP 401), provide a `baseConfig` ConfigMap directly pointing to a manually created `config.yaml`
- **vLLM HTTPS**: The vLLM service uses `appProtocol: https` on port 8000. The OGX config must use `https://` endpoint with `tls.verify: false` in the vLLM provider config

Model namespace mapping:
- `muse-glimmer` → namespace `muse-glimmer`
- All others (`qwen3-8b`, `qwen3-27b`, `thinkingcap-27b`) → namespace `rhoai-playground`

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
- **Routing**: MaaS uses path-based routing — the base URL is `/<namespace>/<model>/v1`, NOT just `/v1`. Model name in request body is `qwen3-8b` (the LLMInferenceService name), NOT the HuggingFace ID
- **Direct route**: `muse-glimmer-direct` Route in `muse-glimmer` namespace bypasses MaaS for direct vLLM access (passthrough TLS, no API key needed)

### MaaS — RHOAI 3.5 Breaking Changes
- **DSC path changed**: `kserve.modelsAsService` is deprecated and rejected. Must use `aigateway.modelsAsAService` (note extra "A") with `aigateway.managementState: Managed`
- **OGX replaces LlamaStack**: Set `llamastackoperator: Removed` BEFORE enabling `ogx: Managed`. OGX is required for MaaS dashboard UI (API keys, subscriptions, auth policies). Without OGX the model shows in "AI asset endpoints" but MaaS management sections are missing
- **HardwareProfile mandatory**: LLMInferenceService references a HardwareProfile via `opendatahub.io/hardware-profile-name` annotation. Deployment fails if the profile doesn't exist. Create a `nvidia-gpu` HardwareProfile in `redhat-ods-applications` if needed
- **Infrastructure namespace**: MaaS infra goes to `redhat-ai-gateway-infra` (auto-created), not `redhat-ods-applications`. The `maas-db-config` secret must be in `redhat-ai-gateway-infra`
- **`maasAuthPolicies` dashboard flag deprecated**: Setting it causes a validation error in 3.5. Only set `vLLMDeploymentOnMaaS: true` and `observabilityDashboard: true`
- **MaaSTenantConfig auto-created**: `default-tenant` in `models-as-a-service` is auto-provisioned. No manual Tenant CR needed

### MaaS — External API Endpoint Fix
The Gateway gets an AWS ELB hostname by default. The dashboard shows this ugly URL as the external endpoint. Fix with `endpointOverride` on MaaSModelRef — set to the Route's base URL (e.g. `https://maas.apps.ocp.example.com`). All MaaSModelRef manifests in this repo use kustomize replacement from `cluster-config.yaml` `MAAS_ENDPOINT_OVERRIDE`.

### MaaS — Gateway Listener Hostname (REQUIRED for API Keys page)
In OcpRoute mode, the Gateway `status.addresses` only contains the internal `.svc.cluster.local` hostname. The maas-api reads this to determine the external URL — without an external hostname, `/v1/tenants` fails with "Unable to determine external hostname from Gateway status" and the dashboard API keys page shows "maas-api is not available". **Fix**: set `hostname` on the MaaS Gateway listener:
```bash
oc patch gateway maas-default-gateway -n openshift-ingress --type json \
  -p '[{"op":"add","path":"/spec/listeners/0/hostname","value":"maas.apps.<cluster-domain>"}]'
```
This does NOT break Authorino auth (the previous belief was wrong — the 403 was caused by a stale API key, not the hostname). Do NOT change `GatewayConfig.spec.ingressMode` to `LoadBalancer` — it causes the data-science-gateway pod to restart and poisons DNS caches with negative NXDOMAIN entries for the dashboard URL.

### MaaS — API Key Lifecycle
API keys are stored in the `maas-db` PostgreSQL database (in `redhat-ods-applications`) as SHA256 hashes. The raw key is only returned once at creation time. If the saved key doesn't match the database hash, the key validation endpoint returns `{valid: false, reason: "key not found"}` and ALL requests get 403 from Authorino. Fix: create a new key via the MaaS gateway using an OpenShift token:
```bash
TOKEN=$(oc whoami -t)
curl -sk -X POST "https://maas.apps.<cluster-domain>/maas-api/v1/api-keys" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"admin-key","description":"Admin API key","subscription":"demo-subscription"}'
```
Then update `VLLM_API_TOKEN_1` on the OGXServer with the new key value.

### MaaS — OGX Playground Path Bug (RHOAI 3.5)
The OGX-deployed LlamaStack distribution (`lsd-genai-playground`) routes inference through the MaaS gateway. The auto-generated config uses **publisher-style paths** (`/publishers/<ns>/models/<model>/v1`). These paths **DO NOT work with MaaS subscription matching** — the gateway extracts the wrong model name and rejects with "no matching subscription found for user". Fix: patch the `llama-stack-config` ConfigMap to use **namespace-based paths** (`/<ns>/<model>/v1`). The ConfigMap has `ogx.io/watch: "true"` label so the operator auto-restarts the pod on changes. Also set `VLLM_API_TOKEN_1` and `VLLM_API_TOKEN_2` env vars on the OGXServer to a valid MaaS API key (defaults to `fake`)

## Model Serving — GPU Requirements
| Model | Parameters | Quantization | Min VRAM | AWS Instance | GPU |
|-------|-----------|-------------|----------|-------------|-----|
| Muse-Glimmer-30B | 30B | FP8 | 48GB | g6e.8xlarge | L40S |
| Qwen3-27B | 27B | — | 48GB | g6e.8xlarge | L40S |
| ThinkingCap-27B | 27B | — | 48GB | g6e.8xlarge | L40S |
| Qwen3-8B | 8B | — | 24GB | g6.8xlarge | L4 |

**g6 vs g6e**: g6 = NVIDIA L4 (24GB), g6e = NVIDIA L40S (48GB). The internal demo platform provisions g6 (L4) nodes — these can only run Qwen3-8B. For 27B+ models, request g6e nodes explicitly.

## Model Serving — Labels
- **`opendatahub.io/genai-asset: "true"`**: Required on every LLMInferenceService/InferenceService for the model to appear in the GenAI Playground. Without it, Playground shows "No available model deployments"
- **`opendatahub.io/dashboard: "true"`**: Required for the resource to be visible in the RHOAI dashboard

## Model Serving — Muse-Glimmer
- **Model**: RedHatAI/Muse-Glimmer-30B-FP8-block, served via vLLM on KServe
- **Multimodal**: Supports vision (image+text). Accepts `image_url` content blocks in OpenAI chat format — both base64 and URL-based images work
- **Tool calling**: Supports `--enable-auto-tool-choice --tool-call-parser=muse_glimmer --reasoning-parser=muse_glimmer`
- **Reasoning model**: Output often splits between `content` (final answer) and `reasoning` (chain-of-thought). Use `max_tokens >= 512` to get both

## Observability — Known Bugs (RHOAI 3.4.3 + COO 1.5.1)

These bugs are **deployment blockers**, not just dashboard tips. The repo includes workaround manifests for each.

- **PersesDatasource missing `caCert.namespace`**: RHOAI operator generates PersesDatasource for both `cluster-prometheus-datasource` and `tempo-datasource` without `spec.client.tls.caCert.namespace`. COO 1.5.1 requires this field. Without it, the **Monitoring CR stays in Error state** and the operator won't create ANY monitoring resources (PrometheusRules, dashboards, nothing). Fix: `cluster-prometheus-datasource-fix.yaml` and `tempo-datasource-fix.yaml` bootstrap these with SSA. After applying, restart operator pods
- **Perses x509 TLS error**: Perses operator doesn't mount the service-serving CA into Perses pods despite the PersesDatasource referencing it. Dashboard shows "x509: certificate signed by unknown authority". Fix: `insecureSkipVerify: true` on `cluster-prometheus-datasource-fix.yaml` — persists through operator SSA reconciliation
- **prometheus-web-tls-ca ConfigMap vs Secret**: RHOAI creates ConfigMap, COO Prometheus expects Secret. Prometheus pod stuck in `Init:0/1`. Fix: create Secret from ConfigMap data (deploy script handles this)
- **Operator reconciles datasource to platform Thanos Querier**: After Monitoring CR goes Ready, operator changes `cluster-prometheus-datasource` URL to `https://thanos-querier.openshift-monitoring.svc:9091`. This is BY DESIGN — recording rules and dashboards query platform Thanos, not MonitoringStack Prometheus
- **`accelerator_gpu_utilization` not available**: Dashboard queries this metric but only `DCGM_FI_DEV_GPU_UTIL` exists. OTel collector relabeling is broken (`__name__` not available in `relabel_configs`). Fix: `accelerator-gpu-metrics.yaml` — PrometheusRule recording rule in `nvidia-gpu-operator` namespace using `monitoring.coreos.com/v1` API group (platform Prometheus scope)
- **RHOAI operator restart**: Must `oc delete pod` — `oc rollout restart` does NOT work for this operator

## Observability Dashboard (Tech Preview)
- **OTel collector is operator-managed**: RHOAI operator reconciles any changes to the OTelCollector CR instantly — do NOT try to patch it. Workaround by creating parallel scrape paths
- **DCGM GPU metrics**: The OTel collector DROPS `DCGM_FI_DEV_GPU_UTIL`. Fix: create a `monitoring.rhobs/v1` PodMonitor that scrapes the DCGM exporter directly (port 9400, `nvidia-gpu-operator` namespace)
- **Namespace labeling / duplicate models**: OTel collector in `redhat-ods-monitoring` re-exports vLLM metrics with `namespace=redhat-ods-monitoring`, causing duplicate model entries in the dashboard. Root cause: the operator-managed `data-science-prometheus-monitor` ServiceMonitor scrapes port 8889 without `honorLabels: true`, AND the operator reconciles away any SSA patches adding it (even with custom field managers). Partial fix: the custom `otel-collector-prometheus-exporter` ServiceMonitor has `metricRelabelings` to drop `kserve_vllm:*` metrics, preventing our SM from creating a second copy. The operator-managed SM still produces one entry with `namespace=redhat-ods-monitoring` and `exported_namespace=rhoai-playground`. **This is a product limitation** — the model appears with "redhat-ods-monitoring" as project instead of the actual namespace. Full fix requires Red Hat to add `honorLabels: true` to the operator-managed ServiceMonitor
- **Platform metrics**: MonitoringStack Prometheus has no kube/node metrics by default. Fix: create a ServiceMonitor with `/federate` path targeting `openshift-monitoring` Prometheus (needs `cluster-monitoring-view` ClusterRoleBinding)
- **MonitoringStack API group**: MonitoringStack uses `monitoring.rhobs/v1` for its ServiceMonitors/PodMonitors. KServe-created monitors use `monitoring.coreos.com/v1` (platform Prometheus only). Don't confuse them
- **Recording rules on counters**: Never use `label_replace` with the same metric name on counters — it creates new series with no history, zeroing `increase()` calculations. This is unfixable
- **MaaS Usage/Observability tab (Tech Preview)**: Requires three things: (1) Kuadrant CR `spec.observability.enable: true`, (2) Tenant CR `spec.telemetry.enabled: true` with metric capture settings, (3) MaaSSubscription MUST have `tokenMetadata.costCenter` and `tokenMetadata.organizationId` set — without these, the WASM shim fails with `CelError::Resolve { NoSuchKey("costCenter") }` and Limitador receives no usage data. Limitador emits `authorized_hits`, `authorized_calls`, `limited_calls` with subscription/model/user labels. Dashboard uses Perses + Thanos Querier. See doc section 1.14

## GatewayConfig — Do NOT Change ingressMode
The `GatewayConfig` CR (`default-gateway`) controls how the data-science-gateway and MaaS gateway are exposed. On RHOAI 3.5 with `OcpRoute` mode, changing to `LoadBalancer` causes the data-science-gateway Envoy pod to restart AND the operator to temporarily remove/recreate the Route. This poisons DNS resolvers (Google DNS) with negative NXDOMAIN entries for `rh-ai.apps.<domain>` that can take minutes to clear. The user loses access to the entire RHOAI dashboard. **Never change `ingressMode`** — use the Gateway listener `hostname` field instead (see "MaaS — Gateway Listener Hostname" above).

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
