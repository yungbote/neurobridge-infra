#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}" 
: "${REGION:?Set REGION}" 
: "${CLUSTER_NAME:?Set CLUSTER_NAME}" 
: "${AR_REPO:?Set AR_REPO}" 

DEPLOY_TEMPORAL="${DEPLOY_TEMPORAL:-true}"
DEPLOY_TEMPORAL_UI="${DEPLOY_TEMPORAL_UI:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GCLOUD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-}"
if [ -z "$IMAGE_TAG" ]; then
  IMAGE_TAG="$(git -C "$GCLOUD_DIR/../.." rev-parse --short HEAD 2>/dev/null || echo "local")"
fi

IMAGE_BACKEND="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/neurobridge-backend:${IMAGE_TAG}"
IMAGE_WORKER="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/neurobridge-worker:${IMAGE_TAG}"
IMAGE_FRONTEND="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/neurobridge-frontend:${IMAGE_TAG}"

ZONE="${ZONE:-}"
LOCATION_FLAG=(--region "$REGION")
LOCATION_LABEL="$REGION"
if [ -n "$ZONE" ]; then
  LOCATION_FLAG=(--zone "$ZONE")
  LOCATION_LABEL="$ZONE"
fi

if [ -z "$ZONE" ]; then
  DETECTED_LOCATION="$(gcloud container clusters list --project "$PROJECT_ID" --format='value(name,location)' | awk -v name="$CLUSTER_NAME" '$1==name {print $2; exit}')"
  if [ -n "$DETECTED_LOCATION" ]; then
    if [[ "$DETECTED_LOCATION" == *"-"*"-"* ]]; then
      LOCATION_FLAG=(--zone "$DETECTED_LOCATION")
      LOCATION_LABEL="$DETECTED_LOCATION"
    else
      LOCATION_FLAG=(--region "$DETECTED_LOCATION")
      LOCATION_LABEL="$DETECTED_LOCATION"
    fi
  fi
fi

gcloud container clusters get-credentials "$CLUSTER_NAME" "${LOCATION_FLAG[@]}" --project "$PROJECT_ID"

kubectl apply -f "$GCLOUD_DIR/k8s/namespace.yaml"

if ! kubectl -n neurobridge get secret gcp-sa >/dev/null 2>&1; then
  echo "Missing secret neurobridge/gcp-sa. Create it with:" >&2
  echo "  kubectl -n neurobridge create secret generic gcp-sa --from-file=gcp_sa.json=/path/to/gcp_sa.json" >&2
  exit 1
fi

kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/configmap.yaml"

kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/frontend-config.yaml"
kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/managed-certificate.yaml"

if kubectl get crd secretstores.external-secrets.io >/dev/null 2>&1 && kubectl get crd externalsecrets.external-secrets.io >/dev/null 2>&1; then
  STORE_VERSIONS="$(kubectl get crd secretstores.external-secrets.io -o jsonpath='{.spec.versions[*].name}' 2>/dev/null || true)"
  SECRET_VERSIONS="$(kubectl get crd externalsecrets.external-secrets.io -o jsonpath='{.spec.versions[*].name}' 2>/dev/null || true)"
  if echo "$STORE_VERSIONS" | grep -q 'v1' && echo "$SECRET_VERSIONS" | grep -q 'v1'; then
kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/secret-store.yaml"
  kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/external-secret.yaml"
  else
    echo "External Secrets CRDs missing v1; run ./scripts/install_external_secrets.sh."
  fi
else
  echo "External Secrets CRDs not found; run ./scripts/install_external_secrets.sh."
fi

if ! kubectl -n neurobridge get secret neurobridge-secrets >/dev/null 2>&1; then
  echo "Waiting for secret neurobridge/neurobridge-secrets (from External Secrets)..." >&2
  for _ in $(seq 1 60); do
    if kubectl -n neurobridge get secret neurobridge-secrets >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
fi
if ! kubectl -n neurobridge get secret neurobridge-secrets >/dev/null 2>&1; then
  echo "Missing secret neurobridge/neurobridge-secrets. Ensure External Secrets is installed and secrets are synced:" >&2
  echo "  cp secrets.env.example secrets.env" >&2
  echo "  ./scripts/sync_secrets_to_gsm.sh" >&2
  exit 1
fi

kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/backend-api-backendconfig.yaml"

if [ "$DEPLOY_TEMPORAL" = "true" ]; then
  if ! kubectl -n neurobridge get secret neurobridge-secrets -o jsonpath='{.data.TEMPORAL_POSTGRES_PASSWORD}' 2>/dev/null | grep -q .; then
    echo "Missing secret key TEMPORAL_POSTGRES_PASSWORD in neurobridge/neurobridge-secrets." >&2
    echo "Set it in secrets.env, then re-run ./scripts/sync_secrets_to_gsm.sh" >&2
    exit 1
  fi

  kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/temporal-postgres.yaml"
  kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/temporal.yaml"
  if [ "$DEPLOY_TEMPORAL_UI" = "true" ]; then
    kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/temporal-ui.yaml"
  fi

  kubectl -n neurobridge rollout status deploy/temporal-postgres --timeout=5m
  kubectl -n neurobridge rollout status deploy/temporal --timeout=5m
  if [ "$DEPLOY_TEMPORAL_UI" = "true" ]; then
    kubectl -n neurobridge rollout status deploy/temporal-ui --timeout=5m
  fi
fi

sed "s|{{IMAGE_BACKEND}}|$IMAGE_BACKEND|g" "$GCLOUD_DIR/k8s/backend-api.yaml" | kubectl -n neurobridge apply -f -
sed "s|{{IMAGE_WORKER}}|$IMAGE_WORKER|g" "$GCLOUD_DIR/k8s/backend-worker.yaml" | kubectl -n neurobridge apply -f -
sed "s|{{IMAGE_FRONTEND}}|$IMAGE_FRONTEND|g" "$GCLOUD_DIR/k8s/frontend.yaml" | kubectl -n neurobridge apply -f -

kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/backend-api-service.yaml"
kubectl -n neurobridge apply -f "$GCLOUD_DIR/k8s/ingress.yaml"

echo "Deployed backend API, workers, frontend, and ingress to $CLUSTER_NAME in $LOCATION_LABEL."
