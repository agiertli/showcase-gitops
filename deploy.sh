#!/bin/bash
set -euo pipefail

# RHOAI Feature Deployment Script
# Deploys composable RHOAI features onto an existing RHOAI installation.
# Handles operator ordering, CRD dependencies, and known workarounds.
#
# Usage: ./deploy.sh [--base] [--model MODEL] [--observability] [--maas DOMAIN] [--mlflow]
#   --base            Apply base config (required, always first)
#   --model MODEL     Deploy a model (qwen3-8b, qwen3-27b, muse-glimmer, thinkingcap-27b)
#   --observability   Deploy observability stack (COO, OTel, Tempo, dashboards)
#   --maas DOMAIN     Deploy MaaS with cluster domain (e.g. apps.ocp.example.com)
#   --mlflow          Deploy MLflow experiment tracking
#
# Examples:
#   ./deploy.sh --base --model qwen3-8b --observability
#   ./deploy.sh --base --model qwen3-8b --observability --maas apps.ocp.example.com

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARGO_APPS="$SCRIPT_DIR/argo-apps"

DEPLOY_BASE=false
DEPLOY_MODEL=""
DEPLOY_OBSERVABILITY=false
DEPLOY_MAAS=""
DEPLOY_MLFLOW=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --base) DEPLOY_BASE=true; shift ;;
    --model) DEPLOY_MODEL="$2"; shift 2 ;;
    --observability) DEPLOY_OBSERVABILITY=true; shift ;;
    --maas) DEPLOY_MAAS="$2"; shift 2 ;;
    --mlflow) DEPLOY_MLFLOW=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

log() { echo "==> $1"; }
warn() { echo "WARNING: $1"; }
wait_for_csv() {
  local ns=$1 name=$2 timeout=${3:-300}
  log "Waiting for CSV $name in $ns (${timeout}s timeout)..."
  for i in $(seq 1 $((timeout/5))); do
    phase=$(oc get csv -n "$ns" -o jsonpath="{.items[?(@.metadata.name=='$name')].status.phase}" 2>/dev/null || true)
    if [[ -z "$phase" ]]; then
      phase=$(oc get csv -n "$ns" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
    fi
    if [[ "$phase" == "Succeeded" ]]; then
      log "CSV $name ready"
      return 0
    fi
    sleep 5
  done
  warn "CSV $name not ready after ${timeout}s, continuing anyway..."
}

wait_for_crd() {
  local crd=$1 timeout=${2:-120}
  log "Waiting for CRD $crd..."
  for i in $(seq 1 $((timeout/5))); do
    if oc get crd "$crd" &>/dev/null; then
      log "CRD $crd available"
      return 0
    fi
    sleep 5
  done
  warn "CRD $crd not available after ${timeout}s"
  return 1
}

approve_installplan() {
  local ns=$1
  log "Auto-approving InstallPlans in $ns..."
  sleep 10
  for i in $(seq 1 12); do
    plans=$(oc get installplan -n "$ns" -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    if [[ -n "$plans" ]]; then
      while IFS= read -r plan; do
        [[ -z "$plan" ]] && continue
        oc patch installplan "$plan" -n "$ns" --type merge -p '{"spec":{"approved":true}}' 2>/dev/null && \
          log "Approved InstallPlan $plan in $ns" || true
      done <<< "$plans"
      return 0
    fi
    sleep 5
  done
}

# --- Validation ---
if ! oc whoami &>/dev/null; then
  echo "ERROR: Not logged into an OpenShift cluster. Run 'oc login' first."
  exit 1
fi

if [[ "$DEPLOY_BASE" != "true" ]]; then
  echo "ERROR: --base is required. Base config must always be deployed first."
  exit 1
fi

if [[ -n "$DEPLOY_MODEL" ]]; then
  case "$DEPLOY_MODEL" in
    qwen3-8b|qwen3-27b|muse-glimmer|thinkingcap-27b) ;;
    *) echo "ERROR: Unknown model: $DEPLOY_MODEL. Choose: qwen3-8b, qwen3-27b, muse-glimmer, thinkingcap-27b"; exit 1 ;;
  esac
fi

# ============================================================
# PHASE 1: Base Config
# ============================================================
log "PHASE 1: Deploying Base Config..."
oc apply -f "$ARGO_APPS/rhoai-config/" --server-side --force-conflicts 2>&1 | grep -v "unchanged" || true
log "Base Config applied."

# ============================================================
# PHASE 2: Model Serving
# ============================================================
if [[ -n "$DEPLOY_MODEL" ]]; then
  log "PHASE 2: Deploying model $DEPLOY_MODEL..."

  # Ensure namespace exists
  oc apply -f "$ARGO_APPS/rhoai-playground/namespace.yaml" --server-side 2>&1 | grep -v "unchanged" || true

  # Model-specific namespace (muse-glimmer has its own)
  if [[ "$DEPLOY_MODEL" == "muse-glimmer" ]]; then
    oc apply -f "$ARGO_APPS/rhoai-playground/muse-glimmer-namespace.yaml" --server-side 2>&1 | grep -v "unchanged" || true
    oc apply -f "$ARGO_APPS/rhoai-playground/muse-glimmer-storage.yaml" --server-side 2>&1 | grep -v "unchanged" || true
    oc apply -f "$ARGO_APPS/rhoai-playground/muse-glimmer-serving-runtime.yaml" --server-side --force-conflicts 2>&1 | grep -v "unchanged" || true
  fi

  # Deploy InferenceService
  oc apply -f "$ARGO_APPS/rhoai-playground/${DEPLOY_MODEL}-inferenceservice.yaml" --server-side --force-conflicts 2>&1 | grep -v "unchanged" || true

  # Determine model namespace and endpoint
  if [[ "$DEPLOY_MODEL" == "muse-glimmer" ]]; then
    MODEL_NS="muse-glimmer"
    MODEL_SVC="${DEPLOY_MODEL}-kserve-workload-svc.${MODEL_NS}.svc.cluster.local"
  else
    MODEL_NS="rhoai-playground"
    MODEL_SVC="${DEPLOY_MODEL}-kserve-workload-svc.${MODEL_NS}.svc.cluster.local"
  fi

  # Generate and apply LlamaStack config for the playground
  log "Configuring GenAI Playground for $DEPLOY_MODEL..."
  cat <<EOCFG | oc apply --server-side -f -
apiVersion: v1
kind: ConfigMap
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "1"
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  labels:
    opendatahub.io/dashboard: "true"
  name: llama-stack-config
  namespace: rhoai-playground
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
      - provider_id: vllm-${DEPLOY_MODEL}
        provider_type: remote::vllm
        config:
          api_token: \${env.VLLM_API_TOKEN_1:=fake}
          base_url: https://${MODEL_SVC}:8000/v1
          max_tokens: \${env.VLLM_MAX_TOKENS:=4096}
          tls_verify: \${env.VLLM_TLS_VERIFY:=true}
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
      - provider_id: vllm-${DEPLOY_MODEL}
        model_id: ${DEPLOY_MODEL}
        model_type: llm
        metadata:
          display_name: ${DEPLOY_MODEL}
      shields: []
      vector_stores: []
      datasets: []
      scoring_fns: []
      benchmarks: []
    server:
      port: 8321
EOCFG

  # Deploy LlamaStack for playground
  oc apply -f "$ARGO_APPS/rhoai-playground/llama-stack-distribution.yaml" --server-side --force-conflicts 2>&1 | grep -v "unchanged" || true
  log "Model $DEPLOY_MODEL deployment initiated."
fi

# ============================================================
# PHASE 3: Observability
# ============================================================
if [[ "$DEPLOY_OBSERVABILITY" == "true" ]]; then
  log "PHASE 3: Deploying Observability..."

  # Step 3a: Install operators (COO, OTel, Tempo)
  log "Installing observability operators..."
  for op in coo otel tempo; do
    oc apply -f "$ARGO_APPS/rhoai-observability/${op}-namespace.yaml" --server-side 2>&1 | grep -v "unchanged" || true
    oc apply -f "$ARGO_APPS/rhoai-observability/${op}-operatorgroup.yaml" --server-side 2>&1 | grep -v "unchanged" || true
    oc apply -f "$ARGO_APPS/rhoai-observability/${op}-subscription.yaml" --server-side 2>&1 | grep -v "unchanged" || true
  done

  # Auto-approve InstallPlans
  approve_installplan "cluster-observability-operator" &
  approve_installplan "openshift-opentelemetry-operator" &
  approve_installplan "openshift-tempo-operator" &
  wait

  # Wait for operator CSVs
  wait_for_csv "cluster-observability-operator" "" 300
  wait_for_csv "openshift-opentelemetry-operator" "" 300
  wait_for_csv "openshift-tempo-operator" "" 300

  # Step 3b: Apply DSCI monitoring patch and dashboard config
  log "Enabling DSCI monitoring..."
  oc apply -f "$ARGO_APPS/rhoai-observability/dsci-monitoring-patch.yaml" --server-side --force-conflicts 2>&1 | grep -v "unchanged" || true
  oc apply -f "$ARGO_APPS/rhoai-observability/dashboard-config-patch.yaml" --server-side --force-conflicts 2>&1 | grep -v "unchanged" || true
  oc apply -f "$ARGO_APPS/rhoai-observability/user-workload-monitoring.yaml" --server-side 2>&1 | grep -v "unchanged" || true

  # Step 3c: Bootstrap PersesDatasource fixes (must exist before operator restart)
  log "Bootstrapping PersesDatasource fixes..."
  wait_for_crd "persesdatasources.perses.dev" 120 || true
  if oc get crd persesdatasources.perses.dev &>/dev/null; then
    oc apply --server-side --force-conflicts -f "$ARGO_APPS/rhoai-observability/cluster-prometheus-datasource-fix.yaml" 2>&1 | grep -v "unchanged" || true
    oc apply --server-side --force-conflicts -f "$ARGO_APPS/rhoai-observability/tempo-datasource-fix.yaml" 2>&1 | grep -v "unchanged" || true
  fi

  # Step 3d: Restart RHOAI operator to detect COO CRDs
  log "Restarting RHOAI operator to detect COO CRDs..."
  oc delete pod -n redhat-ods-operator -l name=rhods-operator --wait=false 2>/dev/null || true
  sleep 30

  # Step 3e: Wait for MonitoringStack CRD, then apply remaining resources
  wait_for_crd "monitoringstacks.monitoring.rhobs" 300 || true

  # Apply NetworkPolicies and monitors
  log "Applying monitors and network policies..."
  for f in perses-coo-networkpolicy.yaml prometheus-thanos-networkpolicy.yaml; do
    oc apply -f "$ARGO_APPS/rhoai-observability/$f" --server-side 2>&1 | grep -v "unchanged" || true
  done

  # Apply monitoring.rhobs resources (need CRDs)
  if oc get crd servicemonitors.monitoring.rhobs &>/dev/null; then
    for f in otel-collector-rbac.yaml otel-collector-servicemonitor.yaml otel-collector-cluster-servicemonitor.yaml \
             dcgm-exporter-cluster-podmonitor.yaml observability-monitors.yaml; do
      oc apply -f "$ARGO_APPS/rhoai-observability/$f" --server-side --force-conflicts 2>&1 | grep -v "unchanged" || true
    done
  fi

  # Apply accelerator GPU recording rule
  oc apply -f "$ARGO_APPS/rhoai-observability/accelerator-gpu-metrics.yaml" --server-side 2>&1 | grep -v "unchanged" || true

  # Step 3f: Fix prometheus-web-tls-ca (operator creates ConfigMap, COO expects Secret)
  log "Fixing prometheus-web-tls-ca Secret..."
  for i in $(seq 1 24); do
    if oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring &>/dev/null; then
      if ! oc get secret prometheus-web-tls-ca -n redhat-ods-monitoring &>/dev/null; then
        oc get configmap prometheus-web-tls-ca -n redhat-ods-monitoring -o jsonpath='{.data.service-ca\.crt}' | \
          oc create secret generic prometheus-web-tls-ca -n redhat-ods-monitoring --from-file=service-ca.crt=/dev/stdin 2>/dev/null && \
          log "Created prometheus-web-tls-ca Secret" || true
      fi
      break
    fi
    sleep 10
  done

  # Step 3g: Verify Monitoring CR is Ready
  log "Waiting for Monitoring CR to be Ready..."
  for i in $(seq 1 24); do
    status=$(oc get monitoring -n redhat-ods-monitoring -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    if [[ "$status" == "True" ]]; then
      log "Monitoring CR is Ready"
      break
    fi
    if [[ "$status" == "False" ]]; then
      # Might need another operator restart
      oc delete pod -n redhat-ods-operator -l name=rhods-operator --wait=false 2>/dev/null || true
      sleep 20
    fi
    sleep 10
  done

  log "Observability deployment complete."
fi

# ============================================================
# PHASE 4: MaaS
# ============================================================
if [[ -n "$DEPLOY_MAAS" ]]; then
  log "PHASE 4: Deploying MaaS (domain: $DEPLOY_MAAS)..."

  # Update cluster config
  MAAS_HOST="maas.${DEPLOY_MAAS}"
  if [[ -n "$DEPLOY_MODEL" ]]; then
    MODEL_FOR_MAAS="$DEPLOY_MODEL"
    if [[ "$DEPLOY_MODEL" == "muse-glimmer" ]]; then
      MAAS_ENDPOINT="https://${MAAS_HOST}/muse-glimmer/muse-glimmer"
    else
      MAAS_ENDPOINT="https://${MAAS_HOST}/rhoai-playground/${DEPLOY_MODEL}"
    fi
  else
    MODEL_FOR_MAAS="muse-glimmer"
    MAAS_ENDPOINT="https://${MAAS_HOST}/muse-glimmer/muse-glimmer"
  fi

  # Patch cluster-config.yaml
  cat > "$ARGO_APPS/rhoai-maas/cluster-config.yaml" <<EOCFG
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config
  annotations:
    config.kubernetes.io/local-config: "true"
data:
  MAAS_HOST: ${MAAS_HOST}
  MAAS_ENDPOINT_OVERRIDE: ${MAAS_ENDPOINT}
EOCFG

  # Step 4a: Install RHCL operator
  log "Installing RHCL operator..."
  oc apply -f "$ARGO_APPS/rhoai-maas/rhcl-namespace.yaml" --server-side 2>&1 | grep -v "unchanged" || true
  oc apply -f "$ARGO_APPS/rhoai-maas/rhcl-operatorgroup.yaml" --server-side 2>&1 | grep -v "unchanged" || true
  oc apply -f "$ARGO_APPS/rhoai-maas/rhcl-subscription.yaml" --server-side 2>&1 | grep -v "unchanged" || true
  approve_installplan "red-hat-connectivity-link-operator"
  wait_for_csv "red-hat-connectivity-link-operator" "" 300

  # Step 4b: Apply Kuadrant CR and MaaS base resources
  log "Applying MaaS resources..."
  oc apply -f "$ARGO_APPS/rhoai-maas/kuadrant-namespace.yaml" --server-side 2>&1 | grep -v "unchanged" || true

  # Wait for Kuadrant CRD
  wait_for_crd "kuadrants.kuadrant.io" 120 || true

  # Apply kustomize (with force-conflicts for SSA)
  oc kustomize "$ARGO_APPS/rhoai-maas" | oc apply --server-side --force-conflicts -f - 2>&1 | grep -v "unchanged" || true

  # Step 4c: Patch subscription and auth policy for the correct model
  if [[ -n "$DEPLOY_MODEL" ]]; then
    if [[ "$DEPLOY_MODEL" == "muse-glimmer" ]]; then
      MODEL_NS_FOR_MAAS="muse-glimmer"
    else
      MODEL_NS_FOR_MAAS="rhoai-playground"
    fi

    log "Patching MaaS Subscription for model $DEPLOY_MODEL..."
    sleep 10
    oc patch maassubscription demo-subscription -n models-as-a-service --type merge \
      -p "{\"spec\":{\"modelRefs\":[{\"name\":\"${DEPLOY_MODEL}\",\"namespace\":\"${MODEL_NS_FOR_MAAS}\",\"tokenRateLimits\":[{\"limit\":1000000,\"window\":\"1h\"},{\"limit\":5000000,\"window\":\"24h\"}]}]}}" 2>/dev/null || true

    oc patch maasauthpolicy demo-auth-policy -n models-as-a-service --type merge \
      -p "{\"spec\":{\"modelRefs\":[{\"name\":\"${DEPLOY_MODEL}\",\"namespace\":\"${MODEL_NS_FOR_MAAS}\"}]}}" 2>/dev/null || true
  fi

  log "MaaS deployment complete."
fi

# ============================================================
# PHASE 5: MLflow
# ============================================================
if [[ "$DEPLOY_MLFLOW" == "true" ]]; then
  log "PHASE 5: Deploying MLflow..."
  oc apply -f "$ARGO_APPS/rhoai-mlflow/" --server-side --force-conflicts 2>&1 | grep -v "unchanged" || true
  log "MLflow deployment complete."
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================"
echo "  RHOAI Deployment Complete"
echo "============================================"
[[ "$DEPLOY_BASE" == "true" ]] && echo "  Base Config:    deployed"
[[ -n "$DEPLOY_MODEL" ]] && echo "  Model Serving:  $DEPLOY_MODEL"
[[ "$DEPLOY_OBSERVABILITY" == "true" ]] && echo "  Observability:  deployed"
[[ -n "$DEPLOY_MAAS" ]] && echo "  MaaS:           $DEPLOY_MAAS"
[[ "$DEPLOY_MLFLOW" == "true" ]] && echo "  MLflow:         deployed"
echo "============================================"
echo ""
if [[ -n "$DEPLOY_MODEL" ]]; then
  echo "Model readiness: watch with"
  if [[ "$DEPLOY_MODEL" == "muse-glimmer" ]]; then
    echo "  oc get pods -n muse-glimmer -w"
  else
    echo "  oc get pods -n rhoai-playground -w"
  fi
fi
if [[ "$DEPLOY_OBSERVABILITY" == "true" ]]; then
  echo "Observability: check dashboard at"
  echo "  Observe & monitor → Dashboard (Tech Preview)"
  echo "  Note: GPU utilization data may take 2-3 minutes to appear"
fi
