#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

gcloud config set project "${PROJECT_ID}" >/dev/null
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

# Ensure GSA
if ! gcloud iam service-accounts describe "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${GSA_NAME}" --display-name="cert-manager dns01 solver"
fi

# Bind DNS admin on project to GSA (idempotent)
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/dns.admin" >/dev/null

# Annotate KSA for cert-manager with Workload Identity
kubectl -n "${CM_NS}" annotate sa cert-manager \
  "iam.gke.io/gcp-service-account=${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --overwrite

# Restart cert-manager to pick up WI annotation (safe)
kubectl -n "${CM_NS}" rollout restart deploy/cert-manager
kubectl -n "${CM_NS}" rollout status deploy/cert-manager --timeout=5m

# ClusterIssuer (DNS-01)
cat <<EOF | kubectl apply -f -
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
          # hostedZoneName can be set, but is not required:
          # hostedZoneName: ${ZONE_NAME}
EOF

echo "ClusterIssuer letsencrypt-prod-dns01 applied."
