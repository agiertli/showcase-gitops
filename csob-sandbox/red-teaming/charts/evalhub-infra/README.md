# evalhub-infra

Helm chart to deploy all EvalHub red-teaming prerequisites on OpenShift with RHOAI 3.x.

## Prerequisites

- RHOAI 3.x installed (operator + DSC)
- `oc` logged in as cluster-admin
- Helm 3.x

## What it deploys

| Component | Purpose |
|-----------|---------|
| S4 (Ceph RadosGW) | S3-compatible object storage for garak pipeline artifacts |
| PostgreSQL | EvalHub database |
| DSPA | Data Science Pipelines (auto-deploys MariaDB + pipeline server) |
| EvalHub CR | TrustyAI evaluation hub with garak + garak-kfp providers |
| Model auth Secret | API keys for judge/SDG/attacker models (intents scans) |
| NetworkPolicy | Fixes DSPA auto-generated policy that blocks EvalHub pods |
| MLflow RBAC | Grants `create` on `mlflow.kubeflow.org/experiments` (kube-rbac-proxy requires it) |

## Quick start

```bash
# Default values (dev/sandbox — no external API keys)
helm install evalhub-infra . -n csob-sandbox --create-namespace

# With RHDP MaaS API keys for intents judge/SDG models
helm install evalhub-infra . -n csob-sandbox --create-namespace \
  --set modelAuth.judgeApiKey="sk-YOUR-KEY" \
  --set modelAuth.sdgApiKey="sk-YOUR-KEY" \
  --set modelAuth.attackerApiKey="sk-YOUR-KEY"

# Custom namespace + PostgreSQL password
helm install evalhub-infra . -n my-namespace --create-namespace \
  --set namespace=my-namespace \
  --set postgres.password="securepass123"
```

## Wait for readiness

```bash
# Watch all pods come up
oc get pods -n csob-sandbox -w

# Verify EvalHub is running
oc get evalhub -n csob-sandbox

# Verify DSPA pipeline server is ready
oc get dspa -n csob-sandbox
```

## Key values

| Value | Default | Description |
|-------|---------|-------------|
| `namespace` | `csob-sandbox` | Target namespace |
| `s4.pvc.size` | `10Gi` | S4 storage size |
| `postgres.password` | `evalhub123` | PostgreSQL password |
| `postgres.pvc.enabled` | `true` | Use PVC instead of emptyDir |
| `modelAuth.judgeApiKey` | `` | API key for judge model (intents scans) |
| `modelAuth.sdgApiKey` | `` | API key for SDG model (intents scans) |
| `evalhub.mlflowTrackingUri` | `https://mlflow...` | MLflow tracking URI (set empty to disable) |

## NetworkPolicy fix

DSPA auto-generates a NetworkPolicy `ds-pipelines-dspa` that only allows KFP pipeline components. EvalHub pod (`app: eval-hub`) gets blocked, causing all garak-kfp intents jobs to appear stuck or failed. This chart includes a supplementary NetworkPolicy that fixes this.

## MLflow RBAC fix

EvalHub's kube-rbac-proxy requires `create` permission on `mlflow.kubeflow.org/experiments` for POST to `/api/v1/evaluations/jobs`. The operator-created `evalhub-tenant-admin` role only grants `get,list` on that resource. This chart adds a supplementary Role granting `create` to all service accounts in the namespace — without it, scan submission Jobs get HTTP 403.

## Uninstall

```bash
helm uninstall evalhub-infra -n csob-sandbox
```

Note: PVCs are not deleted by `helm uninstall`. Clean up manually if needed:
```bash
oc delete pvc s4-data evalhub-postgres-data -n csob-sandbox
```
