#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}" 
: "${REGION:?Set REGION}" 
: "${CLUSTER_NAME:?Set CLUSTER_NAME}" 

ZONE="${ZONE:-}"
NODE_COUNT="${NODE_COUNT:-2}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
MIN_NODES="${MIN_NODES:-1}"
MAX_NODES="${MAX_NODES:-3}"
DISK_SIZE_GB="${DISK_SIZE_GB:-100}"
DISK_TYPE="${DISK_TYPE:-pd-balanced}"

LOCATION_FLAG=(--region "$REGION")
LOCATION_LABEL="$REGION"
if [ -n "$ZONE" ]; then
  LOCATION_FLAG=(--zone "$ZONE")
  LOCATION_LABEL="$ZONE"
fi

describe_args=(container clusters describe "$CLUSTER_NAME" "${LOCATION_FLAG[@]}" --project "$PROJECT_ID")
create_args=(container clusters create "$CLUSTER_NAME" "${LOCATION_FLAG[@]}" --project "$PROJECT_ID" \
  --num-nodes "$NODE_COUNT" \
  --machine-type "$MACHINE_TYPE" \
  --disk-size "$DISK_SIZE_GB" \
  --disk-type "$DISK_TYPE" \
  --enable-ip-alias \
  --enable-autoscaling \
  --min-nodes "$MIN_NODES" \
  --max-nodes "$MAX_NODES" \
  --release-channel regular)

if ! gcloud "${describe_args[@]}" >/dev/null 2>&1; then
  gcloud "${create_args[@]}"
else
  echo "Cluster $CLUSTER_NAME already exists in $LOCATION_LABEL."
fi
