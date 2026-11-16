#!/usr/bin/env bash
# =============================================================================
# Google Drive Backend Only — Provision GCP Service Accounts & JSON keys.
# Not required for local, SSH, S3, or MEGA backends.
# =============================================================================
set -euo pipefail

PROJECT_ID="${1:?Uso: $0 <GCP_PROJECT_ID> <NUM_SAS> [OUT_DIR]}"
COUNT="${2:?Uso: $0 <GCP_PROJECT_ID> <NUM_SAS> [OUT_DIR]}"
OUT_DIR="${3:-./configs/sa_keys}"

mkdir -p "$OUT_DIR"
gcloud services enable drive.googleapis.com --project="$PROJECT_ID"

for i in $(seq -w 1 "$COUNT"); do
  SA_NAME="vfs-sa-$i"
  SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
  if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
    gcloud iam service-accounts create "$SA_NAME" \
      --display-name="VFS Google Drive SA $i" \
      --project="$PROJECT_ID"
  fi
  gcloud iam service-accounts keys create "${OUT_DIR}/${SA_NAME}.json" \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID"
done

echo "Listo (Google Drive): $COUNT claves JSON guardadas en $OUT_DIR"
