#!/usr/bin/env bash
set -euo pipefail
# Configures Workload Identity + IAM for cert-manager to use Cloud DNS DNS-01, and creates ClusterIssuer.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

gcloud iam service-accounts create "${GSA_NAME}" --display-name="cert-manager dns01" 2>/dev/null || true

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/dns.admin" >/dev/null

gcloud iam service-accounts add-iam-policy-binding \
  "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${CM_NS}/cert-manager]" >/dev/null

kubectl -n "${CM_NS}" annotate serviceaccount cert-manager \
  "iam.gke.io/gcp-service-account=${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --overwrite

kubectl -n "${CM_NS}" rollout restart deploy/cert-manager
kubectl -n "${CM_NS}" rollout status deploy/cert-manager --timeout=5m

cat <<YAML | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns01
spec:
  acme:
    email: ${ACME_EMAIL}
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-prod-dns01-account-key
    solvers:
    - selector:
        dnsZones:
        - ${DNS_DOMAIN}
        - user.${DNS_DOMAIN}
      dns01:
        cloudDNS:
          project: ${PROJECT_ID}
YAML

kubectl get clusterissuer letsencrypt-prod-dns01 -o yaml | sed -n '1,120p'
