#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}" 
: "${REGION:?Set REGION}" 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GCLOUD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SQL_INSTANCE="${SQL_INSTANCE:-neurobridge-postgres}"
SQL_VERSION="${SQL_VERSION:-POSTGRES_16}"
SQL_TIER="${SQL_TIER:-db-custom-2-7680}"
SQL_STORAGE_GB="${SQL_STORAGE_GB:-100}"
SQL_AVAILABILITY_TYPE="${SQL_AVAILABILITY_TYPE:-REGIONAL}"
SQL_EDITION="${SQL_EDITION:-ENTERPRISE}"
POSTGRES_USER="${POSTGRES_USER:-neurobridge}"
POSTGRES_NAME="${POSTGRES_NAME:-neurobridge}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"

REDIS_INSTANCE="${REDIS_INSTANCE:-neurobridge-redis}"
REDIS_TIER="${REDIS_TIER:-STANDARD}"
REDIS_SIZE_GB="${REDIS_SIZE_GB:-5}"
REDIS_VERSION="${REDIS_VERSION:-redis_7_0}"

SECRETS_ENV="$GCLOUD_DIR/secrets.env"
SECRETS_EXAMPLE="$GCLOUD_DIR/secrets.env.example"
CONFIGMAP="$GCLOUD_DIR/k8s/configmap.yaml"

if [ -z "$POSTGRES_PASSWORD" ] && [ -f "$SECRETS_ENV" ]; then
  POSTGRES_PASSWORD="$(grep -E '^POSTGRES_PASSWORD=' "$SECRETS_ENV" | head -n1 | cut -d= -f2-)"
fi
if [ -z "$POSTGRES_PASSWORD" ]; then
  echo "POSTGRES_PASSWORD is required. Set it in env or $SECRETS_ENV" >&2
  exit 1
fi

# Enable APIs if needed.
gcloud services enable sqladmin.googleapis.com redis.googleapis.com --project "$PROJECT_ID"

# Cloud SQL instance.
if ! gcloud sql instances describe "$SQL_INSTANCE" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud sql instances create "$SQL_INSTANCE" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --database-version "$SQL_VERSION" \
    --tier "$SQL_TIER" \
    --storage-size "$SQL_STORAGE_GB" \
    --storage-auto-increase \
    --availability-type "$SQL_AVAILABILITY_TYPE" \
    --edition "$SQL_EDITION"
else
  echo "Cloud SQL instance $SQL_INSTANCE already exists."
fi

# Database.
if ! gcloud sql databases list --instance "$SQL_INSTANCE" --project "$PROJECT_ID" --format='value(name)' | grep -qx "$POSTGRES_NAME"; then
  gcloud sql databases create "$POSTGRES_NAME" --instance "$SQL_INSTANCE" --project "$PROJECT_ID"
else
  echo "Database $POSTGRES_NAME already exists."
fi

# User + password.
if ! gcloud sql users list --instance "$SQL_INSTANCE" --project "$PROJECT_ID" --format='value(name)' | grep -qx "$POSTGRES_USER"; then
  gcloud sql users create "$POSTGRES_USER" --instance "$SQL_INSTANCE" --project "$PROJECT_ID" --password "$POSTGRES_PASSWORD"
else
  gcloud sql users set-password "$POSTGRES_USER" --instance "$SQL_INSTANCE" --project "$PROJECT_ID" --password "$POSTGRES_PASSWORD"
fi

CLOUD_SQL_CONNECTION_NAME="$(gcloud sql instances describe "$SQL_INSTANCE" --project "$PROJECT_ID" --format='get(connectionName)')"

# Memorystore (Redis).
if ! gcloud redis instances describe "$REDIS_INSTANCE" --region "$REGION" --project "$PROJECT_ID" >/dev/null 2>&1; then
  gcloud redis instances create "$REDIS_INSTANCE" \
    --project "$PROJECT_ID" \
    --region "$REGION" \
    --tier "$REDIS_TIER" \
    --size "$REDIS_SIZE_GB" \
    --redis-version "$REDIS_VERSION"
else
  echo "Redis instance $REDIS_INSTANCE already exists."
fi

REDIS_HOST="$(gcloud redis instances describe "$REDIS_INSTANCE" --region "$REGION" --project "$PROJECT_ID" --format='get(host)')"
REDIS_PORT="$(gcloud redis instances describe "$REDIS_INSTANCE" --region "$REGION" --project "$PROJECT_ID" --format='get(port)')"
REDIS_ADDR="${REDIS_HOST}:${REDIS_PORT}"

# Export for the Python updater.
export CLOUD_SQL_CONNECTION_NAME
export REDIS_ADDR
export POSTGRES_USER
export POSTGRES_NAME
export POSTGRES_PASSWORD

# Ensure secrets.env exists.
if [ ! -f "$SECRETS_ENV" ]; then
  cp "$SECRETS_EXAMPLE" "$SECRETS_ENV"
fi

python - <<PY
import os
from pathlib import Path

configmap = Path("$CONFIGMAP")
secrets_env = Path("$SECRETS_ENV")

updates = {
    "CLOUD_SQL_CONNECTION_NAME": os.environ["CLOUD_SQL_CONNECTION_NAME"],
    "REDIS_ADDR": os.environ["REDIS_ADDR"],
    "POSTGRES_USER": os.environ["POSTGRES_USER"],
    "POSTGRES_NAME": os.environ["POSTGRES_NAME"],
}

lines = configmap.read_text().splitlines()
out = []
for line in lines:
    stripped = line.lstrip()
    indent = line[:len(line) - len(stripped)]
    if ":" in stripped:
        key = stripped.split(":", 1)[0].strip()
        if key in updates:
            out.append(f"{indent}{key}: \"{updates[key]}\"")
            continue
    out.append(line)
configmap.write_text("\n".join(out) + "\n")

# Update POSTGRES_PASSWORD in secrets.env.
secrets_lines = secrets_env.read_text().splitlines()
updated = False
out = []
for line in secrets_lines:
    if line.startswith("POSTGRES_PASSWORD="):
        out.append(f"POSTGRES_PASSWORD={os.environ['POSTGRES_PASSWORD']}")
        updated = True
    else:
        out.append(line)
if not updated:
    out.append(f"POSTGRES_PASSWORD={os.environ['POSTGRES_PASSWORD']}")
secrets_env.write_text("\n".join(out) + "\n")
PY

echo "Updated configmap and secrets.env with managed service endpoints."
echo "CLOUD_SQL_CONNECTION_NAME=$CLOUD_SQL_CONNECTION_NAME"
echo "REDIS_ADDR=$REDIS_ADDR"
