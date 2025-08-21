#!/usr/bin/env bash
set -euo pipefail

# Load env
[[ -f ".env" ]] && source .env

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${REGION:?Set REGION}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
: "${DNS_DOMAIN:?Set DNS_DOMAIN}"
: "${ACME_EMAIL:?Set ACME_EMAIL}"
: "${GSA_NAME:=cm-dns01-solver}"
: "${CM_NS:=cert-manager}"

gcloud config set project "${PROJECT_ID}" >/dev/null
gcloud config set compute/region "${REGION}" >/dev/null
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

echo "== Create/ensure GSA =="
gcloud iam service-accounts create "${GSA_NAME}" --display-name="cert-manager dns01" 2>/dev/null || true

echo "== Grant dns.admin on project =="
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/dns.admin" >/dev/null

echo "== Bind Workload Identity to KSA ${CM_NS}/cert-manager =="
gcloud iam service-accounts add-iam-policy-binding "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:${PROJECT_ID}.svc.id.goog[${CM_NS}/cert-manager]" >/dev/null

kubectl -n "${CM_NS}" annotate serviceaccount cert-manager \
  "iam.gke.io/gcp-service-account=${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --overwrite

echo "== Restart cert-manager to pick up annotation =="
kubectl -n "${CM_NS}" rollout restart deploy/cert-manager
kubectl -n "${CM_NS}" rollout status deploy/cert-manager --timeout=5m

echo "== Apply ClusterIssuer (Let’s Encrypt PROD, DNS-01 via Cloud DNS) =="
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
echo "✅ ClusterIssuer ready (check .status.conditions[].type==Ready)."
