#!/usr/bin/env bash
set -euo pipefail
# Cleans the installed components without deleting the whole GCP project.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

echo "Cleaning Onyxia..."
helm uninstall onyxia -n "${NAMESPACE}" || true
kubectl delete ns "${NAMESPACE}" --wait=false || true

echo "Cleaning ingress-nginx..."
helm uninstall ingress-nginx -n "${NGINX_NS}" || true
kubectl -n "${NGINX_NS}" delete certificate "${WILDCARD_SECRET}" 2>/dev/null || true
kubectl -n "${NGINX_NS}" delete secret "${WILDCARD_SECRET}" 2>/dev/null || true
kubectl delete ns "${NGINX_NS}" --wait=false || true

echo "Cleaning cert-manager..."
helm uninstall cert-manager -n "${CM_NS}" || true
kubectl delete clusterissuer letsencrypt-prod-dns01 2>/dev/null || true
kubectl delete crd \
  certificates.cert-manager.io \
  certificaterequests.cert-manager.io \
  clusterissuers.cert-manager.io \
  issuers.cert-manager.io \
  orders.acme.cert-manager.io \
  challenges.acme.cert-manager.io 2>/dev/null || true

echo "Removing Workload Identity and IAM bindings..."
kubectl -n "${CM_NS}" annotate serviceaccount cert-manager \
  "iam.gke.io/gcp-service-account-" --overwrite 2>/dev/null || true

gcloud iam service-accounts remove-iam-policy-binding \
  "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${CM_NS}/cert-manager]" >/dev/null || true

gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/dns.admin" >/dev/null || true

gcloud iam service-accounts delete \
  "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --quiet || true

echo "DNS A records can be removed in the Cloud DNS sub-zone if desired (NS delegation stays in parent)."
echo "Cleanup complete."
