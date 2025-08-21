#!/usr/bin/env bash
set -euo pipefail

# Issue/ensure a wildcard Certificate via cert-manager (DNS-01).
# Requires that 04-setup-dns01-issuer.sh has been run successfully.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "${ROOT}/.env" ]]; then
  echo "ERROR: Missing .env at repo root. Aborting."
  exit 1
fi

# Load env (expects DNS_DOMAIN etc.)
set -a
# shellcheck disable=SC1091
source "${ROOT}/.env"
set +a

# Required env with sane defaults
: "${DNS_DOMAIN:?DNS_DOMAIN is required (e.g. lab.example.com)}"
WILDCARD_CERT_NS="${WILDCARD_CERT_NS:-ingress-nginx}"
WILDCARD_CERT_NAME="${WILDCARD_CERT_NAME:-wildcard-lab-tls}"
CLUSTER_ISSUER_NAME="${CLUSTER_ISSUER_NAME:-letsencrypt-prod-dns01}"

echo "Target domain(s): ${DNS_DOMAIN}, *.${DNS_DOMAIN}, *.user.${DNS_DOMAIN}"
echo "Namespace: ${WILDCARD_CERT_NS}"
echo "Certificate name: ${WILDCARD_CERT_NAME}"
echo "ClusterIssuer: ${CLUSTER_ISSUER_NAME}"

mkdir -p "${ROOT}/.tmp"
TMP="${ROOT}/.tmp/wildcard-cert.yaml"

# Write manifest to a file to avoid heredoc/STDIN parsing issues.
cat > "${TMP}" <<EOF
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

echo "Validating manifest (client-side)..."
kubectl apply -f "${TMP}" --dry-run=client >/dev/null

echo "Applying Certificate..."
kubectl apply -f "${TMP}"

echo "Waiting for Certificate to be Ready..."
for i in {1..60}; do
  status="$(kubectl -n "${WILDCARD_CERT_NS}" get certificate "${WILDCARD_CERT_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${status}" == "True" ]]; then
    echo "✅ Certificate is Ready."
    break
  fi
  if (( i % 6 == 0 )); then
    echo "Still waiting... (attempt ${i})"
    # Helpful to see pending ACME resources while waiting
    kubectl get order,challenge -A | grep -E "${WILDCARD_CERT_NAME}" || true
  fi
  sleep 5
done

echo
echo "Certificate summary:"
kubectl -n "${WILDCARD_CERT_NS}" describe certificate "${WILDCARD_CERT_NAME}" | sed -n '1,120p'
echo
echo "If not Ready, check cert-manager logs:"
echo "  kubectl logs -n cert-manager deploy/cert-manager | tail -n 200"
