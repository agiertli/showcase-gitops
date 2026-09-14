# === 2_train_model.py — Elyra pipeline node ===
import io
import pickle
import boto3
import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import accuracy_score, f1_score

MINIO_ENDPOINT = "http://minio-service.minio.svc.cluster.local:9000"
MINIO_ACCESS_KEY = "minio"
MINIO_SECRET_KEY = "minio123"
MINIO_BUCKET = "pipelines"

s3 = boto3.client(
    "s3",
    endpoint_url=MINIO_ENDPOINT,
    aws_access_key_id=MINIO_ACCESS_KEY,
    aws_secret_access_key=MINIO_SECRET_KEY,
)

train_obj = s3.get_object(Bucket=MINIO_BUCKET, Key="data/train.csv")
train_df = pd.read_csv(io.BytesIO(train_obj["Body"].read()))

test_obj = s3.get_object(Bucket=MINIO_BUCKET, Key="data/test.csv")
test_df = pd.read_csv(io.BytesIO(test_obj["Body"].read()))

X_train = train_df.drop("target", axis=1)
y_train = train_df["target"]
X_test = test_df.drop("target", axis=1)
y_test = test_df["target"]

model = GradientBoostingClassifier(
    n_estimators=100, max_depth=5, learning_rate=0.1, random_state=42
)
model.fit(X_train, y_train)

y_pred = model.predict(X_test)
accuracy = accuracy_score(y_test, y_pred)
f1 = f1_score(y_test, y_pred)
print(f"Accuracy: {accuracy:.4f}")
print(f"F1 Score: {f1:.4f}")

model_bytes = pickle.dumps(model)
s3.put_object(Bucket=MINIO_BUCKET, Key="models/gradient_boosting.pkl", Body=model_bytes)
print(f"\nModel saved to s3://{MINIO_BUCKET}/models/gradient_boosting.pkl ({len(model_bytes)} bytes)")

with open("metrics.txt", "w") as f:
    f.write(f"accuracy={accuracy:.4f}\nf1={f1:.4f}\n")
print("Metrics written to metrics.txt")
