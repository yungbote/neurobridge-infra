#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}" 
: "${REGION:?Set REGION}" 
: "${AR_REPO:?Set AR_REPO}" 

PLATFORM="${PLATFORM:-linux/amd64}"

VITE_API_BASE_URL="${VITE_API_BASE_URL:-/api}"
VITE_GOOGLE_OIDC_CLIENT_ID="${VITE_GOOGLE_OIDC_CLIENT_ID:-}"
VITE_GOOGLE_CLIENT_ID="${VITE_GOOGLE_CLIENT_ID:-}"
VITE_APPLE_OIDC_CLIENT_ID="${VITE_APPLE_OIDC_CLIENT_ID:-}"
VITE_APPLE_CLIENT_ID="${VITE_APPLE_CLIENT_ID:-}"
VITE_APPLE_REDIRECT_URI="${VITE_APPLE_REDIRECT_URI:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd)"

IMAGE_TAG="${IMAGE_TAG:-}"
if [ -z "$IMAGE_TAG" ]; then
  IMAGE_TAG="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "local")"
fi

IMAGE_BACKEND="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/neurobridge-backend:${IMAGE_TAG}"
IMAGE_WORKER="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/neurobridge-worker:${IMAGE_TAG}"
IMAGE_FRONTEND="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/neurobridge-frontend:${IMAGE_TAG}"

gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

BACKEND_DIR="$ROOT_DIR/neurobridge-backend"
FRONTEND_DIR="$ROOT_DIR/neurobridge-frontend"

DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" -t "$IMAGE_BACKEND" -f "$BACKEND_DIR/Dockerfile" "$BACKEND_DIR"
DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" -t "$IMAGE_WORKER" -f "$BACKEND_DIR/Dockerfile.worker" "$BACKEND_DIR"
DOCKER_BUILDKIT=1 docker build --platform "$PLATFORM" -t "$IMAGE_FRONTEND" -f "$FRONTEND_DIR/Dockerfile" \
  --build-arg VITE_API_BASE_URL="$VITE_API_BASE_URL" \
  --build-arg VITE_GOOGLE_OIDC_CLIENT_ID="$VITE_GOOGLE_OIDC_CLIENT_ID" \
  --build-arg VITE_GOOGLE_CLIENT_ID="$VITE_GOOGLE_CLIENT_ID" \
  --build-arg VITE_APPLE_OIDC_CLIENT_ID="$VITE_APPLE_OIDC_CLIENT_ID" \
  --build-arg VITE_APPLE_CLIENT_ID="$VITE_APPLE_CLIENT_ID" \
  --build-arg VITE_APPLE_REDIRECT_URI="$VITE_APPLE_REDIRECT_URI" \
  "$FRONTEND_DIR"

docker push "$IMAGE_BACKEND"
docker push "$IMAGE_WORKER"
docker push "$IMAGE_FRONTEND"

echo "Pushed:\n  $IMAGE_BACKEND\n  $IMAGE_WORKER\n  $IMAGE_FRONTEND"
