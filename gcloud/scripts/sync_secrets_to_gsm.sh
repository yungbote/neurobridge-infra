#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_ID:?Set PROJECT_ID}" 

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GCLOUD_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SECRETS_ENV="${SECRETS_ENV:-$GCLOUD_DIR/secrets.env}"
SECRET_STORE="${SECRET_STORE:-$GCLOUD_DIR/k8s/secret-store.yaml}"

if [ ! -f "$SECRETS_ENV" ]; then
  echo "Missing $SECRETS_ENV. Create it first (copy from secrets.env.example)." >&2
  exit 1
fi

# Enable API if needed.
gcloud services enable secretmanager.googleapis.com --project "$PROJECT_ID"

# Push secrets to GSM.
while IFS= read -r raw; do
  line="${raw%%#*}"
  line="${line%$'\r'}"
  line="${line%%$'\n'}"
  [ -z "${line// }" ] && continue
  if [[ "$line" != *"="* ]]; then
    continue
  fi
  key="${line%%=*}"
  value="${line#*=}"
  if [ -z "$key" ]; then
    continue
  fi
  if [ -z "$value" ]; then
    echo "Skipping empty secret: $key"
    continue
  fi
  if ! gcloud secrets describe "$key" --project "$PROJECT_ID" >/dev/null 2>&1; then
    gcloud secrets create "$key" --project "$PROJECT_ID" --replication-policy=automatic
  fi
  printf '%s' "$value" | gcloud secrets versions add "$key" --project "$PROJECT_ID" --data-file=-
  echo "Updated secret: $key"
  
  done < "$SECRETS_ENV"

# Patch SecretStore project ID.
python - <<PY
from pathlib import Path

store = Path("$SECRET_STORE")
if store.exists():
    lines = store.read_text().splitlines()
    out = []
    for line in lines:
        if line.strip().startswith('projectID:'):
            indent = line[:len(line) - len(line.lstrip())]
            out.append(f"{indent}projectID: \"$PROJECT_ID\"")
        else:
            out.append(line)
    store.write_text("\n".join(out) + "\n")
PY

echo "Secret Manager sync complete."
