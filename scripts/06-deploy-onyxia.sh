#!/usr/bin/env bash
set -euo pipefail
# Renders prod values from .env and deploys Onyxia via Helm.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

mkdir -p "${ROOT_DIR}/values/rendered"
envsubst < "${ROOT_DIR}/values/values-prod.tmpl.yaml" > "${ROOT_DIR}/values/rendered/values-prod.yaml"

helm upgrade --install onyxia onyxia/onyxia \
  -n "${NAMESPACE}" --create-namespace \
  -f "${ROOT_DIR}/values/values-base.yaml" \
  -f "${ROOT_DIR}/values/rendered/values-prod.yaml" \
  --wait

echo "Onyxia deployed. Open: https://${ONYXIA_HOST}"
