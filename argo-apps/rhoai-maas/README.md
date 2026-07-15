# Models-as-a-Service (MaaS) for RHOAI 3.4

MaaS provides subscription-based governance for LLM access: API key authentication, per-user token rate limits, and authorization policies. It sits in front of locally deployed models (LLMInferenceService) and optionally external providers (OpenAI, Anthropic, etc).

Getting MaaS to work via GitOps required **17 YAML files across 2 ArgoCD apps** plus RBAC changes. The official docs assume dashboard-driven deployment and omit critical programmatic details. This README documents every piece and the non-obvious gotchas.

## Architecture overview

```
User request
  |
  v
maas-default-gateway (Gateway API, openshift-ingress)
  |
  |-- /v1/models, /maas-api --> maas-api (auto-created by RHOAI)
  |-- /llm/<model>/v1/...   --> qwen3-8b-kserve-workload-svc:8000 (via HTTPRoute)
  |
  +-- Kuadrant enforces: AuthPolicy (Authorino) + TokenRateLimitPolicy
```

## Prerequisites (not managed by this app)

- RHOAI 3.4+ installed with KServe managed
- `rhoai-playground` namespace exists (managed by rhoai-playground app)
- ArgoCD RBAC includes `maas.opendatahub.io`, `gateway.networking.k8s.io`, `kuadrant.io`, `operator.authorino.kuadrant.io` API groups and relevant resource kinds (see `argo-apps/rbac/`)

## Files and sync-wave ordering

Sync waves control deployment order. Lower numbers deploy first.

### Layer 1: Infrastructure (waves -10 to -3)

| File | Wave | What it does |
|---|---|---|
| `rhcl-namespace.yaml` | -10 | Namespace for Red Hat Connectivity Link (Kuadrant) operator |
| `rhcl-operatorgroup.yaml` | -10 | OperatorGroup for RHCL (each operator gets its own namespace) |
| `kuadrant-namespace.yaml` | -10 | Namespace `kuadrant-system` for the Kuadrant runtime |
| `rhcl-subscription.yaml` | -9 | OLM Subscription to install RHCL operator (provides Kuadrant CRDs) |
| `kuadrant.yaml` | -7 | Kuadrant CR — activates the policy engine in `kuadrant-system` |
| `postgresql.yaml` | -5 | PostgreSQL deployment + PVC + Service for MaaS state storage, deployed into `redhat-ods-applications` |
| `user-workload-monitoring.yaml` | -4 | Enables user workload monitoring (required for token counting metrics) |
| `maas-db-config.yaml` | -3 | Secret with PostgreSQL connection URL for MaaS API |
| `dsc-maas-patch.yaml` | -1 | ServerSideApply patch on DataScienceCluster to enable `modelsAsService: Managed` |

### Layer 2: Networking & Auth (waves 0 to 3)

| File | Wave | What it does |
|---|---|---|
| `remove-kuadrant-wasm-from-dsg.yaml` | 1 | EnvoyFilter that removes leaked Kuadrant WASM filters from data-science-gateway (prevents dashboard 401) |
| `maas-gateway.yaml` | 0, 1 | Headless Service (triggers OpenShift TLS cert generation for `maas-gateway-tls` secret) + Gateway using `data-science-gateway-class` with HTTPS/443 listener |
| `tls-authorino-service.yaml` | 2 | ServerSideApply patch on `authorino-authorino-authorization` Service to add cert annotation — triggers OpenShift to generate `authorino-server-cert` |
| `tls-authorino-cr.yaml` | 2 | Authorino CR with TLS enabled, referencing the generated cert secret |
| `tls-authorino-deployment.yaml` | 3 | ServerSideApply patch on the Authorino Deployment to inject `SSL_CERT_FILE` and `REQUESTS_CA_BUNDLE` env vars pointing to OpenShift's service-ca bundle |

### Layer 3: Model publishing (wave 5)

| File | Wave | What it does |
|---|---|---|
| `maas-model-ref.yaml` | 5 | MaaSModelRef — registers `qwen3-8b` LLMInferenceService as a MaaS-visible model. Lives in the model's namespace (`rhoai-playground`) |

### Layer 4: Access control (wave 10)

| File | Wave | What it does |
|---|---|---|
| `maas-subscription.yaml` | 10 | MaaSSubscription — grants `argocdadmins` group and `admin` user access to qwen3-8b with token rate limits (1M/hr, 5M/day). Lives in `models-as-a-service` namespace |
| `maas-auth-policy.yaml` | 10 | MaaSAuthPolicy — authorizes the same groups/users to access the model through the gateway. Without this, requests get 403 even with a valid API key |

### Model deployment (separate app: rhoai-playground)

| File | Wave | What it does |
|---|---|---|
| `qwen3-8b-inferenceservice.yaml` | 2 | LLMInferenceService with router/gateway config that triggers HTTPRoute creation |

## Critical gotchas (undocumented or poorly documented)

### 1. LLMInferenceService requires explicit router config for MaaS

The biggest time sink. The `llmisvc-controller-manager` will NOT create an HTTPRoute unless the LLMInferenceService has **both**:

```yaml
spec:
  router:
    gateway:
      refs:
        - name: maas-default-gateway
          namespace: openshift-ingress
    route:
      http:
        spec:
          useDefaultGateways: "All"
```

Without `gateway.refs`, the controller logs `"No Gateway references found, skipping"`.
Without `route.http.spec.useDefaultGateways`, the controller logs `"No HTTPRoute configuration found, clearing HTTPRoutesReady condition"`.

The dashboard "Publish as MaaS" checkbox sets these fields automatically. The docs never mention them for CLI/GitOps deployment.

### 2. MaaSModelRef requires kind: LLMInferenceService, not InferenceService

```yaml
spec:
  modelRef:
    kind: LLMInferenceService  # NOT InferenceService
    name: qwen3-8b
```

The allowed values for `kind` are: `LLMInferenceService`, `ExternalModel`.

### 3. MaaSSubscription owner.groups only has 'name', not 'kind'

The CRD schema only supports `name` for group items:

```yaml
# WRONG - causes "unknown field" warning and OutOfSync
owner:
  groups:
    - kind: Group
      name: argocdadmins

# CORRECT
owner:
  groups:
    - name: argocdadmins
```

### 4. MaaS API group is maas.opendatahub.io, not models.opendatahub.io

Some older docs reference `models.opendatahub.io/v1alpha1` but the actual API group is `maas.opendatahub.io/v1alpha1`.

### 5. Authorino needs manual TLS bootstrapping

The Kuadrant-managed Authorino doesn't automatically get TLS certs on OpenShift. You need:
- A Service with `service.beta.openshift.io/serving-cert-secret-name` annotation to trigger cert generation
- An Authorino CR referencing that cert
- A Deployment patch to inject the CA bundle env vars

### 6. PostgreSQL is a manual prerequisite

MaaS needs a PostgreSQL database but RHOAI doesn't deploy one. You must provide your own and pass the connection URL via the `maas-db-config` Secret in `redhat-ods-applications`.

### 7. Gateway TLS cert generation trick

The `maas-gateway-tls` Secret referenced by the Gateway doesn't exist by default. A headless Service with `service.beta.openshift.io/serving-cert-secret-name: maas-gateway-tls` triggers OpenShift's service-ca to generate it.

### 8. ArgoCD RBAC additions required

ArgoCD needs permissions for several new API groups and resource types:

**ClusterRole (roles.yaml):**
- `maas.opendatahub.io` — maasmodelrefs, maassubscriptions, maasauthpolicies
- `serving.kserve.io` — llminferenceservices (in addition to existing inferenceservices)
- `kuadrant.io` — kuadrants
- `operator.authorino.kuadrant.io` — authorinos
- `gateway.networking.k8s.io` — gateways

**resourceInclusions (argocd-policy-patch.yaml):**
- LLMInferenceService, MaaSModelRef, MaaSSubscription, MaaSAuthPolicy, Kuadrant, Authorino, Gateway

### 9. ServerSideApply DSC patch MUST include all managed components

The DSC patch uses ServerSideApply which takes field ownership of `spec.components`. Any component NOT explicitly listed in the patch will revert to `Removed` — **including the RHOAI dashboard**. Always include every component that should stay Managed:

```yaml
spec:
  components:
    dashboard:
      managementState: Managed        # CRITICAL: omitting this kills the dashboard
    mlflowoperator:
      managementState: Managed
    kserve:
      managementState: Managed
      rawDeploymentServiceConfig: Headless
      modelsAsService:
        managementState: Managed
```

DataScienceCluster, Authorino Service, and Authorino Deployment are owned by operators. Use `argocd.argoproj.io/sync-options: ServerSideApply=true` to do partial patches instead of full replacements.

### 10. SkipDryRunOnMissingResource for CRDs installed by operators

Resources like Kuadrant, Authorino, MaaSModelRef, MaaSSubscription, Gateway, and LLMInferenceService depend on CRDs installed by operators in earlier sync waves. ArgoCD dry-run fails without `SkipDryRunOnMissingResource=true`.

### 11. Kuadrant WASM filters leak to data-science-gateway (BREAKS DASHBOARD)

Kuadrant creates EnvoyFilters with `targetRefs` pointing to `maas-default-gateway`, but Istio's `targetRefs` on EnvoyFilter doesn't properly scope them. Since all gateways (data-science-gateway, maas-default-gateway, openshift-ai-inference) run as separate pods in `openshift-ingress`, the WASM filters leak to ALL gateway pods.

The WASM filter has a catch-all route (`request.url_path.startsWith('/')`) that sends every request to Authorino for API key validation with `failureMode: deny`. Dashboard requests use OAuth Bearer tokens, not API keys, so Authorino rejects them → 401.

Fix: `remove-kuadrant-wasm-from-dsg.yaml` creates an EnvoyFilter with `workloadSelector` targeting `data-science-gateway` that explicitly REMOVEs the WASM filters. This is safe because the data-science-gateway uses OAuth (ext_authz + kube-auth-proxy), not Kuadrant API key auth.

## Dependency chain

```
RHCL Operator install (wave -10 to -9)
  |
  v
Kuadrant CR (wave -7) --> enables policy engine
  |
PostgreSQL + DB config (wave -5, -3)
  |
DSC patch: modelsAsService Managed (wave -1) --> RHOAI deploys maas-controller, maas-api, models-as-a-service namespace
  |
Gateway + TLS (wave 0-1) --> maas-default-gateway in openshift-ingress
  |
Authorino TLS bootstrap (wave 2-3)
  |
LLMInferenceService with router config (rhoai-playground, wave 2) --> llmisvc-controller creates HTTPRoute
  |
MaaSModelRef (wave 5) --> registers model, watches for HTTPRoute
  |
MaaSSubscription + MaaSAuthPolicy (wave 10) --> creates TokenRateLimitPolicy + AuthPolicy via Kuadrant
```

## Verification

```bash
# All resources healthy
oc get llminferenceservice -n rhoai-playground
oc get maasmodelref -n rhoai-playground -o jsonpath='{.items[0].status.phase}'
oc get maassubscription -n models-as-a-service -o jsonpath='{.items[0].status.phase}'
oc get maasauthpolicy -n models-as-a-service
oc get httproute -n rhoai-playground

# Test API access via the passthrough Route (preferred — stable DNS)
curl -sk -X POST "https://maas.apps.<cluster_domain>/rhoai-playground/qwen3-8b/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-<your-key>" \
  -H "Content-Type: application/json" \
  -d '{"model": "qwen3-8b", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 50, "chat_template_kwargs": {"enable_thinking": false}}'
```

## Operations

### Adding a new model

1. Create an `LLMInferenceService` in the target namespace with these required fields:

```yaml
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  labels:
    opendatahub.io/dashboard: "true"
    opendatahub.io/genai-asset: "true"     # makes it visible in AI asset endpoints + Playground
  name: <model-name>
  namespace: <namespace>
spec:
  model:
    uri: oci://registry.redhat.io/...      # modelcar OCI URI
  replicas: 1
  router:
    gateway:
      refs:
        - name: maas-default-gateway
          namespace: openshift-ingress
    route: {}                              # empty = auto-generated path prefix routing
  template:
    containers:
      - name: main
        args: [--dtype=float16, --max-model-len=16384, --gpu-memory-utilization=0.95]
        resources:
          limits:
            nvidia.com/gpu: "1"
```

2. Create a `MaaSModelRef` in the model's namespace:

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: <model-name>
  namespace: <namespace>
spec:
  modelRef:
    kind: LLMInferenceService
    name: <model-name>
```

3. Add the model to an existing MaaSSubscription's `modelRefs[]` or create a new subscription.

4. If using LlamaStack/Playground, update the LlamaStack `config.yaml` ConfigMap to add the new model as a provider. Use `https://` for the vLLM endpoint (vLLM serves TLS).

### Adding a new subscription

Create a `MaaSSubscription` in the `models-as-a-service` namespace:

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: <subscription-name>
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: <group-name>       # OpenShift group (NOT kind: Group)
    users:
      - <username>
  modelRefs:
    - name: <model-name>
      namespace: <model-namespace>
      tokenRateLimits:
        - limit: 1000000         # tokens
          window: "1h"
        - limit: 5000000
          window: "24h"
  priority: 10                   # higher = higher priority
```

You also need a matching `MaaSAuthPolicy`:

```yaml
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: <policy-name>
  namespace: models-as-a-service
spec:
  groups:
    - name: <group-name>
  users:
    - <username>
```

Without the auth policy, requests get 403 even with a valid API key.

Alternatively, use the dashboard: **Settings > Subscriptions > Create subscription**. Token limits appear per-model after clicking "Add models". Check "Create a matching authorization policy" to auto-create the auth policy.

### Adding users to an existing subscription

1. **Via GitOps**: Add the username to `spec.owner.users[]` in the MaaSSubscription and to `spec.users[]` in the matching MaaSAuthPolicy.
2. **Via UI**: Edit the subscription in **Settings > Subscriptions**, update the groups or users.
3. **Via groups**: Add the user to an OpenShift group that's already in the subscription's `owner.groups[]`. No subscription change needed.

Users create their own API keys via **Gen AI studio > API keys**.

### Monitoring token consumption

Observability is enabled via:
- `spec.observability.enable: true` on the Kuadrant CR (gitopsified in `kuadrant.yaml`)
- `spec.telemetry.enabled: true` on the Tenant CR (applied via `oc patch` — Tenant is excluded from ArgoCD)

To re-apply telemetry if the Tenant gets recreated:
```bash
oc patch tenants.maas.opendatahub.io default-tenant -n models-as-a-service \
  --type merge \
  -p '{"spec":{"telemetry":{"enabled":true,"metrics":{"captureOrganization":true,"captureUser":true,"captureGroup":false,"captureModelUsage":true}}}}'
```

Query consumption via Prometheus (OpenShift Console > Observe > Metrics):
```promql
# Total tokens consumed per model
authorized_hits

# Total API calls
authorized_calls

# Rate-limited requests (HTTP 429)
limited_calls
```

### ArgoCD-excluded resources

ArgoCD settings exclude certain resource types. These must be managed directly via `oc`:
- `Tenant` — telemetry config (see above)
- `batch/Job` — avoid using Jobs for workarounds

### Known UI quirks

- **"Models as a Service could not be loaded"** banner on AI asset endpoints: **product bug** in gen-ai-ui (RHOAI 3.4.2). The `resolveMaaSBaseURL()` autodiscovery function exists in the BFF code (`packages/gen-ai/bff/internal/api/maas_helpers.go`) and correctly constructs `https://maas.<cluster_domain>/maas-api`, but it's NOT wired to the MaaS client factory initialization — the factory reads `config.MaaSURL` directly (empty when `MAAS_URL` env var isn't set). Meanwhile, the `maas-ui` container in the same pod autodiscovers the URL successfully. Models still appear via the `genai-asset` label. The banner is cosmetic — functionality is unaffected.
- **External API endpoint shows AWS NLB URL**: the LLMInferenceService controller reads `Gateway.status.addresses[0].value` which is the NLB hostname on AWS. This is by design for Gateway API on AWS. The `maas.apps.<cluster_domain>` Route is a passthrough proxy to the same backend — both URLs work. Use the Route URL for stable DNS in scripts: `https://maas.apps.<cluster_domain>/rhoai-playground/<model>/v1/chat/completions`.
- **"No internal endpoints found" on Models > Deployments page**: the Models page reads endpoints differently from AI asset endpoints. The LLMInferenceService status has both `gateway-external` and `gateway-internal` addresses, but the Models page doesn't show the internal one. This is a dashboard display issue.
- **Qwen3 shows `<think>` tags in Playground**: Qwen3 models have a thinking mode. To suppress it in API calls, add `"chat_template_kwargs": {"enable_thinking": false}` to the request body.
- **Per-user consumption not visible in Prometheus**: the `authorized_hits`/`authorized_calls` metrics from Limitador only have per-route labels, not per-user. Rate limiting IS enforced per-user (`counters: auth.identity.userid`), but per-user dashboards require the Perses observability component which isn't auto-deployed in RHOAI 3.4.
