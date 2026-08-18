# GitOpsified showcase of selected Red Hat Products

This repository helps to get quickly up and running with selected Red Hat products. It's designed for demo, PoC, and enablement purposes — not production. The manifests can be applied via ArgoCD (app-of-apps) or used as a reference for manual/agentic setup on an existing cluster.

## RHOAI Feature Layers

RHOAI features are split into independent, composable layers. Apply `rhoai-config` first, then layer on whichever features you need:

| Layer | Directory | What it enables | Depends on |
|-------|-----------|----------------|------------|
| **Base config** | `argo-apps/rhoai-config/` | Dashboard, KServe, Model Registry, Model Catalog, GenAI Playground | RHOAI operator installed |
| **Model Serving** | `argo-apps/rhoai-playground/` | InferenceServices, ServingRuntimes, LlamaStack | Base config |
| **MLflow** | `argo-apps/rhoai-mlflow/` | MLflow operator + MLflow CR | Base config |
| **MaaS** | `argo-apps/rhoai-maas/` | Models-as-a-Service, Kuadrant, gateway, auth, observability operators | Base config |
| **Observability** | `argo-apps/rhoai-observability/` | MonitoringStack, dashboards | Base config + MaaS |

Each layer carries its own DSC patch (ServerSideApply) that enables only the components it needs. This means you can deploy Model Registry + Catalog without MaaS, or MLflow without the playground.

## Other Supported Products

 - Red Hat OpenShift Pipelines
 - Red Hat OpenShift Dev Spaces
 - Red Hat Trusted Artifact Signer (RHTAS)
 - Namespace Config Operator (Community support only, integrated with Dev Spaces)
 - Red Hat Single Sign On (integrated with RHTAS)
 - ArgoCD RBAC - fine-grained permissions instead of cluster-admin

Component diagram of this solution looks like this:

![Component diagram](images/showcase-gitops-1.png)

## Usage

 - Configure what ArgoCD Application you want to enable in [parent application](argo-apps/tooling-app-of-apps/values.yaml)
 - If you want to use RHTAS, make sure to fix [argo-apps/rhtas-install/values.yaml](argo-apps/rhtas-install/values.yaml) so it fits your cluster
 - Using `oc` cli , log into the OpenShift cluster as cluster-admin
 - Execute installation script
 ```bash
cd install/
./install.sh -p <ARGO_CD_ADMIN_PASSWORD>
```
 - Once the command finishes, you can log in to the ArgoCD Console to observe the installation progress. You can locate the ArgoCD Server URL via:
  ```bash
  oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}{"\n"}'
  ```
 - Use `admin` username and password which you passed to the install script

## Troubleshooting

Despite ArgoCD being awesome, it's still a software written by human beings, thus riddled with bugs. This section describes the typical troubleshooting scenarios I have encountered while working on this solution.

### Parent App Error State

If the parent app ends up in error state as shown below:

![Error ArgoCD](images/argo-error.png)

You need to click `Refresh`. This will fix the error state and the parent application will be properly reconciled.

![OK ArgoCD](images/argo-ok.png)


### Customer Resources not visible in the ArgoCD UI

If the operator custom resources are not visible in the ArgoCD UI despite them being added in the [Resource Inclusion](argo-apps/rbac/argocd-policy-patch.yaml) you need to delete few gitops pods

Before deleting pod:

![No resources](images/custom-resources-missing.png)

Delete the pods by executing following command:

```bash
oc get pods -n openshift-gitops | grep gitops-server
oc delete pod <GITOPS_SERVER_POD_NAME> -n openshift-gitops
oc get pods -n openshift-gitops | grep redis
oc delete pod <REDIS_POD_NAME> -n openshift-gitops
```

Afte deleting pod:
![Resources present](images/custom-resources-present.png)






