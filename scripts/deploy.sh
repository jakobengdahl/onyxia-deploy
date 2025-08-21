#!/usr/bin/env bash
set -euo pipefail

# Load local env if present
if [[ -f ".env" ]]; then
  # shellcheck disable=SC1091
  source .env
fi

# Required
: "${ONYXIA_HOST:?Set ONYXIA_HOST}"
: "${CATALOG_URL:?Set CATALOG_URL}"
: "${CUSTOM_RESOURCES_URL:?Set CUSTOM_RESOURCES_URL}"

# Optional
: "${LOGO_LIGHT_URL:=}"
: "${LOGO_DARK_URL:=}"
: "${NAMESPACE:=default}"

# Chart source (override to your fork if you repackage the Onyxia chart)
: "${CHART_REPO:=https://inseefrlab.github.io/helm-charts}"
: "${CHART_NAME:=inseefrlab/onyxia}"

# Render prod values from template
if ! command -v envsubst >/dev/null 2>&1; then
  echo "ERROR: envsubst not found (install gettext-base or use Cloud Shell)." >&2
  exit 1
fi
ENV_VARS='${ONYXIA_HOST} ${CATALOG_URL} ${CUSTOM_RESOURCES_URL} ${LOGO_LIGHT_URL} ${LOGO_DARK_URL}'
envsubst "${ENV_VARS}" < values/values-prod.tmpl.yaml > values/values-prod.rendered.yaml

echo "== Rendered prod values =="
sed -n '1,200p' values/values-prod.rendered.yaml || true
echo "=========================="

# Deploy
helm repo add inseefrlab "${CHART_REPO}" >/dev/null || true
helm repo update >/dev/null

helm upgrade --install onyxia "${CHART_NAME}" \
  -n "${NAMESPACE}" --create-namespace \
  -f values/values-base.yaml \
  -f values/values-prod.rendered.yaml \
  --wait

echo "✅ Onyxia deployed at https://${ONYXIA_HOST}"
