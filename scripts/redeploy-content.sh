#!/usr/bin/env bash
set -euo pipefail
# Forces the Onyxia web deployment to reload UI content and catalog URLs.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

# Option 1: restart only the web (fast)
kubectl -n "${NAMESPACE}" rollout restart deploy onyxia-web || true

# Option 2: full helm upgrade (uncomment if preferred)
# envsubst < "${ROOT_DIR}/values/values-prod.tmpl.yaml" > "${ROOT_DIR}/values/rendered/values-prod.yaml"
# helm upgrade --install onyxia onyxia/onyxia \
#   -n "${NAMESPACE}" \
#   -f "${ROOT_DIR}/values/values-base.yaml" \
#   -f "${ROOT_DIR}/values/rendered/values-prod.yaml" \
#   --wait
