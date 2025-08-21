#!/usr/bin/env bash
set -euo pipefail

[[ -f ".env" ]] && source .env

: "${PROJECT_ID:?Set PROJECT_ID}"
: "${REGION:?Set REGION}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
: "${DNS_DOMAIN:?Set DNS_DOMAIN}"
: "${WILDCARD_SECRET:=wildcard-edge-tls}"
: "${NGINX_NS:=ingress-nginx}"

gcloud config set project "${PROJECT_ID}" >/dev/null
gcloud config set compute/region "${REGION}" >/dev/null
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

echo "== Apply wildcard Certificate =="
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
    - "*.$DNS_DOMAIN"
    - "*.user.$DNS_DOMAIN"
YAML

echo "== Wait for Certificate to be Ready =="
for i in {1..36}; do
  cond="$(kubectl -n "${NGINX_NS}" get certificate "${WILDCARD_SECRET}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  [[ "${cond}" == "True" ]] && break
  echo "…waiting (${i}/36)"
  sleep 10
done
kubectl -n "${NGINX_NS}" get certificate "${WILDCARD_SECRET}" -o wide

echo "== Set as default SSL cert on ingress-nginx (via Helm) =="
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n "${NGINX_NS}" \
  --reuse-values \
  --set controller.extraArgs.default-ssl-certificate="${NGINX_NS}/${WILDCARD_SECRET}" \
  --wait

echo "== Sanity check the presented cert on the LB =="
LB_IP="$(kubectl -n "${NGINX_NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
HOST="randomcheck.${DNS_DOMAIN}"
printf '' | openssl s_client -connect ${LB_IP}:443 -servername ${HOST} 2>/dev/null | \
  openssl x509 -noout -subject -ext subjectAltName | sed -e 's/subject=/subject: /'
echo "✅ Wildcard certificate in place."
