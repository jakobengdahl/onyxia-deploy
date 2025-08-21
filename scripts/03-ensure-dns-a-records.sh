#!/usr/bin/env bash
set -euo pipefail
# Ensures A records in Cloud DNS sub-zone for apex, *.domain, *.user.domain (idempotent).

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

LB_IP="$(kubectl -n "${NGINX_NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
if [[ -z "${LB_IP}" ]]; then
  echo "ERROR: LoadBalancer IP not ready."
  exit 1
fi

ensure_a() {
  local name="$1"
  local ip="$2"
  local have
  have="$(gcloud dns record-sets list -z "${ZONE_NAME}" --name="${name}" --type=A --format="get(rrdatas[0])" 2>/dev/null || true)"
  if [[ "${have}" == "${ip}" ]]; then
    echo "A ${name} already set to ${ip}"
    return
  fi

  gcloud dns record-sets transaction start -z "${ZONE_NAME}" >/dev/null || true
  if [[ -n "${have}" ]]; then
    gcloud dns record-sets transaction remove -z "${ZONE_NAME}" --name="${name}" --type=A --ttl=300 "${have}" >/dev/null
  fi
  gcloud dns record-sets transaction add -z "${ZONE_NAME}" --name="${name}" --type=A --ttl=300 "${ip}" >/dev/null
  gcloud dns record-sets transaction execute -z "${ZONE_NAME}" >/dev/null
  echo "A ${name} -> ${ip} ensured"
}

ensure_a "${DNS_DOMAIN}." "${LB_IP}"
ensure_a "*.${DNS_DOMAIN}." "${LB_IP}"
ensure_a "*.user.${DNS_DOMAIN}." "${LB_IP}"

echo "Current A records:"
gcloud dns record-sets list -z "${ZONE_NAME}" --filter="type=A"
