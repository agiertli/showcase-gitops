## EvalHub garak-kfp: jobs stuck as "Running" after pipeline completes

**Env:** RHOAI 3.5.1, OCP 4.20.37, MinIO S3, MLflow via service-serving cert

**Symptom:** `garak-kfp` scans complete (all KFP pods `Completed`, results in S3), but EvalHub job stays "Running" forever. Plain `garak` provider works fine.

**Error 1 — Adapter can't read S3 secret:**
```
WARNING - Could not read S3 credentials from secret csob-sandbox/s4-credentials: Invalid kube-config file. No configuration found.
botocore.exceptions.NoCredentialsError: Unable to locate credentials
```
Adapter pod has `EVALHUB_MODE=k8s` but no AWS env vars. EvalHub CR `spec.env` with S3 secretKeyRef does NOT propagate to adapter Job pods. RBAC for the adapter SA (`evalhub-csob-sandbox-job`) has been granted. The K8s client fails before making any API call.

**Error 2 — KFP launcher MLflow TLS:**
```
failed to create task-level MLflow run: tls: failed to verify certificate: x509: certificate signed by unknown authority
→ runID is required to update nested MLflow run
```
KFP launcher can't trust the MLflow service-serving CA cert → no runID created → second error at task completion.

**Questions:**
1. How do adapter Job pods get S3 credentials? `spec.env` doesn't reach them.
2. How does the KFP launcher trust service-serving CA for MLflow?

**Full payload and config:** https://github.com/agiertli/showcase-gitops — `csob-sandbox/red-teaming/scans/intents-raw/payload.json`
