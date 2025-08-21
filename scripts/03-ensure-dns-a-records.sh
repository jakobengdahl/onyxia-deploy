#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

gcloud config set project "${PROJECT_ID}" >/dev/null

LB_IP="$(kubectl -n "${NGINX_NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
[[ -n "${LB_IP}" ]] || { echo "No LB IP yet"; exit 1; }

function upsert_a() {
  local name="$1" ttl="${2:-300}" ip="$3"
  local have
  have=$(gcloud dns record-sets list --zone="${ZONE_NAME}" --name="${name}" --type=A --format="value(rrdatas[0])" || true)
  gcloud dns record-sets transaction start --zone "${ZONE_NAME}" >/dev/null

  if [[ -n "${have}" ]]; then
    gcloud dns record-sets transaction remove --zone "${ZONE_NAME}" \
      --name="${name}" --type=A --ttl="$(gcloud dns record-sets list --zone="${ZONE_NAME}" --name="${name}" --type=A --format='value(ttl)')" "${have}" >/dev/null
  fi

  gcloud dns record-sets transaction add --zone "${ZONE_NAME}" \
    --name="${name}" --type=A --ttl="${ttl}" "${ip}" >/dev/null

  if ! gcloud dns record-sets transaction execute --zone "${ZONE_NAME}" >/dev/null 2>&1; then
    echo "Transaction conflict for ${name}, retrying..."
    gcloud dns record-sets transaction abort --zone "${ZONE_NAME}" >/dev/null 2>&1 || true
    # second attempt (fresh)
    gcloud dns record-sets transaction start --zone "${ZONE_NAME}" >/dev/null
    gcloud dns record-sets transaction add --zone "${ZONE_NAME}" \
      --name="${name}" --type=A --ttl="${ttl}" "${ip}" >/dev/null
    gcloud dns record-sets transaction execute --zone "${ZONE_NAME}" >/devnull
  fi
  echo "Upserted A ${name} -> ${ip}"
}

upsert_a "${DNS_DOMAIN}." 300 "${LB_IP}"
upsert_a "*.${DNS_DOMAIN}." 300 "${LB_IP}"
upsert_a "*.user.${DNS_DOMAIN}." 300 "${LB_IP}"

echo
echo "Remember to set A record for ${ONYXIA_HOST} in Zoneedit to ${LB_IP} (parent zone)."
