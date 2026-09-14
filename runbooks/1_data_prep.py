# === 1_data_prep.py — Elyra pipeline node ===
import io
import boto3
import pandas as pd
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split

MINIO_ENDPOINT = "http://minio-service.minio.svc.cluster.local:9000"
MINIO_ACCESS_KEY = "minio"
MINIO_SECRET_KEY = "minio123"
MINIO_BUCKET = "pipelines"

X, y = make_classification(
    n_samples=1000, n_features=20, n_informative=10,
    n_redundant=5, random_state=42
)
feature_names = [f"feature_{i}" for i in range(X.shape[1])]
df = pd.DataFrame(X, columns=feature_names)
df["target"] = y

X_train, X_test, y_train, y_test = train_test_split(
    df.drop("target", axis=1), df["target"], test_size=0.2, random_state=42
)

train_df = X_train.copy()
train_df["target"] = y_train
test_df = X_test.copy()
test_df["target"] = y_test

s3 = boto3.client(
    "s3",
    endpoint_url=MINIO_ENDPOINT,
    aws_access_key_id=MINIO_ACCESS_KEY,
    aws_secret_access_key=MINIO_SECRET_KEY,
)

for name, data in [("data/train.csv", train_df), ("data/test.csv", test_df)]:
    buf = io.BytesIO()
    data.to_csv(buf, index=False)
    buf.seek(0)
    s3.put_object(Bucket=MINIO_BUCKET, Key=name, Body=buf.getvalue())
    print(f"Uploaded {name} ({len(data)} rows)")

print("\nData preparation complete.")
