# === 3_register_model.py — Elyra pipeline node ===
import os
import subprocess
import requests
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

MODEL_REGISTRY_URL = "https://demo-registry.rhoai-model-registries.svc:8443"
MODEL_REGISTRY_API = f"{MODEL_REGISTRY_URL}/api/model_registry/v1alpha3"

try:
    with open("/var/run/secrets/kubernetes.io/serviceaccount/token") as f:
        AUTH_TOKEN = f.read().strip()
except FileNotFoundError:
    AUTH_TOKEN = subprocess.check_output(["oc", "whoami", "-t"]).decode().strip()

headers = {
    "Authorization": f"Bearer {AUTH_TOKEN}",
    "Content-Type": "application/json",
}

accuracy = "unknown"
f1 = "unknown"
if os.path.exists("metrics.txt"):
    with open("metrics.txt") as f:
        for line in f:
            k, v = line.strip().split("=")
            if k == "accuracy":
                accuracy = v
            elif k == "f1":
                f1 = v

resp = requests.post(
    f"{MODEL_REGISTRY_API}/registered_models",
    headers=headers,
    json={
        "name": "elyra-gradient-boosting",
        "description": "GradientBoostingClassifier trained via Elyra visual pipeline",
        "customProperties": {
            "pipeline": {"stringValue": "elyra-visual"},
            "framework": {"stringValue": "scikit-learn"},
        },
    },
    verify=False,
)
resp.raise_for_status()
model_id = resp.json()["id"]
print(f"Registered model: {resp.json()['name']} (id={model_id})")

resp = requests.post(
    f"{MODEL_REGISTRY_API}/registered_models/{model_id}/versions",
    headers=headers,
    json={
        "name": "v1",
        "description": f"accuracy={accuracy}, f1={f1}",
        "customProperties": {
            "accuracy": {"stringValue": str(accuracy)},
            "f1_score": {"stringValue": str(f1)},
            "source": {"stringValue": "elyra-pipeline"},
        },
    },
    verify=False,
)
resp.raise_for_status()
version_id = resp.json()["id"]
print(f"Created version: {resp.json()['name']} (id={version_id})")

resp = requests.post(
    f"{MODEL_REGISTRY_API}/model_versions/{version_id}/artifacts",
    headers=headers,
    json={
        "name": "gradient-boosting-pkl",
        "description": "Pickle-serialized GradientBoostingClassifier",
        "uri": "s3://pipelines/models/gradient_boosting.pkl",
        "artifactType": "model-artifact",
        "modelFormatName": "sklearn",
        "modelFormatVersion": "1.5",
    },
    verify=False,
)
resp.raise_for_status()
print(f"Created artifact -> s3://pipelines/models/gradient_boosting.pkl")
print("\nModel registered successfully in Model Registry!")
