# RHOAI Base Config

Patches an existing RHOAI installation with sensible defaults:

- **Dashboard**: Managed
- **KServe**: Managed (single-model serving with raw deployment)
- **Model Registry**: Managed (namespace: `rhoai-model-registries`)
- **Model Catalog**: Enabled in the dashboard

## Prerequisites

- RHOAI operator already installed on the cluster
- The operator has created the default `DataScienceCluster` and `OdhDashboardConfig` resources

## What this does NOT include

This is the base layer. Feature-specific configuration lives in separate apps:

| Feature | Directory | What it adds |
|---------|-----------|-------------|
| MaaS (Models-as-a-Service) | `rhoai-maas/` | Kuadrant, gateway, auth, MaaS model refs, observability operators |
| MLflow | `rhoai-mlflow/` | MLflow operator enablement + MLflow CR |
| Model Serving (playground) | `rhoai-playground/` | InferenceServices, ServingRuntimes, LlamaStack |
| Observability | `rhoai-observability/` | Monitoring stack, dashboards |
