#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

kubectl -n "${NGINX_NS}" apply -f - <<EOF
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

echo "Waiting for certificate ${WILDCARD_SECRET} to be Ready..."
for i in {1..60}; do
  st="$(kubectl -n "${NGINX_NS}" get certificate "${WILDCARD_SECRET}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${st}" == "True" ]]; then
    echo "Certificate is Ready."
    break
  fi
  sleep 5
done

# NGINX default-ssl-certificate guard (if your 01-script didn’t already set it)
if ! kubectl -n "${NGINX_NS}" get deploy ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- "--default-ssl-certificate=${NGINX_NS}/${WILDCARD_SECRET}"; then
  echo "Patching ingress-nginx-controller to use ${NGINX_NS}/${WILDCARD_SECRET} as default SSL certificate..."
  kubectl -n "${NGINX_NS}" patch deploy ingress-nginx-controller \
    --type json -p="[{
      \"op\":\"add\",
      \"path\":\"/spec/template/spec/containers/0/args/-\",
      \"value\":\"--default-ssl-certificate=${NGINX_NS}/${WILDCARD_SECRET}\"
    }]"
  kubectl -n "${NGINX_NS}" rollout restart deploy/ingress-nginx-controller
  kubectl -n "${NGINX_NS}" rollout status deploy/ingress-nginx-controller --timeout=5m
fi
