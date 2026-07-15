# RHOAI Playground (Gen AI Studio)

Deploys a model serving environment with LlamaStack-powered Playground, accessible through the RHOAI Gen AI Studio UI.

## What's deployed

| File | Purpose |
|---|---|
| `namespace.yaml` | `rhoai-playground` namespace |
| `qwen3-8b-inferenceservice.yaml` | LLMInferenceService — deploys Qwen3-8B via vLLM with MaaS gateway routing |
| `llama-stack-config.yaml` | LlamaStack config — connects to vLLM over HTTPS (vLLM serves TLS) |
| `llama-stack-distribution.yaml` | LlamaStackDistribution CR — deploys the LlamaStack server pod |
| `minio.yaml` | MinIO for LlamaStack artifact storage |
| `namespace-my-first-model.yaml` | Cleanup: removes the `my-first-model` namespace (leftover from initial setup) |

## How it works

```
Browser (Playground UI)
  |
  v
gen-ai-ui (rhods-dashboard sidecar)
  |
  v
LlamaStack (lsd-genai-playground pod, port 8321)
  |
  v
vLLM (qwen3-8b-kserve pod, port 8000, HTTPS)
```

The Playground routes through LlamaStack, which proxies to vLLM. The model name in the Playground dropdown is `vllm-inference-1/qwen3-8b` (LlamaStack provider prefix).

## Key configuration details

### LLMInferenceService labels

- `opendatahub.io/dashboard: "true"` — shows model in the RHOAI dashboard
- `opendatahub.io/genai-asset: "true"` — makes model visible in AI asset endpoints and Playground (equivalent to "Publish as AI asset endpoint" checkbox in UI)

### LLMInferenceService router config

```yaml
spec:
  router:
    gateway:
      refs:
        - name: maas-default-gateway
          namespace: openshift-ingress
    route: {}   # auto-generates /<namespace>/<model>/v1/... path prefix routing
```

`route: {}` (empty) generates proper path-prefix HTTPRoutes with URLRewrite filters. Do NOT use `useDefaultGateways: "All"` — it generates `PathPrefix: /` which causes recursive routing with maas-api.

### LlamaStack vLLM endpoint

vLLM serves over HTTPS (uses `--ssl-certfile` / `--ssl-keyfile`). The LlamaStack config must use `https://`:

```yaml
base_url: https://qwen3-8b-kserve-workload-svc.rhoai-playground.svc.cluster.local:8000/v1
```

TLS verification is disabled via env var `VLLM_TLS_VERIFY=false` on the LlamaStack deployment, referenced in config as `tls_verify: ${env.VLLM_TLS_VERIFY:=true}`.

### Adding a new model to the Playground

1. Deploy the model as an LLMInferenceService (see rhoai-maas README)
2. Update `llama-stack-config.yaml`:
   - Add a new provider under `providers.inference[]` with the vLLM HTTPS endpoint
   - Add a model entry under `registered_resources.models[]`
3. Restart the LlamaStack pod: `oc rollout restart deployment/lsd-genai-playground -n rhoai-playground`

## API access

Direct API access bypasses LlamaStack and goes through the MaaS gateway:

```bash
# Via the passthrough Route (stable DNS)
curl -sk -X POST "https://maas.apps.<cluster_domain>/rhoai-playground/qwen3-8b/v1/chat/completions" \
  -H "Authorization: Bearer <api-key>" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-8b", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 200, "chat_template_kwargs": {"enable_thinking": false}}'
```

API keys are created in **Gen AI studio > API keys**.
