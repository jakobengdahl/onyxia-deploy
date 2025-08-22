#!/usr/bin/env bash
set -euo pipefail

# --- Load env & kube context ---
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  echo "Missing ${ROOT_DIR}/.env — copy .env.example and fill your values." >&2
  exit 1
fi
# shellcheck disable=SC2046
export $(grep -E '^[A-Z0-9_]+=' "${ROOT_DIR}/.env" | xargs -I{} echo {})

gcloud config set core/project "${PROJECT_ID}" >/dev/null
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

SUBZONE="${SUBZONE:?SUBZONE must be set in .env, e.g. boa71693.tjoo.se}"
ONYXIA_HOST="onyxia.${SUBZONE}"

echo "-> Checking NS delegation for ${SUBZONE}"
dig NS "${SUBZONE}" +short

echo "-> Verifying A record resolution for ${ONYXIA_HOST}"
LB_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
if [[ -z "${LB_IP}" ]]; then
  echo "ERROR: ingress-nginx LoadBalancer IP not found. Run the previous step that installs ingress-nginx first." >&2
  exit 1
fi
RESOLVED_IP="$(dig +short "${ONYXIA_HOST}" | tail -n1 || true)"
if [[ "${RESOLVED_IP}" != "${LB_IP}" ]]; then
  echo "DNS WARNING: ${ONYXIA_HOST} resolves to '${RESOLVED_IP}', expected '${LB_IP}'."
  echo "If you just updated NS/A records at the registrar, wait until they propagate."
else
  echo "DNS OK: ${ONYXIA_HOST} -> ${RESOLVED_IP}"
fi

# --- Install cert-manager robustly ---
echo "-> Installing cert-manager (with CRDs pre-applied)"
CM_VERSION="${CERT_MANAGER_VERSION:-v1.14.4}"

# Apply CRDs first to avoid Helm post-install timeouts
kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${CM_VERSION}/cert-manager.crds.yaml"

kubectl get ns cert-manager >/dev/null 2>&1 || kubectl create ns cert-manager

helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update >/dev/null

# Install/upgrade chart and wait
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version "${CM_VERSION}" \
  --wait --timeout 10m

echo "-> Waiting for cert-manager rollouts"
kubectl rollout status deploy/cert-manager -n cert-manager --timeout=300s
kubectl rollout status deploy/cert-manager-webhook -n cert-manager --timeout=300s
kubectl rollout status deploy/cert-manager-cainjector -n cert-manager --timeout=300s

# --- Ensure ClusterIssuer (DNS-01 via Cloud DNS) ---
echo "-> Applying ClusterIssuer letsencrypt-prod-dns01"
envsubst < "${ROOT_DIR}/manifests/clusterissuer-letsencrypt-prod-dns01.yaml.tmpl" | kubectl apply -f -

# --- Issue wildcard cert ---
echo "-> Applying wildcard Certificate (wildcard-lab-tls)"
envsubst < "${ROOT_DIR}/manifests/certificate-wildcard.yaml.tmpl" | kubectl apply -f -

echo "  Waiting… checking Orders/Challenges"
ATTEMPTS=30
SLEEP=10
for ((i=1; i<=ATTEMPTS; i++)); do
  READY="$(kubectl -n ingress-nginx get certificate wildcard-lab-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${READY}" == "True" ]]; then
    echo "Certificate is Ready."
    break
  fi
  kubectl -n ingress-nginx get order,challenge | sed 's/^/  /' || true
  sleep "${SLEEP}"
  if [[ $i -eq $ATTEMPTS ]]; then
    echo "ERROR: Certificate did not become Ready within timeout."
    echo "Hint: cert-manager logs:"
    echo "  kubectl logs -n cert-manager deploy/cert-manager | egrep -i 'dns01|acme|order|challenge|error'"
    exit 1
  fi
done

# --- Make it the default TLS for NGINX ---
echo "-> Patching ingress-nginx controller to use wildcard-lab-tls as default"
kubectl -n ingress-nginx patch deploy ingress-nginx-controller \
  --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--default-ssl-certificate=ingress-nginx/wildcard-lab-tls"}]'

kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=5m

echo "Done: cert-manager installed and wildcard certificate issued."
