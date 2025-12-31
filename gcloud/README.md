# Neurobridge on GKE

This folder contains a minimal GKE setup for running the backend API + workers on Google Cloud.
It keeps Postgres and Redis inside the cluster for simplicity. Swap them for Cloud SQL and
Memorystore when you want managed services.

## Prereqs
- gcloud CLI + kubectl
- Helm
- Docker
- A GCP project with billing enabled

## Quick start
1) Set vars:
```
PROJECT_ID="your-project"
REGION="us-central1"
CLUSTER_NAME="neurobridge"
AR_REPO="neurobridge"
IMAGE_TAG="$(git rev-parse --short HEAD)"
VITE_API_BASE_URL="/api"
STATIC_IP_NAME="neurobridge-ip"

# Optional (if using OAuth in the frontend)
# VITE_GOOGLE_OIDC_CLIENT_ID=""
# VITE_GOOGLE_CLIENT_ID=""
# VITE_APPLE_OIDC_CLIENT_ID=""
# VITE_APPLE_CLIENT_ID=""
# VITE_APPLE_REDIRECT_URI=""
```

2) Create cluster + registry:
```
./scripts/create_cluster.sh
./scripts/create_registry.sh
```
If you want to stay within low quotas, set a zone and smaller disks, for example:
```
export ZONE="us-central1-a"
export NODE_COUNT=2
export MACHINE_TYPE="e2-standard-4"
export DISK_SIZE_GB=100
export DISK_TYPE="pd-balanced"
export MIN_NODES=1
export MAX_NODES=2
./scripts/create_cluster.sh
```

3) Reserve a global static IP:
```
./scripts/create_static_ip.sh
```

4) Create managed data services:
```
export POSTGRES_PASSWORD="your-strong-password"
./scripts/create_managed_data.sh
```

5) Update domains:
Edit `k8s/managed-certificate.yaml` and `k8s/ingress.yaml` with your domain(s).

6) Build + push images:
```
./scripts/build_push.sh
```
For the single LB setup, set `VITE_API_BASE_URL="/api"`.
On Apple Silicon, this script builds `linux/amd64` images by default. Override with `PLATFORM=linux/arm64` if needed.

7) Install External Secrets Operator:
```
./scripts/install_external_secrets.sh
```

8) Sync secrets to Google Secret Manager:
```
cp secrets.env.example secrets.env
./scripts/sync_secrets_to_gsm.sh
```

9) Create the GCP service account secret (used by workloads + External Secrets):
```
kubectl create namespace neurobridge
kubectl -n neurobridge create secret generic gcp-sa --from-file=gcp_sa.json=/path/to/gcp_sa.json
```

10) Deploy:
```
export ZONE="us-central1-a" # if you created a zonal cluster
./scripts/deploy.sh
```

11) Get the external IP (use this for DNS A records):
```
gcloud compute addresses describe neurobridge-ip --global --format='get(address)'
```

12) Point your domain at the static IP:
- Create A records for `@` and `www` to the static IP.

13) Wait for the cert to go Active:
```
kubectl -n neurobridge describe managedcertificate neurobridge-cert
```

## Managed services config
- The `./scripts/create_managed_data.sh` script creates Cloud SQL + Memorystore and updates
  `k8s/configmap.yaml` and `secrets.env` automatically.
- Optional overrides: `SQL_INSTANCE`, `SQL_VERSION`, `SQL_TIER`, `SQL_STORAGE_GB`, `POSTGRES_USER`, `POSTGRES_NAME`,
  `SQL_AVAILABILITY_TYPE`, `SQL_EDITION`, `REDIS_INSTANCE`, `REDIS_TIER`, `REDIS_SIZE_GB`, `REDIS_VERSION`.
- Cloud SQL:
  - Set `CLOUD_SQL_CONNECTION_NAME` in `k8s/configmap.yaml` (format: `project:region:instance`).
  - Set `POSTGRES_USER` / `POSTGRES_NAME` in `k8s/configmap.yaml`.
  - Set `POSTGRES_PASSWORD` in `secrets.env`.
  - Ensure the GCP service account in `gcp_sa.json` has the `Cloud SQL Client` role.
- Memorystore:
  - Set `REDIS_ADDR` in `k8s/configmap.yaml` to the Redis instance IP and port (example: `10.0.0.5:6379`).
  - Ensure your GKE cluster and Memorystore are in the same VPC/network.
  - `REDIS_TIER` accepts `BASIC` or `STANDARD` (HA).

## Secret Manager sync
- `./scripts/sync_secrets_to_gsm.sh` updates Google Secret Manager from `secrets.env` and patches
  `k8s/secret-store.yaml` with your `PROJECT_ID`.
- The GCP service account in `gcp_sa.json` must have `Secret Manager Secret Accessor`.
- `k8s/secret-store.yaml` reads credentials from the `gcp-sa` secret (`gcp_sa.json` key).

## Next steps
1. Set `VITE_API_BASE_URL="/api"`, run `./scripts/build_push.sh`, then `./scripts/deploy.sh`.
2. The Ingress is included for single LB + `/api` routing; grab the IP from `gcloud compute addresses describe neurobridge-ip --global --format='get(address)'`.

## Files
- `k8s/` contains manifests for namespace, config, secret store, external secret, backend config, cert, frontend config, postgres, redis, api, workers, frontend, and ingress.
- `scripts/` contains helper scripts for GKE + image publishing + secret sync.
- `secrets.env.example` shows required secret keys.

## Notes
- The backend image is built from `neurobridge-backend/Dockerfile`.
- The worker image is built from `neurobridge-backend/Dockerfile.worker`.
- The frontend image is built from `neurobridge-frontend/Dockerfile`.
- `VITE_API_BASE_URL` is baked at build time; rebuild/push frontend if the backend URL changes.
- `backend-api` and `frontend` services are `NodePort` for the GCE Ingress to route traffic.
- Update `k8s/managed-certificate.yaml` with your domain before deploying.
- Update `k8s/ingress.yaml` hosts to match your domain(s).
- HTTPS redirect is enforced via `k8s/frontend-config.yaml`.
- If you change the static IP name, update `k8s/ingress.yaml` (`kubernetes.io/ingress.global-static-ip-name`).
- `k8s/postgres.yaml` and `k8s/redis.yaml` are kept for reference but are not applied by default.
- `k8s/postgres.yaml` and `k8s/redis.yaml` are for in-cluster use only; managed services are the default path here.
