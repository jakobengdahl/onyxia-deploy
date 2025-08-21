#!/usr/bin/env bash
set -euo pipefail
# Prints Cloud DNS NS servers for the subzone and the current LB IP (manual use in parent DNS).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

echo "=== Cloud DNS name servers for sub-zone (${ZONE_NAME} / ${DNS_DOMAIN}) ==="
gcloud dns managed-zones describe "${ZONE_NAME}" --format="value(nameServers[])"

LB_IP="$(kubectl -n "${NGINX_NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
echo "=== Current LoadBalancer IP (for A-records in sub-zone) ==="
echo "${LB_IP:-<pending>}"

cat <<INFO

Action (manual in parent DNS provider):
- Create 4 NS records for the subdomain (e.g. 'lab') pointing to the Cloud DNS name servers above (one per record).
INFO
