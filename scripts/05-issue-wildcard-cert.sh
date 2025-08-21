#!/usr/bin/env bash
set -euo pipefail

# --------------------------------------------
# Issue/refresh wildcard certificate via cert-manager (DNS-01)
# Primary domain variable: DNS_DOMAIN (fallback: LAB_DOMAIN)
# Requires:
#  - A working ClusterIssuer (default: letsencrypt-prod-dns01)
#  - Access to a DNS-01 solver for the domain
#  - kubectl context pointing to the target cluster
# --------------------------------------------

# Load .env from repo root if present
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [ -f "${ROOT_DIR}/.env" ]; then
  # shellcheck disable=SC1090
  set -a; source "${ROOT_DIR}/.env"; set +a
fi

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing required command: $1"; exit 1; }
}
require kubectl
require sed
require awk
require date

# ---- Resolve domain inputs (prefer DNS_DOMAIN) ----
DNS_DOMAIN="${DNS_DOMAIN:-${LAB_DOMAIN:-}}"
if [ -z "${DNS_DOMAIN}" ]; then
  echo "DNS_DOMAIN (or LAB_DOMAIN) is required, e.g. dns.example.com"
  exit 1
fi
# Strip trailing dot if user pasted a DNS-style FQDN
DNS_DOMAIN="${DNS_DOMAIN%.}"

# ---- Common vars (with sensible defaults) ----
WILDCARD_CERT_NAME="${WILDCARD_CERT_NAME:-${WILDCARD_SECRET:-wildcard-lab-tls}}"
WILDCARD_CERT_NS="${WILDCARD_CERT_NS:-${NGINX_NS:-ingress-nginx}}"
CLUSTER_ISSUER_NAME="${CLUSTER_ISSUER_NAME:-letsencrypt-prod-dns01}"

echo "== Using settings =="
echo "  DNS_DOMAIN:          ${DNS_DOMAIN}"
echo "  Certificate name:    ${WILDCARD_CERT_NAME}"
echo "  Certificate ns:      ${WILDCARD_CERT_NS}"
echo "  ClusterIssuer:       ${CLUSTER_ISSUER_NAME}"
echo

# ---- Create/Apply Certificate manifest (idempotent) ----
TMP_MANIFEST="$(mktemp)"
cat > "${TMP_MANIFEST}" <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${WILDCARD_CERT_NAME}
  namespace: ${WILDCARD_CERT_NS}
spec:
  secretName: ${WILDCARD_CERT_NAME}
  issuerRef:
    name: ${CLUSTER_ISSUER_NAME}
    kind: ClusterIssuer
  dnsNames:
    - "${DNS_DOMAIN}"
    - "*.${DNS_DOMAIN}"
    - "*.user.${DNS_DOMAIN}"
EOF

echo "Applying Certificate manifest..."
kubectl apply -f "${TMP_MANIFEST}" >/dev/null
rm -f "${TMP_MANIFEST}"

echo "Polling certificate readiness (up to 10 minutes)..."
DEADLINE=$(( $(date +%s) + 600 ))
READY="False"

while [ "$(date +%s)" -lt "${DEADLINE}" ]; do
  READY_STATUS="$(kubectl -n "${WILDCARD_CERT_NS}" get certificate "${WILDCARD_CERT_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")"
  if [ "${READY_STATUS}" = "True" ]; then
    READY="True"
    break
  fi
  # Optional: show current Orders/Challenges summary (non-fatal if empty)
  echo "  Waiting… checking Orders/Challenges"
  kubectl get order,challenge -A 2>/dev/null | grep "${WILDCARD_CERT_NAME}" || true
  sleep 10
done

if [ "${READY}" != "True" ]; then
  echo "ERROR: Certificate did not become Ready within timeout."
  echo "Hint: check cert-manager logs:"
  echo "  kubectl logs -n cert-manager deploy/cert-manager | egrep -i '${WILDCARD_CERT_NAME}|dns01|acme|order|challenge|error'"
  exit 1
fi

echo
echo "== Certificate Ready =="
kubectl -n "${WILDCARD_CERT_NS}" get certificate "${WILDCARD_CERT_NAME}" -o wide
echo
echo "Secret present:"
kubectl -n "${WILDCARD_CERT_NS}" get secret "${WILDCARD_CERT_NAME}" -o jsonpath='{.metadata.name}{"\n"}'
echo
echo "Done."
