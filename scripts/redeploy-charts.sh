#!/usr/bin/env bash
set -euo pipefail
# After publishing updated charts to GitHub Pages, force Onyxia web to refresh.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

kubectl -n "${NAMESPACE}" rollout restart deploy onyxia-web || true
echo "Restarted onyxia-web to refresh catalog from: ${CATALOG_URL}"
