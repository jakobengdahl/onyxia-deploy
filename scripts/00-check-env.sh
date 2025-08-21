#!/usr/bin/env bash
set -euo pipefail

# Loads .env and validates required variables, then sets GCP context and fetches kube credentials.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  set -a; # export all
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/.env"
  set +a
else
  echo "ERROR: .env not found at ${ROOT_DIR}/.env"
  exit 1
fi

REQUIRED_VARS=(
  PROJECT_ID REGION CLUSTER_NAME
  NAMESPACE ONYXIA_HOST
  DNS_DOMAIN ZONE_NAME ACME_EMAIL
  GSA_NAME NGINX_NS CM_NS WILDCARD_SECRET
  CATALOG_URL CUSTOM_RESOURCES_URL
)

missing=0
for v in "${REQUIRED_VARS[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: Missing env var: ${v}"
    missing=1
  fi
done
(( missing == 0 )) || exit 1

echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo "Domain:  ${DNS_DOMAIN}"
echo "NS/CM:   ${NGINX_NS}/${CM_NS}"

gcloud config set project "${PROJECT_ID}" >/dev/null
gcloud config set compute/region "${REGION}" >/dev/null
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

echo "Env check & context OK."
