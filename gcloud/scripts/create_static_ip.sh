#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}" 
: "${REGION:?Set REGION}" 

STATIC_IP_NAME="${STATIC_IP_NAME:-neurobridge-ip}"

if ! gcloud compute addresses describe "$STATIC_IP_NAME" --global --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute addresses create "$STATIC_IP_NAME" --global --project "$PROJECT_ID"
else
  echo "Static IP $STATIC_IP_NAME already exists."
fi

IP_ADDRESS="$(gcloud compute addresses describe "$STATIC_IP_NAME" --global --project "$PROJECT_ID" --format='get(address)')"

echo "Reserved global IP: $IP_ADDRESS"
