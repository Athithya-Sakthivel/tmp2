#!/usr/bin/env python3
import os
import sys
import logging
import shutil
import subprocess
from pathlib import Path
from datetime import datetime

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("batch")

ROOT = Path.cwd()
DATA_DIR = ROOT / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)

S3_PREFIX = os.environ.get("S3_PREFIX", "mlops-demo")
PYICEBERG_CATALOG = os.environ.get("PYICEBERG_CATALOG", "").strip()
PYICEBERG_NAMESPACE = os.environ.get("PYICEBERG_NAMESPACE", "mlops")
AWS_REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or None

DATASETS = [
    ("jainilcoder/online-payment-fraud-detection", "online_payment_fraud"),
    ("ealaxi/paysim1", "paysim")
]

def ensure_kaggle_credentials():
    kaggle_json = Path.home() / ".kaggle" / "kaggle.json"
    if kaggle_json.exists():
        log.info("Found Kaggle token file: %s", kaggle_json)
        return
    if os.environ.get("KAGGLE_USERNAME") and os.environ.get("KAGGLE_KEY"):
        log.info("Found KAGGLE_USERNAME/KAGGLE_KEY in environment")
        return
    log.error("Missing Kaggle credentials. Provide ~/.kaggle/kaggle.json or set KAGGLE_USERNAME and KAGGLE_KEY.")
    sys.exit(1)

def get_aws_account_id():
    try:
        import boto3
        sts = boto3.client("sts")
        resp = sts.get_caller_identity()
        account = resp.get("Account")
        if account:
            log.info("Retrieved AWS account id via boto3: %s", account)
            return account
    except Exception as e:
        log.warning("boto3 sts.get_caller_identity failed: %s", e)
    try:
        out = subprocess.check_output(["aws", "sts", "get-caller-identity", "--query", "Account", "--output", "text"], stderr=subprocess.DEVNULL)
        account = out.decode().strip()
        if account:
            log.info("Retrieved AWS account id via aws CLI: %s", account)
            return account
    except Exception as e:
        log.warning("aws CLI get-caller-identity failed: %s", e)
    log.error("Unable to determine AWS account id. Ensure AWS credentials or aws CLI available.")
    sys.exit(1)

def ensure_bucket(bucket_name, region=None):
    try:
        import boto3
        s3 = boto3.client("s3", region_name=region) if region else boto3.client("s3")
        try:
            s3.head_bucket(Bucket=bucket_name)
            log.info("S3 bucket exists and is accessible: %s", bucket_name)
            return
        except Exception as e:
            log.info("Bucket %s not present or not accessible: %s", bucket_name, e)
        create_kwargs = {"Bucket": bucket_name}
        if region and region != "us-east-1":
            create_kwargs["CreateBucketConfiguration"] = {"LocationConstraint": region}
        s3.create_bucket(**create_kwargs)
        log.info("Created bucket: %s in region %s", bucket_name, region)
    except Exception as e:
        log.exception("Failed to ensure bucket %s: %s", bucket_name, e)
        log.error("Check IAM permissions (s3:CreateBucket) or create the bucket manually and re-run.")
        sys.exit(1)

def download_dataset_kaggle(dataset_ref, target_dir):
    try:
        from kaggle.api.kaggle_api_extended import KaggleApi
    except Exception as e:
        log.exception("kaggle package not installed: %s", e)
        log.error("Install with: pip install kaggle==2.0.0")
        sys.exit(1)
    api = KaggleApi()
    api.authenticate()
    if target_dir.exists():
        log.info("Clearing existing directory %s", target_dir)
        shutil.rmtree(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    log.info("Downloading dataset %s -> %s", dataset_ref, target_dir)
    try:
        api.dataset_download_files(dataset_ref, path=str(target_dir), unzip=True, quiet=False)
        log.info("Downloaded dataset %s", dataset_ref)
        return True
    except Exception as e:
        log.warning("Dataset download failed for %s: %s", dataset_ref, e)
        return False

def preview_csv(csv_path, nrows=2):
    try:
        import pandas as pd
    except Exception as e:
        log.exception("pandas not installed: %s", e)
        log.error("Install with: pip install pandas==2.3.3")
        sys.exit(1)
    log.info("Previewing %s", csv_path)
    try:
        df = pd.read_csv(csv_path, nrows=nrows)
        log.info("First %d rows of %s:\n%s", nrows, csv_path.name, df.head(nrows).to_string(index=False))
        log.info("Dtypes for %s:\n%s", csv_path.name, df.dtypes.astype(str).to_string())
    except Exception as e:
        log.exception("Failed to preview %s: %s", csv_path, e)

def upload_to_s3(local_path, bucket, prefix, short):
    try:
        import boto3
    except Exception as e:
        log.exception("boto3 not installed: %s", e)
        log.error("Install with: pip install boto3")
        sys.exit(1)
    s3 = boto3.client("s3")
    key = f"{prefix}/raw/{short}/{local_path.name}"
    log.info("Uploading %s -> s3://%s/%s", local_path, bucket, key)
    try:
        s3.upload_file(str(local_path), bucket, key)
    except Exception as e:
        log.exception("S3 upload failed for %s: %s", local_path, e)
        log.error("Check IAM policy: ensure s3:PutObject, s3:AbortMultipartUpload, s3:ListMultipartUploadParts on arn:aws:s3:::%s/*", bucket)
        sys.exit(1)
    s3uri = f"s3://{bucket}/{key}"
    log.info("Uploaded to %s", s3uri)
    return s3uri

def try_pyiceberg_append(csv_path):
    if not PYICEBERG_CATALOG:
        log.info("PYICEBERG_CATALOG not set; skipping PyIceberg append")
        return
    try:
        import pandas as pd
        import pyarrow as pa
        from pyiceberg.catalog import load_catalog
    except Exception as e:
        log.warning("PyIceberg or deps not installed/configured: %s", e)
        return
    try:
        catalog = load_catalog(PYICEBERG_CATALOG)
    except Exception as e:
        log.exception("Failed to load PyIceberg catalog '%s': %s", PYICEBERG_CATALOG, e)
        return
    try:
        df = pd.read_csv(csv_path)
        pa_table = pa.Table.from_pandas(df)
        identifier = f"{PYICEBERG_NAMESPACE}.{csv_path.stem.replace('-', '_').replace('.', '_')}"
        try:
            tbl = catalog.load_table(identifier)
            log.info("Loaded existing Iceberg table %s", identifier)
        except Exception:
            log.info("Creating Iceberg table %s using Arrow schema", identifier)
            try:
                tbl = catalog.create_table(identifier, schema=pa_table.schema)
                log.info("Created Iceberg table %s", identifier)
            except Exception as e:
                log.exception("Catalog create_table failed: %s", e)
                return
        log.info("Appending %d rows to Iceberg table %s", pa_table.num_rows, identifier)
        tbl.append(pa_table)
        snap = getattr(tbl.metadata, "current_snapshot_id", None)
        log.info("Append finished. snapshot_id=%s", snap)
    except Exception as e:
        log.exception("PyIceberg append failed for %s: %s", csv_path, e)

def assert_dataset_list(dlist):
    ok = all(isinstance(x, tuple) and len(x) >= 2 for x in dlist)
    if not ok:
        log.error("DATASETS must be a list of tuples: (dataset_ref, shortname)")
        sys.exit(1)

def main():
    assert_dataset_list(DATASETS)
    ensure_kaggle_credentials()
    account_id = get_aws_account_id()
    bucket_name = f"e2e-mlops-data-{account_id}"
    ensure_bucket(bucket_name, region=AWS_REGION)
    downloaded = []
    for dataset_ref, short in DATASETS:
        target = DATA_DIR / short
        ok = download_dataset_kaggle(dataset_ref, target)
        if not ok:
            log.warning("Failed to download %s; skipping", dataset_ref)
            continue
        csvs = list(target.glob("*.csv"))
        if not csvs:
            csvs = list(target.rglob("*.csv"))
        if not csvs:
            log.warning("No CSVs found under %s after download; skipping", target)
            continue
        for csv in csvs:
            preview_csv(csv, nrows=2)
            s3uri = upload_to_s3(csv, bucket_name, S3_PREFIX, short)
            downloaded.append((csv, s3uri))
            try_pyiceberg_append(csv)
    if not downloaded:
        log.error("No files downloaded/uploaded. Exiting.")
        sys.exit(1)
    log.info("Uploaded %d files to s3://%s/%s/raw/", len(downloaded), bucket_name, S3_PREFIX)
    log.info("Completed at %s", datetime.utcnow().isoformat())

if __name__ == "__main__":
    main()