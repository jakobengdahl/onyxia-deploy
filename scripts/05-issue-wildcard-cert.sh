#!/usr/bin/env bash
set -euo pipefail
# Issues a wildcard cert and sets it as default TLS in ingress-nginx.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

cat <<YAML | kubectl apply -f -
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
    - "${DNS_DOMAIN}"
    - "*.${DNS_DOMAIN}"
    - "*.user.${DNS_DOMAIN}"
YAML

echo "Waiting for wildcard certificate to become Ready..."
for i in {1..36}; do
  cond="$(kubectl -n "${NGINX_NS}" get certificate "${WILDCARD_SECRET}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "${cond}" == "True" ]] && break
  sleep 10
done
kubectl -n "${NGINX_NS}" get certificate "${WILDCARD_SECRET}" -o wide

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n "${NGINX_NS}" \
  --reuse-values \
  --set controller.extraArgs.default-ssl-certificate="${NGINX_NS}/${WILDCARD_SECRET}" \
  --wait

LB_IP="$(kubectl -n "${NGINX_NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
HOST="randomcheck.${DNS_DOMAIN}"
if command -v openssl >/dev/null 2>&1; then
  echo "Verifying certificate via s_client (SNI=${HOST})..."
  printf '' | openssl s_client -connect "${LB_IP}:443" -servername "${HOST}" 2>/dev/null \
    | openssl x509 -noout -subject -ext subjectAltName || true
fi
