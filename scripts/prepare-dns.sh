#!/usr/bin/env bash
set -euo pipefail

# Load local env if present
if [[ -f ".env" ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${PROJECT_ID:=$(gcloud config get-value core/project 2>/dev/null || true)}"
: "${REGION:=$(gcloud config get-value compute/region 2>/dev/null || true)}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME in .env or env}"
: "${ZONE_NAME:?Set ZONE_NAME in .env or env (Cloud DNS managed zone name)}"
: "${DNS_DOMAIN:?Set DNS_DOMAIN in .env or env (e.g. lab.example.com)}"

: "${NGINX_NS:=ingress-nginx}"

gcloud config set project "${PROJECT_ID}" >/dev/null
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

LB_IP="$(kubectl -n "${NGINX_NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "LB_IP=${LB_IP}"
echo

APEX="${DNS_DOMAIN}."
WILDCARD="*.${DNS_DOMAIN}."
USER_WILDCARD="*.user.${DNS_DOMAIN}."

echo "== Planned A-records =="
printf "  %-35s -> %s\n" "${APEX}" "${LB_IP}"
printf "  %-35s -> %s\n" "${WILDCARD}" "${LB_IP}"
printf "  %-35s -> %s\n" "${USER_WILDCARD}" "${LB_IP}"
echo

echo "== Reconciling records in Cloud DNS zone: ${ZONE_NAME} =="
TMPDIR="$(mktemp -d)"
pushd "${TMPDIR}" >/dev/null

# Helper: upsert A record to desired IP (delete old if needed, then add)
upsert_a() {
  local name="$1"; local ip="$2"
  local existing
  existing="$(gcloud dns record-sets list -z "${ZONE_NAME}" --name="${name}" --type=A --format="value(rrdatas[0])" || true)"
  gcloud dns record-sets transaction start -z "${ZONE_NAME}" >/dev/null
  if [[ -n "${existing}" && "${existing}" != "${ip}" ]]; then
    gcloud dns record-sets transaction remove -z "${ZONE_NAME}" --name="${name}" --type=A --ttl=300 "${existing}" >/dev/null
  fi
  if [[ -z "${existing}" || "${existing}" != "${ip}" ]]; then
    gcloud dns record-sets transaction add    -z "${ZONE_NAME}" --name="${name}" --type=A --ttl=300 "${ip}" >/dev/null
  fi
  # If nothing changed, abort transaction to avoid empty commit error
  if ! gcloud dns record-sets transaction execute -z "${ZONE_NAME}" >/dev/null 2>&1; then
    gcloud dns record-sets transaction abort -z "${ZONE_NAME}" >/dev/null || true
  fi
}

upsert_a "${APEX}" "${LB_IP}"
upsert_a "${WILDCARD}" "${LB_IP}"
upsert_a "${USER_WILDCARD}" "${LB_IP}"

popd >/dev/null
rm -rf "${TMPDIR}"

echo "✅ DNS A-records reconciled. Current A records:"
gcloud dns record-sets list -z "${ZONE_NAME}" --filter="type=A"
