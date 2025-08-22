#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .state ]]; then
  echo "No .state file found; cleanup cannot proceed safely."
  exit 1
fi
# shellcheck disable=SC1091
source .state

REGION="${REGION:-europe-north1}"
CLUSTER_NAME="${CLUSTER_NAME:-onyxia-poc}"
NAMESPACE="${NAMESPACE:-default}"
GSA_NAME="cm-dns01-solver"
CM_NS="cert-manager"
NGINX_NS="ingress-nginx"

echo "-> Setting project context: ${PROJECT_ID}"
gcloud config set core/project "${PROJECT_ID}" >/dev/null || true

echo "-> Attempting to connect to cluster (may already be gone)..."
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" || true

echo "-> Deleting Helm releases (ignore errors if already removed)"
helm -n "${NAMESPACE}" uninstall onyxia || true
helm -n "${CM_NS}" uninstall cert-manager || true
helm -n "${NGINX_NS}" uninstall ingress-nginx || true

echo "-> Deleting namespaces (best-effort)"
kubectl delete ns "${NAMESPACE}" --ignore-not-found=true || true
kubectl delete ns "${CM_NS}" --ignore-not-found=true || true
kubectl delete ns "${NGINX_NS}" --ignore-not-found=true || true

echo "-> Deleting Cloud DNS records and zone"
if gcloud dns managed-zones describe "${ZONE_NAME}" >/dev/null 2>&1; then
  # Delete all A records we created
  for name in "${ONYXIA_HOST}" "*.${DNS_DOMAIN}" "*.user.${DNS_DOMAIN}"; do
    existing="$(gcloud dns record-sets list -z "${ZONE_NAME}" --name="${name}." --type=A --format='value(rrdatas[0])' || true)"
    if [[ -n "${existing}" ]]; then
      gcloud dns record-sets transaction start -z "${ZONE_NAME}" >/dev/null 2>&1 || true
      gcloud dns record-sets transaction remove -z "${ZONE_NAME}" --name="${name}." --type=A --ttl=300 "${existing}" || true
      gcloud dns record-sets transaction execute -z "${ZONE_NAME}" >/dev/null 2>&1 || true
    fi
  done
  # Finally delete the zone (must keep SOA/NS so it will succeed)
  gcloud dns managed-zones delete "${ZONE_NAME}" --quiet || true
fi

echo "-> Deleting GKE cluster"
gcloud container clusters delete "${CLUSTER_NAME}" --region "${REGION}" --quiet || true

echo "-> Removing IAM bindings and service account"
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --role roles/dns.admin \
  --member "serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet || true

gcloud iam service-accounts delete "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet || true

echo "-> Deleting project (this may take a while)"
gcloud projects delete "${PROJECT_ID}" --quiet || true

echo "Cleanup complete."
