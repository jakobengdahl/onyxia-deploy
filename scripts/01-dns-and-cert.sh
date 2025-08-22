#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

source .env
source .state

REGION="${REGION:-europe-north1}"
CLUSTER_NAME="${CLUSTER_NAME:-onyxia-poc}"

GSA_NAME="cm-dns01-solver"
CM_NS="cert-manager"
NGINX_NS="ingress-nginx"
WILDCARD_SECRET="wildcard-lab-tls"
ACME_ENV="${ACME_ENV:-prod}" # staging|prod

gcloud config set core/project "${PROJECT_ID}" >/dev/null
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}"

echo "-> Checking NS delegation for ${DNS_DOMAIN}"
deadline=$((SECONDS+600))
while true; do
  ns_now="$(dig +short NS "${DNS_DOMAIN}." | tr '[:upper:]' '[:lower:]' || true)"
  if echo "${ns_now}" | grep -q "googledomains.com"; then
    echo "NS looks delegated to Google: "
    echo "${ns_now}"
    break
  fi
  if (( SECONDS > deadline )); then
    echo "ERROR: NS delegation not visible after 10 minutes. Try again later."
    exit 1
  fi
  echo "  waiting for NS delegation..."
  sleep 10
done

echo "-> Verifying A record resolution for ${ONYXIA_HOST}"
deadline=$((SECONDS+600))
while true; do
  a_now="$(dig +short "${ONYXIA_HOST}" | head -n1 || true)"
  if [[ "${a_now}" == "${LB_IP}" ]]; then
    echo "DNS OK: ${ONYXIA_HOST} -> ${a_now}"
    break
  fi
  if (( SECONDS > deadline )); then
    echo "ERROR: ${ONYXIA_HOST} does not resolve to ${LB_IP} after 10 minutes."
    exit 1
  fi
  echo "  waiting for ${ONYXIA_HOST} A record to resolve..."
  sleep 10
done

echo "-> Installing cert-manager"
kubectl create ns "${CM_NS}" --dry-run=client -o yaml | kubectl apply -f -
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install cert-manager jetstack/cert-manager \
  -n "${CM_NS}" --set installCRDs=true

kubectl -n "${CM_NS}" rollout status deploy/cert-manager --timeout=5m
kubectl -n "${CM_NS}" rollout status deploy/cert-manager-webhook --timeout=5m
kubectl -n "${CM_NS}" rollout status deploy/cert-manager-cainjector --timeout=5m

echo "-> Creating GSA and bindings for DNS-01"
gcloud iam service-accounts create "${GSA_NAME}" --display-name="${GSA_NAME}" 2>/dev/null || true
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --role roles/dns.admin \
  --member "serviceAccount:${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" >/dev/null

kubectl -n "${CM_NS}" annotate sa cert-manager \
  "iam.gke.io/gcp-service-account=${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" --overwrite

gcloud iam service-accounts add-iam-policy-binding \
  "${GSA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[${CM_NS}/cert-manager]" >/dev/null

echo "-> Applying ClusterIssuer (Let's Encrypt ${ACME_ENV})"
if [[ "${ACME_ENV}" == "staging" ]]; then
  ACME_SERVER="https://acme-staging-v02.api.letsencrypt.org/directory"
else
  ACME_SERVER="https://acme-v02.api.letsencrypt.org/directory"
fi

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod-dns01
spec:
  acme:
    email: ${ACME_EMAIL}
    server: ${ACME_SERVER}
    privateKeySecretRef:
      name: letsencrypt-prod-dns01-account-key
    solvers:
    - dns01:
        cloudDNS:
          project: ${PROJECT_ID}
      selector:
        dnsZones:
        - ${DNS_DOMAIN}
EOF

echo "-> Requesting wildcard certificate"
kubectl create ns "${NGINX_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${WILDCARD_SECRET}
  namespace: ${NGINX_NS}
spec:
  secretName: ${WILDCARD_SECRET}
  issuerRef:
    name: letsencrypt-prod-dns01
    kind: ClusterIssuer
  dnsNames:
    - ${DNS_DOMAIN}
    - *.${DNS_DOMAIN}
    - *.user.${DNS_DOMAIN}
EOF

echo "-> Waiting for certificate to be Ready"
deadline=$((SECONDS+900))
while true; do
  cond="$(kubectl -n "${NGINX_NS}" get certificate "${WILDCARD_SECRET}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "${cond}" == "True" ]] && break
  if (( SECONDS > deadline )); then
    echo "ERROR: Certificate did not become Ready within timeout."
    echo "Hint: check logs:"
    echo "kubectl logs -n ${CM_NS} deploy/cert-manager | egrep -i '${WILDCARD_SECRET}|dns01|acme|order|challenge|error'"
    exit 1
  fi
  echo "  waiting..."
  sleep 10
done

echo "-> Patching ingress-nginx to use default TLS certificate"
kubectl -n "${NGINX_NS}" patch deployment ingress-nginx-controller \
  --type json \
  -p="[
    {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--default-ssl-certificate=${NGINX_NS}/${WILDCARD_SECRET}\"},
    {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--watch-ingress-without-class=true\"},
    {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--ingress-class-by-name=true\"}
  ]" || true

kubectl -n "${NGINX_NS}" rollout restart deploy/ingress-nginx-controller
kubectl -n "${NGINX_NS}" rollout status deploy/ingress-nginx-controller --timeout=5m

echo "Done. Certificate Ready and controller patched."
echo "Next: bash scripts/02-deploy-onyxia.sh"
