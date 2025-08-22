#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source .env
source .state

REGION="${REGION:-europe-north1}"
CLUSTER_NAME="${CLUSTER_NAME:-onyxia-poc}"
NAMESPACE="${NAMESPACE:-default}"
HELM_CHART_REPO="${HELM_CHART_REPO:-https://inseefrlab.github.io/helm-charts}"

gcloud config set core/project "${PROJECT_ID}" >/dev/null
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}"

helm repo add onyxia "${HELM_CHART_REPO}" >/dev/null 2>&1 || true
helm repo update >/dev/null

mkdir -p rendered
# Render values from template (envsubst expects ${VAR} in template)
if [[ -f values/values-prod.tmpl.yaml ]]; then
  DNS_DOMAIN="${DNS_DOMAIN}" ONYXIA_HOST="${ONYXIA_HOST}" \
  CATALOG_URL="${CATALOG_URL}" CUSTOM_RESOURCES_URL="${CUSTOM_RESOURCES_URL}" \
  envsubst < values/values-prod.tmpl.yaml > rendered/values-prod.yaml
  VALUES_FILES=(-f values/values-base.yaml -f rendered/values-prod.yaml)
else
  VALUES_FILES=(-f values/values-base.yaml)
fi

kubectl create ns "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

helm upgrade --install onyxia onyxia/onyxia -n "${NAMESPACE}" "${VALUES_FILES[@]}"

echo
echo "Onyxia deployed (or updated)."
echo "URL: https://${ONYXIA_HOST}"
