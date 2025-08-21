#!/usr/bin/env bash
set -euo pipefail

# Optional flags (set in your shell before running):
#   CLEANUP_DELETE_DNS_ZONE=true   -> also delete the Cloud DNS managed zone
#   CLEANUP_DELETE_CLUSTER=true    -> also delete the GKE cluster
#   CLEANUP_DELETE_CRDS=true       -> also delete cert-manager CRDs

set -a; source .env; set +a

gcloud config set project "${PROJECT_ID}" >/dev/null
gcloud config set compute/region "${REGION}" >/dev/null || true

echo "== Uninstall Onyxia chart =="
helm -n "${NAMESPACE}" uninstall onyxia 2>/dev/null || true

echo "== Remove wildcard cert/secret (if any) =="
kubectl -n "${NGINX_NS}" delete certificate "${WILDCARD_SECRET}" --ignore-not-found
kubectl -n "${NGINX_NS}" delete secret "${WILDCARD_SECRET}" --ignore-not-found

echo "== Uninstall ingress-nginx =="
helm -n "${NGINX_NS}" uninstall ingress-nginx 2>/dev/null || true
kubectl delete ns "${NGINX_NS}" --ignore-not-found

echo "== Uninstall cert-manager =="
helm -n "${CM_NS}" uninstall cert-manager 2>/dev/null || true
kubectl delete ns "${CM_NS}" --ignore-not-found

if [[ "${CLEANUP_DELETE_CRDS:-false}" == "true" ]]; then
  echo "== Deleting cert-manager CRDs =="
  kubectl delete crd certificaterequests.cert-manager.io \
                      certificates.cert-manager.io \
                      challenges.acme.cert-manager.io \
                      clusterissuers.cert-manager.io \
                      issuers.cert-manager.io \
                      orders.acme.cert-manager.io --ignore-not-found
fi

echo "== Remove ClusterIssuer (dns01) =="
kubectl delete clusterissuer letsencrypt-prod-dns01 --ignore-not-found

echo "== Remove Workload Identity binding / GSA =="
# Remove WI annotation (safe even if ns gone)
kubectl -n "${CM_NS}" annotate sa cert-manager iam.gke.io/gcp-service-account- --overwrite 2>/dev/null || true

# Remove IAM binding and GSA
gcloud projects remove-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/dns.admin" >/dev/null 2>&1 || true

gcloud iam service-accounts delete "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --quiet 2>/dev/null || true

if [[ "${CLEANUP_DELETE_DNS_ZONE:-false}" == "true" ]]; then
  echo "== Deleting Cloud DNS managed zone ${ZONE_NAME} (${DNS_DOMAIN}) =="
  # Must be empty before deletion
  # Try to delete all record-sets except NS/SOA
  TMPF="$(mktemp)"
  gcloud dns record-sets list --zone="${ZONE_NAME}" --format=json > "${TMPF}" || true
  if [[ -s "${TMPF}" ]]; then
    gcloud dns record-sets transaction start --zone="${ZONE_NAME}" >/dev/null || true
    # Remove all A/CNAME/TXT/etc. (skip SOA/NS)
    for t in A AAAA CNAME TXT MX SRV PTR; do
      while read -r name; do
        [[ -z "${name}" ]] && continue
        ttl=$(gcloud dns record-sets list --zone="${ZONE_NAME}" --name="${name}" --type="${t}" --format="value(ttl)" 2>/dev/null || true)
        data=$(gcloud dns record-sets list --zone="${ZONE_NAME}" --name="${name}" --type="${t}" --format="value(rrdatas[])")
        [[ -z "${ttl}" || -z "${data}" ]] && continue
        gcloud dns record-sets transaction remove --zone="${ZONE_NAME}" --name="${name}" --type="${t}" --ttl="${ttl}" ${data} >/dev/null || true
      done < <(jq -r '.[] | select(.type=="'"$t"'") | .name' "${TMPF}")
    done
    gcloud dns record-sets transaction execute --zone="${ZONE_NAME}" >/dev/null || gcloud dns record-sets transaction abort --zone="${ZONE_NAME}" >/dev/null || true
    rm -f "${TMPF}"
  fi
  gcloud dns managed-zones delete "${ZONE_NAME}" --quiet || true
else
  echo "NOTE: Cloud DNS zone ${ZONE_NAME} kept (set CLEANUP_DELETE_DNS_ZONE=true to remove)."
fi

if [[ "${CLEANUP_DELETE_CLUSTER:-false}" == "true" ]]; then
  echo "== Deleting GKE Autopilot cluster ${CLUSTER_NAME} =="
  gcloud container clusters delete "${CLUSTER_NAME}" --region "${REGION}" --quiet || true
else
  echo "NOTE: Cluster ${CLUSTER_NAME} kept (set CLEANUP_DELETE_CLUSTER=true to remove)."
fi

echo "Cleanup completed."
