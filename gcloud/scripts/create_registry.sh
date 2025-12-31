#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}" 
: "${REGION:?Set REGION}" 
: "${AR_REPO:?Set AR_REPO}" 

if ! gcloud artifacts repositories describe "$AR_REPO" --location "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$AR_REPO" \
    --project "$PROJECT_ID" \
    --location "$REGION" \
    --repository-format docker \
    --description "Neurobridge images"
else
  echo "Artifact Registry repo $AR_REPO already exists in $REGION."
fi
