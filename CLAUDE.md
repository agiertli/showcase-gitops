# Project Rules

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
