# RHOAI + MaaS Manual Deployment Runbook

Manual step-by-step deployment of Red Hat OpenShift AI with Models-as-a-Service. No ArgoCD required. Based on battle-tested manifests from this repo.

Source manifests: `argo-apps/` (relative to this repo root)

Estimated time: 2-3 hours (depends on model download speed and GPU availability).

Strategy: deploy model serving first (quick value), MaaS governance last (most complex).

---

## Customization Points (fill in before starting)

| Variable | Example | Your Value |
|---|---|---|
| `CLUSTER_DOMAIN` | `apps.ocp.example.com` | __________ |
| `MODEL_NAME` | `qwen3-8b` | __________ |
| `MODEL_NAMESPACE` | `rhoai-playground` | __________ |
| `GPU_TYPE` | L4 (24GB) / L40S (48GB) | __________ |
| `ADMIN_USER` | `admin` | __________ |
| `ADMIN_GROUP` | `argocdadmins` | __________ |

GPU requirements per model:
- `qwen3-8b` — L4 (24GB) or better
- `qwen3-27b` — L40S (48GB) or A100
- `thinkingcap-27b` — L40S (48GB) or A100
- `muse-glimmer` — L40S (48GB) or A100

---

## Phase 0: Prerequisites Check

Before starting, verify the cluster meets minimum requirements.

### 0.1 — Cluster access

```bash
oc whoami
oc auth can-i create subscription -n openshift-operators
```

**Expected:** You are logged in as cluster-admin.

### 0.2 — Default StorageClass exists

```bash
oc get storageclass -o name
```

**Expected:** At least one StorageClass exists (e.g., `gp3-csi`, `thin-csi`). One should have `(default)` annotation.

### 0.3 — GPU nodes available

```bash
oc get nodes -l nvidia.com/gpu.present=true
```

**Expected:** At least one GPU node is Ready. If no GPU nodes exist, you need to provision them (MachineSet, bare-metal, etc.) before Phase 3.

### 0.4 — NVIDIA GPU Operator installed

```bash
oc get csv -n nvidia-gpu-operator | grep gpu
```

**Expected:** GPU operator CSV shows `Succeeded`. If not installed, install it from OperatorHub first.

### 0.5 — OperatorHub functional

```bash
oc get packagemanifest rhods-operator -n openshift-marketplace
oc get packagemanifest rhcl-operator -n openshift-marketplace
```

**Expected:** Both package manifests exist. If not, check CatalogSource health.

---

## Phase 1: Install RHOAI Operator

The RHOAI operator is not in this repo. Install it from OperatorHub.

### 1.1 — Create the Subscription

```bash
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: stable-3.4
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 1.2 — Wait for the operator to install

```bash
oc get csv -n redhat-ods-operator -w
```

**Expected:** CSV reaches `Succeeded` phase. This may take 2-5 minutes.

### 1.3 — Verify the operator is running

```bash
oc get pods -n redhat-ods-operator -l name=rhods-operator
```

**Expected:** Operator pod is Running. The DSC and DSCI do NOT get created automatically — you will create the DSC manually in Phase 2.1, which triggers DSCI creation.

---

## Phase 2: Apply Base Config

Source: `argo-apps/rhoai-config/`

### 2.1 — Create the DataScienceCluster

This creates the DSC (which also triggers DSCI creation) with Dashboard, KServe (vLLM + OpenVINO runtimes), Model Registry, Workbenches, and LlamaStack operator (required for GenAI Studio Playground) enabled.

The file `argo-apps/rhoai-config/dsc-base.yaml` does not include Workbenches by default. Apply with Workbenches added:

```bash
oc apply --server-side --force-conflicts -f - <<'EOF'
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    dashboard:
      managementState: Managed
    kserve:
      managementState: Managed
      rawDeploymentServiceConfig: Headless
    modelregistry:
      managementState: Managed
      registriesNamespace: rhoai-model-registries
    workbenches:
      managementState: Managed
    llamastackoperator:
      managementState: Managed
EOF
```

### 2.2 — Verify DSCI was created

```bash
oc get dscinitializations
```

**Expected:** A DSCInitialization resource exists (created automatically when the DSC was applied).

### 2.3 — Fix Model Registry controller OOM (if needed)

The Model Registry operator controller may get OOMKilled with its default memory limits. Check:

```bash
oc get pods -n redhat-ods-applications -l control-plane=modelregistry-operator-controller-manager
```

If the pod shows `OOMKilled` or `CrashLoopBackOff`, patch its memory limits:

```bash
oc patch deployment modelregistry-operator-controller-manager -n redhat-ods-applications --type=json -p '[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "512Mi"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/requests/memory", "value": "256Mi"}
]'
```

Verify it recovers:

```bash
oc get pods -n redhat-ods-applications -l control-plane=modelregistry-operator-controller-manager -w
```

**Expected:** Pod reaches Running 1/1.

**Note:** The RHOAI operator may revert this patch on next reconciliation. If it keeps OOMing, you can disable Model Registry for now — it's not in the critical path for model serving or MaaS:

```bash
oc apply --server-side --force-conflicts -f - <<'EOF'
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    modelregistry:
      managementState: Removed
EOF
```

### 2.4 — Verify DSC reconciliation

```bash
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'
```

**Expected:** `Ready` (may take 5-10 minutes as KServe/Istio/Serverless are deployed).

If stuck at `NotReady`, check conditions:

```bash
oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}'
```

**KServe dependency on LeaderWorkerSet:** KServe requires the LeaderWorkerSet CRD. If the DSC stays `NotReady` because of KServe, check if there's a pending LeaderWorkerSet InstallPlan:

```bash
oc get installplan -A | grep -i leader
```

If found, approve it. KServe won't report Ready until LeaderWorkerSet is installed, even if you're not using multi-node serving.

### 2.5 — Verify the data-science-gateway exists

KServe deploys this gateway — it's a prerequisite for MaaS later.

```bash
oc get gateway data-science-gateway -n openshift-ingress
```

**Expected:** Gateway exists. On bare-metal, the Gateway's LoadBalancer IP will show `Pending` — that's normal, OpenShift Routes handle external access instead. If the Gateway resource itself doesn't exist, wait for DSC to finish reconciling.

### 2.6 — Patch the OdhDashboardConfig (Model Catalog + GenAI Studio)

Enables Model Catalog (`disableModelCatalog: false`) and GenAI Studio (`genAiStudio: true`) in the dashboard.

```bash
oc apply --server-side --force-conflicts -f argo-apps/rhoai-config/dashboard-config.yaml
```

### 2.7 — Apply dashboard RBAC for LLMInferenceService

Grants the dashboard ServiceAccount permission to manage LLMInferenceService resources.

```bash
oc apply -f argo-apps/rhoai-config/dashboard-llmis-rbac.yaml
```

### 2.8 — Verify dashboard is accessible

```bash
oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}'
```

**Expected:** Open the URL in a browser. Dashboard should load with Model Catalog, GenAI Studio, and Workbenches visible.

---

## Phase 3: Deploy a Model

Source: `argo-apps/rhoai-playground/`

Deploy a model now to prove KServe + GPU work before tackling MaaS complexity.

### 3.1 — Create the model namespace

```bash
oc apply -f argo-apps/rhoai-playground/namespace.yaml
```

### 3.2 — Deploy the LLMInferenceService

Choose the model that matches your GPU. For L4 (24GB), use `qwen3-8b`:

```bash
oc apply -f argo-apps/rhoai-playground/qwen3-8b-inferenceservice.yaml
```

For L40S (48GB), you can use `qwen3-27b` or `thinkingcap-27b`:

```bash
oc apply -f argo-apps/rhoai-playground/qwen3-27b-inferenceservice.yaml
```

**Note:** The LLMInferenceService manifest includes `spec.router.gateway.refs` pointing to `maas-default-gateway` which doesn't exist yet (MaaS is installed in Phases 6-9). This is fine — the model deploys and serves via KServe regardless. The `llmisvc-controller-manager` will log a warning about the missing gateway and skip HTTPRoute creation. Once MaaS is installed and the gateway exists, the controller restart in Phase 10.1 will re-reconcile and create the HTTPRoute.

**Hardware Profile:** The manifest includes `opendatahub.io/hardware-profile-name: nvidia-gpu` annotation. If you created the HardwareProfile in Phase 5 first, the mutating webhook injects resources/nodeSelector/tolerations from the profile. If Phase 5 hasn't been done yet, the inline `resources` block in the manifest still works — the pod just won't get nodeSelector/tolerations from the profile. You can re-apply the InferenceService after creating the profile to pick up the injection.

**Visibility:** The label `networking.kserve.io/visibility: exposed` tells KServe to create an OpenShift Route for the model, making it accessible outside the cluster. Without this label, the model is only reachable via cluster-internal Services.

### 3.3 — Wait for the model to be Ready

This is the longest wait — the model image (OCI modelcar) must download and vLLM must load the weights into GPU memory.

```bash
oc get llminferenceservice -n rhoai-playground -w
```

**Expected:** Status progresses through `Pending` -> model download -> `Ready`. This can take 5-15 minutes depending on image pull speed.

Check pod status for detailed progress:

```bash
oc get pods -n rhoai-playground
oc logs -n rhoai-playground -l serving.kserve.io/inferenceservice=qwen3-8b -c main --tail=20 -f
```

Look for `INFO: Application startup complete` in the vLLM logs.

### 3.4 — Verify the model is working (direct, no MaaS)

Test the model directly via its internal Service before MaaS is in place:

```bash
oc get llminferenceservice -n rhoai-playground
```

**Expected:** Model shows `Ready` status. At this point the model is serving via KServe and visible in the RHOAI dashboard. The customer can see a working model.

---

## Phase 4 (Optional): Deploy GenAI Studio Playground (LlamaStack)

The Playground chat interface in GenAI Studio requires LlamaStack as a backend. Without it, the Playground UI has no model to talk to. Skip this phase if you only need API-level model access (via MaaS or direct KServe).

### 4.1 — Verify LlamaStack operator is ready

```bash
oc get csv -n redhat-ods-applications | grep llama
```

**Expected:** LlamaStack operator CSV shows `Succeeded`. If not present, verify `llamastackoperator: Managed` is in your DSC (Phase 2.1).

### 4.2 — Create the LlamaStack config

This ConfigMap tells LlamaStack where to find the vLLM model. Replace `MODEL_NAME` and `MODEL_NAMESPACE` with values from the customization table at the top.

The vLLM internal Service name follows the pattern: `<MODEL_NAME>-kserve-workload-svc.<MODEL_NAMESPACE>.svc.cluster.local:8000/v1`

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  labels:
    opendatahub.io/dashboard: "true"
  name: llama-stack-config
  namespace: MODEL_NAMESPACE
data:
  config.yaml: |
    version: "2"
    distro_name: rh
    apis:
    - responses
    - datasetio
    - files
    - inference
    - safety
    - scoring
    - tool_runtime
    - vector_io
    providers:
      inference:
      - provider_id: sentence-transformers
        provider_type: inline::sentence-transformers
        config: {}
      - provider_id: vllm-MODEL_NAME
        provider_type: remote::vllm
        config:
          api_token: ${env.VLLM_API_TOKEN_1:=fake}
          base_url: https://MODEL_NAME-kserve-workload-svc.MODEL_NAMESPACE.svc.cluster.local:8000/v1
          max_tokens: ${env.VLLM_MAX_TOKENS:=4096}
          tls_verify: ${env.VLLM_TLS_VERIFY:=true}
      vector_io:
      - provider_id: milvus
        provider_type: inline::milvus
        config:
          db_path: /opt/app-root/src/.llama/distributions/rh/milvus.db
          persistence:
            backend: kv_default
            namespace: vector_io::milvus
      responses:
      - provider_id: builtin
        provider_type: inline::builtin
        config:
          persistence:
            agent_state:
              backend: kv_default
              namespace: agents
            responses:
              backend: sql_default
              max_write_queue_size: 10000
              num_writers: 4
              table_name: responses
      eval: []
      files:
      - provider_id: meta-reference-files
        provider_type: inline::localfs
        config:
          metadata_store:
            backend: sql_default
            table_name: files_metadata
          storage_dir: /opt/app-root/src/.llama/distributions/rh/files
      datasetio:
      - provider_id: huggingface
        provider_type: remote::huggingface
        config:
          kvstore:
            backend: kv_default
            namespace: datasetio::huggingface
      scoring:
      - provider_id: basic
        provider_type: inline::basic
        config: {}
      - provider_id: llm-as-judge
        provider_type: inline::llm-as-judge
        config: {}
      tool_runtime:
      - provider_id: file-search
        provider_type: inline::file-search
        config: {}
      - provider_id: model-context-protocol
        provider_type: remote::model-context-protocol
        config: {}
      safety: []
    metadata_store:
      type: sqlite
      db_path: /opt/app-root/src/.llama/distributions/rh/inference_store.db
    storage:
      backends:
        kv_default:
          db_path: /opt/app-root/src/.llama/distributions/rh/kvstore.db
          type: kv_sqlite
        sql_default:
          db_path: /opt/app-root/src/.llama/distributions/rh/sql_store.db
          type: sql_sqlite
      stores:
        conversations:
          backend: sql_default
          table_name: openai_conversations
        inference:
          backend: sql_default
          table_name: inference_store
        metadata:
          backend: kv_default
          namespace: registry
    vector_stores:
      default_provider_id: milvus
      default_embedding_model:
        provider_id: sentence-transformers
        model_id: ibm-granite/granite-embedding-125m-english
    registered_resources:
      models:
      - provider_id: sentence-transformers
        model_id: sentence-transformers/ibm-granite/granite-embedding-125m-english
        provider_model_id: ibm-granite/granite-embedding-125m-english
        model_type: embedding
        metadata:
          embedding_dimension: 768
      - provider_id: vllm-MODEL_NAME
        model_id: MODEL_NAME
        model_type: llm
        metadata:
          display_name: MODEL_NAME
      shields: []
      vector_stores: []
      datasets: []
      scoring_fns: []
      benchmarks: []
    server:
      port: 8321
EOF
```

### 4.3 — Deploy the LlamaStackDistribution

Replace `MODEL_NAMESPACE` with the namespace from the customization table.

```bash
oc apply -f - <<'EOF'
apiVersion: llamastack.io/v1alpha1
kind: LlamaStackDistribution
metadata:
  labels:
    opendatahub.io/dashboard: "true"
  name: lsd-genai-playground
  namespace: MODEL_NAMESPACE
spec:
  network:
    allowedFrom:
      namespaces:
        - MODEL_NAMESPACE
    exposeRoute: false
  replicas: 1
  server:
    containerSpec:
      command:
        - /bin/sh
        - -c
        - llama stack run /etc/llama-stack/config.yaml
      env:
        - name: VLLM_TLS_VERIFY
          value: "false"
        - name: MILVUS_DB_PATH
          value: ~/.llama/milvus.db
        - name: FMS_ORCHESTRATOR_URL
          value: http://localhost
        - name: VLLM_MAX_TOKENS
          value: "2048"
        - name: VLLM_API_TOKEN_1
          value: fake
        - name: LLAMA_STACK_CONFIG_DIR
          value: /opt/app-root/src/.llama/distributions/rh/
      name: llama-stack
      port: 8321
      resources:
        limits:
          cpu: "2"
          memory: 12Gi
        requests:
          cpu: 250m
          memory: 500Mi
    distribution:
      name: rh-dev
    userConfig:
      configMapName: llama-stack-config
EOF
```

### 4.4 — Verify LlamaStack is running

```bash
oc get pods -n rhoai-playground -l app.kubernetes.io/name=lsd-genai-playground
```

**Expected:** LlamaStack pod reaches Running 1/1. Check logs for startup:

```bash
oc logs -n rhoai-playground -l app.kubernetes.io/name=lsd-genai-playground --tail=20
```

Look for successful connection to the vLLM endpoint.

### 4.5 — Test the Playground

Open the RHOAI dashboard -> GenAI Studio -> Playground. You should see the `qwen3-8b` model in the dropdown. Send a test message.

**Note:** If Qwen3 returns `<think>` tags in the Playground, this is the model's thinking mode. It cannot be suppressed from the Playground UI — only via the API with `"chat_template_kwargs": {"enable_thinking": false}`.

---

## Phase 5: Hardware Profiles

Hardware Profiles define GPU resource defaults, node selectors, and tolerations. When referenced from a LLMInferenceService via annotation, a mutating webhook (`hardwareprofile-llmisvc-injector`) automatically injects the resources, nodeSelector, and tolerations into the pod template — so you don't need to hardcode them in every InferenceService YAML.

### 5.1 — Create a HardwareProfile

Adjust nodeSelector labels and tolerations to match your GPU nodes. Run `oc get nodes --show-labels | grep gpu` to find the right label.

The HardwareProfile lives in `redhat-ods-applications` (alongside the default profiles). The LLMInferenceService references it via two annotations: `opendatahub.io/hardware-profile-name` and `opendatahub.io/hardware-profile-namespace`. Without the namespace annotation, the webhook looks in the model's namespace and fails.

```bash
oc apply -f - <<'EOF'
apiVersion: infrastructure.opendatahub.io/v1
kind: HardwareProfile
metadata:
  annotations:
    opendatahub.io/dashboard-feature-visibility: '[]'
    opendatahub.io/disabled: "false"
    opendatahub.io/display-name: "NVIDIA GPU"
  name: nvidia-gpu
  namespace: redhat-ods-applications
spec:
  identifiers:
  - defaultCount: "4"
    displayName: CPU
    identifier: cpu
    maxCount: "8"
    minCount: 1
    resourceType: CPU
  - defaultCount: 16Gi
    displayName: Memory
    identifier: memory
    maxCount: 32Gi
    minCount: 8Gi
    resourceType: Memory
  - defaultCount: 1
    displayName: GPU
    identifier: nvidia.com/gpu
    maxCount: 4
    minCount: 1
    resourceType: Accelerator
  scheduling:
    type: Node
    node:
      nodeSelector:
        nvidia.com/gpu.present: "true"
      tolerations:
      - key: nvidia.com/gpu
        operator: Exists
        effect: NoSchedule
EOF
```

### 5.2 — Verify HardwareProfile exists

```bash
oc get hardwareprofile -n redhat-ods-applications
```

**Expected:** `nvidia-gpu` appears alongside `default-profile` and `gpu-profile`.

### 5.3 — How LLMInferenceService references a HardwareProfile

The `qwen3-8b-inferenceservice.yaml` in this repo already includes both annotations:

```yaml
metadata:
  annotations:
    opendatahub.io/hardware-profile-name: nvidia-gpu
    opendatahub.io/hardware-profile-namespace: redhat-ods-applications
```

When applied, the RHOAI mutating webhook injects the HardwareProfile's resources, nodeSelector, and tolerations into the pod template. You can still override individual fields in `spec.template.containers[].resources` — the webhook merges, it doesn't replace if inline resources are present.

**Important:** Create the HardwareProfile (step 5.1) BEFORE applying the LLMInferenceService. The webhook's `failurePolicy` is `Fail` — if the profile doesn't exist, the admission is **denied** (not silently skipped). If you already applied the model in Phase 3 without the profile, re-apply the InferenceService after creating the profile:

```bash
oc apply -f argo-apps/rhoai-playground/qwen3-8b-inferenceservice.yaml
```

---

## Checkpoint: Core RHOAI is working

At this point you have:
- RHOAI operator with Dashboard, KServe, Model Registry, Model Catalog, Workbenches, and GenAI Studio
- A running model (vLLM on GPU)
- GenAI Studio Playground (if Phase 4 was done)
- Hardware Profiles in the dashboard

If time is short, you can stop here. The customer has a functional RHOAI installation. MaaS adds API gateway, authentication, rate limiting, and usage tracking on top.

---

## Phase 6: Install RHCL Operator (Red Hat Connectivity Link / Kuadrant)

Source: `argo-apps/rhoai-maas/`

MaaS uses Kuadrant for API key auth and rate limiting. Kuadrant is provided by the RHCL operator.

### 6.1 — Create the operator namespace and OperatorGroup

```bash
oc apply -f argo-apps/rhoai-maas/rhcl-namespace.yaml
oc apply -f argo-apps/rhoai-maas/rhcl-operatorgroup.yaml
```

### 6.2 — Create the Subscription

```bash
oc apply -f argo-apps/rhoai-maas/rhcl-subscription.yaml
```

**Note:** The subscription uses `installPlanApproval: Manual` and includes `spec.config.resources` to prevent Kuadrant controller OOM (default limits are too low).

### 6.3 — Approve ALL InstallPlans (RHCL + dependencies)

RHCL has OLM-level dependencies on **Limitador** and **Authorino** operators. OLM creates separate InstallPlans for each. You must approve all of them — RHCL CSV won't reach `Succeeded` until its dependencies are installed.

```bash
# List all pending InstallPlans
oc get installplan -n rhcl-operator

# Approve each one (repeat for every pending InstallPlan)
oc patch installplan <INSTALLPLAN_NAME> -n rhcl-operator --type merge -p '{"spec":{"approved":true}}'
```

Expect to see InstallPlans for: RHCL, Limitador operator, and Authorino operator.

### 6.4 — Wait for CSV to succeed

```bash
oc get csv -n rhcl-operator -w
```

**Expected:** All CSVs (RHCL, Limitador, Authorino) reach `Succeeded`.

### 6.5 — Verify Kuadrant CRD exists

```bash
oc get crd kuadrants.kuadrant.io
```

**Expected:** CRD exists. If not, the operator hasn't finished installing — wait and re-check.

---

## Phase 7: Configure MaaS Infrastructure

### 7.1 — Create kuadrant-system namespace

```bash
oc apply -f argo-apps/rhoai-maas/kuadrant-namespace.yaml
```

### 7.2 — Deploy Kuadrant CR

```bash
oc apply -f argo-apps/rhoai-maas/kuadrant.yaml
```

### 7.3 — Verify Kuadrant is Ready

```bash
oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

**Expected:** `True`. May take 1-2 minutes. If stuck, check:

```bash
oc get pods -n kuadrant-system
```

Authorino and Limitador pods should be running.

### 7.4 — Deploy PostgreSQL for MaaS

MaaS needs a database but RHOAI doesn't deploy one.

```bash
oc apply -f argo-apps/rhoai-maas/postgresql.yaml
```

### 7.5 — Verify PostgreSQL is Ready

```bash
oc wait deployment/maas-postgresql -n redhat-ods-applications --for=condition=Available --timeout=120s
```

**Expected:** Deployment is Available. Double-check:

```bash
oc get pods -n redhat-ods-applications -l app=maas-postgresql
```

Pod should be `Running` and `1/1 Ready`.

### 7.6 — Create the DB connection Secret

```bash
oc apply -f argo-apps/rhoai-maas/maas-db-config.yaml
```

### 7.7 — Verify Secret exists

```bash
oc get secret maas-db-config -n redhat-ods-applications
```

**Expected:** Secret exists.

### 7.8 — Enable MaaS in the Dashboard config

The operator won't deploy `maas-api` until the dashboard is configured for MaaS. This is a separate config from the DSC patch — both are required.

```bash
oc apply --server-side --force-conflicts -f - <<'EOF'
apiVersion: opendatahub.io/v1alpha
kind: OdhDashboardConfig
metadata:
  name: odh-dashboard-config
  namespace: redhat-ods-applications
spec:
  dashboardConfig:
    modelAsService: true
    maasAuthPolicies: true
EOF
```

**Verify:**

```bash
oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications -o jsonpath='{.spec.dashboardConfig.modelAsService}'
```

**Expected:** `true`

### 7.9 — Patch DSC to enable Models-as-a-Service

This tells RHOAI to deploy the maas-controller, maas-api, and create the `models-as-a-service` namespace.

Do NOT use `argo-apps/rhoai-maas/dsc-maas-patch.yaml` directly — it includes `llamastackoperator: Managed` which you may not need. Apply only the MaaS component:

```bash
oc apply --server-side --force-conflicts -f - <<'EOF'
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    kserve:
      modelsAsService:
        managementState: Managed
EOF
```

### 7.10 — Verify MaaS controller is deploying

This takes 2-5 minutes. The operator deploys the controller and creates the namespace.

```bash
# Wait for the models-as-a-service namespace to be created
oc get namespace models-as-a-service
```

If the namespace doesn't appear after 3 minutes, check DSC status:

```bash
oc get datasciencecluster default-dsc -o jsonpath='{range .status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}'
```

```bash
# Verify maas-controller is running
oc get pods -n redhat-ods-applications -l app.kubernetes.io/part-of=models-as-a-service
```

**Expected:** `maas-controller` pod is Running. You will NOT see `maas-api` yet — it is created by the maas-controller only after the `maas-default-gateway` Gateway exists (Phase 8.3).

```bash
# Verify the llmisvc-controller is running
oc get pods -n redhat-ods-applications -l control-plane=llmisvc-controller-manager
```

**Expected:** Controller pod is Running.

---

## Phase 8: Configure MaaS Networking and Auth

### 8.1 — Create the TLS cert-generating Service

This headless Service tricks OpenShift's service-ca into generating a TLS cert for the MaaS gateway.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: maas-gateway-tls
  name: maas-gateway-cert-generator
  namespace: openshift-ingress
spec:
  clusterIP: None
  ports:
    - port: 443
      targetPort: 443
      protocol: TCP
EOF
```

### 8.2 — Verify TLS Secret was generated

```bash
oc get secret maas-gateway-tls -n openshift-ingress
```

**Expected:** Secret exists (created by OpenShift service-ca within seconds).

### 8.3 — Deploy the MaaS Gateway

The Gateway TLS `certificateRefs` references `cert-manager-ingress-cert`. If your cluster does NOT have cert-manager with a wildcard cert, use `maas-gateway-tls` (the service-ca cert from step 8.1) instead.

**IMPORTANT:** The `infrastructure.parametersRef` pointing to `data-science-gateway-config` ConfigMap is required. Without it, the Gateway gets an IPAddress instead of a Hostname, which breaks Kuadrant AuthPolicy path resolution.

**Option A — You have cert-manager with a wildcard cert** (the default in the manifest):

```bash
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
  name: maas-default-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: data-science-gateway-class
  infrastructure:
    parametersRef:
      name: data-science-gateway-config
      group: ""
      kind: ConfigMap
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: cert-manager-ingress-cert
EOF
```

**Option B — No cert-manager; use service-ca cert instead:**

If the cluster doesn't have cert-manager, copy the service-ca cert to the expected name (the Gateway controller reconciles `certificateRefs` back to `cert-manager-ingress-cert`):

```bash
oc get secret maas-gateway-tls -n openshift-ingress -o json | \
  jq '.metadata.name = "cert-manager-ingress-cert" | del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.ownerReferences)' | \
  oc apply -f -
```

Then apply the same Gateway as Option A (with `cert-manager-ingress-cert`). The cert will be service-ca signed (not publicly trusted), so use `curl -k` for testing.

```bash
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  annotations:
    opendatahub.io/managed: "false"
    security.opendatahub.io/authorino-tls-bootstrap: "true"
  name: maas-default-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: data-science-gateway-class
  infrastructure:
    parametersRef:
      name: data-science-gateway-config
      group: ""
      kind: ConfigMap
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      allowedRoutes:
        namespaces:
          from: All
      tls:
        mode: Terminate
        certificateRefs:
          - name: cert-manager-ingress-cert
EOF
```

### 8.4 — Verify the Gateway is Accepted

```bash
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{range .status.conditions[*]}{.type}: {.status}{"\n"}{end}'
```

**Expected:** `Accepted: True` and `Programmed: True`.

**Bare-metal note:** On bare-metal clusters without MetalLB, the Gateway's LoadBalancer Service will stay `Pending` and `Programmed` may not become `True`. This is expected — the Route created in step 8.7 bypasses the LoadBalancer entirely and routes through OpenShift's built-in HAProxy router. As long as `Accepted: True`, you're fine. Ignore `Pending` external IP.

### 8.5 — Verify maas-api is now running

The maas-controller creates the `maas-api` deployment once it detects the `maas-default-gateway` Gateway. This may take 1-2 minutes after the Gateway is created.

```bash
oc get pods -n redhat-ods-applications -l app.kubernetes.io/part-of=models-as-a-service
```

**Expected:** Both `maas-controller` and `maas-api` pods are Running. If `maas-api` doesn't appear after 2 minutes, check the controller logs:

```bash
oc logs deployment/maas-controller -n redhat-ods-applications --tail=50
```

### 8.6 — Fix payload-processing OOM (if needed)

The maas-controller deploys `payload-processing` pods in `openshift-ingress`. These sit in the Envoy request path as ext_proc filters for token counting (rate limiting, usage tracking). The default memory limit is 256Mi, which often causes OOM crashes.

Check if payload-processing pods are crash-looping:

```bash
oc get pods -n openshift-ingress -l app.kubernetes.io/part-of=models-as-a-service
```

If you see OOMKilled or CrashLoopBackOff, apply the resource override:

```bash
oc apply --server-side --force-conflicts -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payload-processing
  namespace: openshift-ingress
  annotations:
    opendatahub.io/managed: "false"
  labels:
    app.kubernetes.io/component: payload-processing
    app.kubernetes.io/name: payload-processing
    app.kubernetes.io/part-of: models-as-a-service
spec:
  selector:
    matchLabels:
      app: payload-processing
  template:
    metadata:
      labels:
        app: payload-processing
        app.kubernetes.io/component: payload-processing
        app.kubernetes.io/name: payload-processing
        app.kubernetes.io/part-of: models-as-a-service
    spec:
      containers:
        - name: payload-processing
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: "1"
              memory: 1Gi
EOF
```

> **IMPORTANT:** The `opendatahub.io/managed: "false"` annotation tells the maas-controller to skip SSA reconciliation for this resource. After RHOAI upgrades, review and update this manifest or remove the annotation. You MUST use `--server-side --force-conflicts` because maas-controller owns the fields via SSA.

Verify pods restart with new limits:

```bash
oc get pods -n openshift-ingress -l app=payload-processing -w
```

**Expected:** Pod(s) Running without OOM restarts.

### 8.7 — Create the MaaS Route (stable DNS)

The Route targets the Service `maas-default-gateway-data-science-gateway-class` — this is auto-created by the Gateway controller when the Gateway is accepted (step 8.4). Verify it exists before creating the Route:

```bash
oc get svc maas-default-gateway-data-science-gateway-class -n openshift-ingress
```

Replace `YOUR_CLUSTER_DOMAIN` with your actual cluster domain.

```bash
oc apply -f - <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: maas-default-gateway
  namespace: openshift-ingress
spec:
  host: maas.YOUR_CLUSTER_DOMAIN
  port:
    targetPort: https
  tls:
    insecureEdgeTerminationPolicy: Redirect
    termination: passthrough
  to:
    kind: Service
    name: maas-default-gateway-data-science-gateway-class
    weight: 100
EOF
```

### 8.8 — Verify the Route is Admitted

```bash
oc get route maas-default-gateway -n openshift-ingress
```

**Expected:** Route shows `Admitted` with the host `maas.YOUR_CLUSTER_DOMAIN`.

### 8.9 — Apply the Kuadrant WASM filter fix (CRITICAL)

Without this, Kuadrant's WASM filters leak to the data-science-gateway and break the RHOAI dashboard with 401 errors.

```bash
oc apply -f argo-apps/rhoai-maas/remove-kuadrant-wasm-from-dsg.yaml
```

### 8.10 — Verify dashboard still works

Open the RHOAI dashboard in a browser. If you get 401 errors, the WASM filter fix didn't apply correctly — re-check the EnvoyFilter.

### 8.11 — Bootstrap Authorino TLS

Authorino needs TLS certs to communicate with the maas-api. Three patches in sequence:

**Step A — Patch the Authorino Service to trigger cert generation:**

```bash
oc apply --server-side --force-conflicts -f argo-apps/rhoai-maas/tls-authorino-service.yaml
```

Verify cert was generated:

```bash
oc get secret authorino-server-cert -n kuadrant-system
```

**Expected:** Secret exists.

**Step B — Create the Authorino CR with TLS:**

```bash
oc apply --server-side --force-conflicts -f argo-apps/rhoai-maas/tls-authorino-cr.yaml
```

Verify:

```bash
oc get authorino authorino -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
```

**Expected:** `True`.

**Step C — Patch the Authorino Deployment with CA bundle env vars:**

```bash
oc apply --server-side --force-conflicts -f argo-apps/rhoai-maas/tls-authorino-deployment.yaml
```

Verify Authorino pod restarts with new env:

```bash
oc get pods -n kuadrant-system -l authorino-resource=authorino -w
```

**Expected:** Pod restarts and reaches Running 1/1.

```bash
oc exec -n kuadrant-system deploy/authorino -c authorino -- env | grep SSL_CERT_FILE
```

**Expected:** `SSL_CERT_FILE=/etc/ssl/certs/openshift-service-ca/service-ca-bundle.crt`

---

## Phase 9: Register Model with MaaS

### 9.1 — Check HTTPRoute status

The `llmisvc-controller-manager` creates HTTPRoutes when it sees a LLMInferenceService with `spec.router.gateway.refs`. Since the model was deployed in Phase 3 before the gateway existed, the HTTPRoute may not exist yet.

```bash
oc get httproute -n rhoai-playground
```

If no HTTPRoute exists, that's expected — the controller restart in Phase 10.1 will trigger re-reconciliation and create it. If it already exists, even better.

### 9.2 — Create the MaaSModelRef

For `qwen3-8b`:

```bash
oc apply -f - <<'EOF'
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: qwen3-8b
  namespace: rhoai-playground
spec:
  modelRef:
    kind: LLMInferenceService
    name: qwen3-8b
EOF
```

**Note:** Use `kind: LLMInferenceService`, NOT `InferenceService` (gotcha #2 in `argo-apps/rhoai-maas/README.md`).

### 9.3 — Verify MaaSModelRef status

```bash
oc get maasmodelref -n rhoai-playground -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase}{"\n"}{end}'
```

**Expected:** Phase is `Ready` or `Available`.

### 9.4 — Enable telemetry on the Tenant

```bash
oc apply -f - <<'EOF'
apiVersion: maas.opendatahub.io/v1alpha1
kind: Tenant
metadata:
  name: default-tenant
  namespace: models-as-a-service
spec:
  telemetry:
    enabled: true
    metrics:
      captureOrganization: true
      captureUser: true
      captureGroup: false
      captureModelUsage: true
EOF
```

### 9.5 — Create the MaaSSubscription

Adjust `owner.groups`, `owner.users`, `modelRefs`, and rate limits for your environment.

```bash
oc apply -f - <<'EOF'
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: demo-subscription
  namespace: models-as-a-service
spec:
  owner:
    groups:
      - name: YOUR_GROUP
    users:
      - YOUR_ADMIN_USER
  modelRefs:
    - name: qwen3-8b
      namespace: rhoai-playground
      tokenRateLimits:
        - limit: 1000000
          window: "1h"
        - limit: 5000000
          window: "24h"
  priority: 10
EOF
```

### 9.6 — Verify MaaSSubscription

```bash
oc get maassubscription -n models-as-a-service -o jsonpath='{range .items[*]}{.metadata.name}: {.status.phase}{"\n"}{end}'
```

**Expected:** Phase shows `Accepted` or `Ready`.

### 9.7 — Create the MaaSAuthPolicy

Without this, requests get 403 even with a valid API key.

```bash
oc apply -f - <<'EOF'
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: demo-auth-policy
  namespace: models-as-a-service
spec:
  subjects:
    groups:
      - name: YOUR_GROUP
    users:
      - YOUR_ADMIN_USER
  modelRefs:
    - name: qwen3-8b
      namespace: rhoai-playground
EOF
```

### 9.8 — Verify MaaSAuthPolicy

```bash
oc get maasauthpolicy -n models-as-a-service
```

**Expected:** Resource exists without errors.

---

## Phase 10: Post-Deployment Workarounds

### 10.1 — Restart controllers to pick up new CRDs and create HTTPRoute

The `llmisvc-controller-manager` needs a restart for two reasons:
1. To recognize AuthPolicy CRDs installed by RHCL
2. To re-reconcile the LLMInferenceService from Phase 3 — now that `maas-default-gateway` exists, it will create the HTTPRoute

```bash
# Wait for AuthPolicy CRD
oc get crd authpolicies.kuadrant.io

# Restart both controllers
oc rollout restart deployment/llmisvc-controller-manager -n redhat-ods-applications
oc rollout restart deployment/kuadrant-operator-controller-manager -n rhcl-operator
```

### 10.2 — Verify controllers are back and HTTPRoute was created

```bash
oc rollout status deployment/llmisvc-controller-manager -n redhat-ods-applications --timeout=120s
oc rollout status deployment/kuadrant-operator-controller-manager -n rhcl-operator --timeout=120s
```

Verify the HTTPRoute now exists:

```bash
oc get httproute -n rhoai-playground
```

**Expected:** An HTTPRoute exists with `parentRefs` pointing to `maas-default-gateway`. If still missing, check the llmisvc-controller logs:

```bash
oc logs -n redhat-ods-applications -l control-plane=llmisvc-controller-manager --tail=30
```

### 10.3 — Fix maas-api OOM (RHOAI 3.4.x bug)

The maas-api Deployment is hardcoded to 128Mi memory, which causes OOM. Patch to 512Mi.

```bash
oc apply --server-side --force-conflicts -f argo-apps/rhoai-maas/maas-api-resource-override.yaml
```

### 10.4 — Verify maas-api is running with new limits

```bash
oc get deployment maas-api -n redhat-ods-applications -o jsonpath='{.spec.template.spec.containers[0].resources.limits.memory}'
```

**Expected:** `512Mi`.

```bash
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=maas-api
```

**Expected:** Pod is Running and not OOMKilled.

---

## Phase 11: Smoke Test

### 11.1 — Create an API key

Open the RHOAI dashboard -> Gen AI Studio -> API Keys -> Create API Key.

Alternatively, use the MaaS API:

```bash
MAAS_HOST="maas.YOUR_CLUSTER_DOMAIN"

# Get a user token (login to OpenShift first)
TOKEN=$(oc whoami -t)

# List available models via MaaS API
curl -sk "https://${MAAS_HOST}/maas-api/v1/models" \
  -H "Authorization: Bearer ${TOKEN}"
```

### 11.2 — Test model inference via MaaS gateway

Replace `API_KEY` with the key created in step 10.1.

```bash
MAAS_HOST="maas.YOUR_CLUSTER_DOMAIN"

curl -sk -X POST "https://${MAAS_HOST}/rhoai-playground/qwen3-8b/v1/chat/completions" \
  -H "Authorization: Bearer sk-oai-YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3-8b",
    "messages": [{"role": "user", "content": "What is OpenShift?"}],
    "max_tokens": 200,
    "chat_template_kwargs": {"enable_thinking": false}
  }'
```

**Expected:** JSON response with the model's completion. If Qwen3 returns `<think>` tags, add the `chat_template_kwargs` parameter shown above.

### 11.3 — Verify rate limiting works

```bash
# Check if TokenRateLimitPolicy was created by MaaS
oc get tokenratelimitpolicy -n models-as-a-service
```

**Expected:** A TokenRateLimitPolicy exists matching your subscription.

### 11.4 — Full resource health check

```bash
echo "=== DataScienceCluster ==="
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'
echo ""

echo "=== Kuadrant ==="
oc get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
echo ""

echo "=== PostgreSQL ==="
oc get pods -n redhat-ods-applications -l app=maas-postgresql -o jsonpath='{.items[0].status.phase}'
echo ""

echo "=== MaaS API ==="
oc get pods -n redhat-ods-applications -l app.kubernetes.io/name=maas-api -o jsonpath='{.items[0].status.phase}'
echo ""

echo "=== Gateway ==="
oc get gateway maas-default-gateway -n openshift-ingress -o jsonpath='{range .status.conditions[*]}{.type}: {.status}{"\n"}{end}'

echo "=== Authorino ==="
oc get authorino authorino -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
echo ""

echo "=== LLMInferenceService ==="
oc get llminferenceservice -n rhoai-playground

echo "=== MaaSModelRef ==="
oc get maasmodelref -n rhoai-playground

echo "=== MaaSSubscription ==="
oc get maassubscription -n models-as-a-service

echo "=== MaaSAuthPolicy ==="
oc get maasauthpolicy -n models-as-a-service

echo "=== HTTPRoute ==="
oc get httproute -n rhoai-playground

echo "=== Route ==="
oc get route maas-default-gateway -n openshift-ingress
```

---

## Troubleshooting

### Dashboard returns 401 after Kuadrant install

Kuadrant WASM filters leaked to data-science-gateway. Apply the fix from Phase 8.9:

```bash
oc apply -f argo-apps/rhoai-maas/remove-kuadrant-wasm-from-dsg.yaml
```

### maas-api pod OOMKilled

Apply the resource override from Phase 10.3. Check if the maas-controller reverted it:

```bash
oc get deployment maas-api -n redhat-ods-applications -o jsonpath='{.metadata.annotations.opendatahub\.io/managed}'
```

Should be `false`. If missing, re-apply the override.

### No HTTPRoute created for LLMInferenceService

The LLMInferenceService needs `spec.router.gateway.refs` pointing to `maas-default-gateway`. Check:

```bash
oc get llminferenceservice -n rhoai-playground -o yaml | grep -A5 router
```

If missing, the model won't be accessible via MaaS.

### MaaSSubscription shows no API key / 403 on requests

Both `MaaSSubscription` AND `MaaSAuthPolicy` are required. The subscription grants rate-limited access; the auth policy authorizes the request through the gateway. Check both exist and reference the same groups/users.

### models-as-a-service namespace not created

The DSC patch from Phase 7.8 triggers this. Check DSC status:

```bash
oc get datasciencecluster default-dsc -o jsonpath='{.status.conditions[?(@.type=="modelsAsServiceReady")].message}'
```

If it reports a missing PostgreSQL connection, verify the `maas-db-config` Secret exists in `redhat-ods-applications`.

### Authorino not authenticating (TLS errors in logs)

Check all three TLS pieces from Phase 8.11:

```bash
oc get secret authorino-server-cert -n kuadrant-system   # must exist
oc get authorino authorino -n kuadrant-system             # must be Ready
oc exec -n kuadrant-system deploy/authorino -c authorino -- env | grep SSL  # must show CA path
```

### Qwen3 returns thinking tags

Add `"chat_template_kwargs": {"enable_thinking": false}` to the request body. This is a model-level behavior, not a MaaS issue.

---

## Reference: Complete Dependency Chain

```
RHOAI Operator (Phase 1)
  |
  v
Base Config: DSC + Dashboard + Model Catalog + Model Registry + Workbenches (Phase 2)
  |
  +-- data-science-gateway-class created by KServe
  |
  v
Deploy Model (Phase 3) --> vLLM pod running, model visible in dashboard
  |
LlamaStack (Phase 4, optional) --> GenAI Studio Playground
  |
Hardware Profiles (Phase 5) --> GPU configs visible in dashboard
  |
  |  --- Checkpoint: core RHOAI working ---
  |
  v
RHCL Operator (Phase 6) --> provides Kuadrant CRDs
  |
  v
Kuadrant CR (Phase 7.2) --> Authorino + Limitador pods
  |
PostgreSQL + DB Secret (Phase 7.4-7.6)
  |
DSC MaaS patch (Phase 7.8) --> maas-controller, maas-api, models-as-a-service namespace
  |
  v
Gateway + Route + TLS (Phase 8.1-8.8) --> maas-default-gateway
  |
WASM filter fix (Phase 8.9) --> prevents dashboard 401
  |
Authorino TLS (Phase 8.11) --> API key auth chain
  |
  v
MaaSModelRef (Phase 9.2) --> model visible in MaaS catalog
  |
MaaSSubscription + MaaSAuthPolicy (Phase 9.5-9.7) --> rate limits + access control
  |
  v
Controller restart + maas-api fix (Phase 10)
  |
  v
Working MaaS endpoint (Phase 11)
```
