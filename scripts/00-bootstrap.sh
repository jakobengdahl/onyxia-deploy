#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

if [[ ! -f .env ]]; then
  echo "Missing .env. Copy .env.example to .env and fill in required values."
  exit 1
fi
# shellcheck disable=SC1091
source .env

# Defaults
REGION="${REGION:-europe-north1}"
CLUSTER_NAME="${CLUSTER_NAME:-onyxia-poc}"
NAMESPACE="${NAMESPACE:-default}"
HELM_CHART_REPO="${HELM_CHART_REPO:-https://inseefrlab.github.io/helm-charts}"

if [[ -z "${BASE_DOMAIN:-}" || -z "${ACME_EMAIL:-}" ]]; then
  echo "BASE_DOMAIN and ACME_EMAIL are required in .env"
  exit 1
fi

PROJECT_PREFIX="scb-onyxia-lab"

ensure_project() {
  if [[ -n "${PROJECT_ID:-}" ]]; then
    echo "Using existing PROJECT_ID=${PROJECT_ID}"
    gcloud config set core/project "${PROJECT_ID}" >/dev/null
    return
  fi

  local run_id
  run_id="$(shuf -i 10000-99999 -n 1)"
  PROJECT_ID="${PROJECT_PREFIX}-${run_id}"
  echo "-> Creating project: ${PROJECT_ID}"
  gcloud projects create "${PROJECT_ID}" --name="${PROJECT_ID}"

  if [[ -n "${BILLING_ACCOUNT_ID:-}" ]]; then
    echo "-> Linking billing: ${BILLING_ACCOUNT_ID}"
    gcloud beta billing projects link "${PROJECT_ID}" --billing-account="${BILLING_ACCOUNT_ID}"
  else
    echo "NOTE: No BILLING_ACCOUNT_ID set. Assuming billing is auto-attached in your org."
  fi

  gcloud config set core/project "${PROJECT_ID}" >/dev/null

  # Persist PROJECT_ID into .env for this run
  if grep -q '^PROJECT_ID=' .env; then
    sed -i.bak "s/^PROJECT_ID=.*/PROJECT_ID=${PROJECT_ID}/" .env
  else
    echo "PROJECT_ID=${PROJECT_ID}" >> .env
  fi
}

enable_apis() {
  echo "-> Enabling required APIs"
  gcloud services enable \
    container.googleapis.com \
    dns.googleapis.com \
    iam.googleapis.com \
    iamcredentials.googleapis.com \
    serviceusage.googleapis.com
}

create_cluster() {
  echo "-> Creating Autopilot cluster: ${CLUSTER_NAME} in ${REGION}"
  gcloud config set compute/region "${REGION}" >/dev/null
  gcloud container clusters create-auto "${CLUSTER_NAME}" --region "${REGION}" || true
  gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}"
}

install_ingress() {
  echo "-> Installing ingress-nginx"
  kubectl create ns ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
  helm repo update >/dev/null

  helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
    -n ingress-nginx \
    --set controller.ingressClassResource.name=nginx \
    --set controller.ingressClassResource.enabled=true \
    --set controller.ingressClassResource.default=true \
    --set controller.watchIngressWithoutClass=true \
    --set controller.ingressClassByName=true

  echo "-> Waiting for LoadBalancer IP..."
  for i in {1..60}; do
    LB_IP="$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    [[ -n "${LB_IP}" ]] && break
    sleep 10
  done
  if [[ -z "${LB_IP}" ]]; then
    echo "ERROR: Timed out waiting for LB IP."
    exit 1
  fi
}

setup_dns_zone_and_records() {
  # Determine run id and ephemeral subdomain
  local run_id
  if [[ "${PROJECT_ID}" =~ ([0-9]{5})$ ]]; then
    run_id="${BASH_REMATCH[1]}"
  else
    run_id="$(shuf -i 10000-99999 -n 1)"
  fi

  DNS_DOMAIN="boa${run_id}.${BASE_DOMAIN}"
  ZONE_NAME="boa-${run_id}"
  ONYXIA_HOST="onyxia.${DNS_DOMAIN}"

  echo "-> Ensuring Cloud DNS managed zone: ${ZONE_NAME} (${DNS_DOMAIN}.)"
  if ! gcloud dns managed-zones describe "${ZONE_NAME}" >/dev/null 2>&1; then
    gcloud dns managed-zones create "${ZONE_NAME}" \
      --dns-name="${DNS_DOMAIN}." \
      --description="Ephemeral zone for ${PROJECT_ID}"
  fi

  # helper to upsert A records in Cloud DNS
  upsert_a_record() {
    local name="$1" ip="$2"
    local existing
    existing="$(gcloud dns record-sets list -z "${ZONE_NAME}" --name="${name}." --type=A --format='value(rrdatas[0])' || true)"
    gcloud dns record-sets transaction start -z "${ZONE_NAME}" >/dev/null 2>&1 || true
    if [[ -n "${existing}" && "${existing}" != "${ip}" ]]; then
      gcloud dns record-sets transaction remove -z "${ZONE_NAME}" --name="${name}." --type=A --ttl=300 "${existing}" >/dev/null 2>&1 || true
    fi
    if [[ -z "${existing}" || "${existing}" != "${ip}" ]]; then
      gcloud dns record-sets transaction add -z "${ZONE_NAME}" --name="${name}." --type=A --ttl=300 "${ip}"
    fi
    gcloud dns record-sets transaction execute -z "${ZONE_NAME}" >/dev/null 2>&1 || true
  }

  echo "-> Creating A records inside ${ZONE_NAME}"
  upsert_a_record "${ONYXIA_HOST}" "${LB_IP}"
  upsert_a_record "*.${DNS_DOMAIN}" "${LB_IP}"
  upsert_a_record "*.user.${DNS_DOMAIN}" "${LB_IP}"

  # Persist state for later scripts
  cat > .state <<EOF
PROJECT_ID=${PROJECT_ID}
REGION=${REGION}
CLUSTER_NAME=${CLUSTER_NAME}
LB_IP=${LB_IP}
DNS_DOMAIN=${DNS_DOMAIN}
ZONE_NAME=${ZONE_NAME}
ONYXIA_HOST=${ONYXIA_HOST}
EOF

  echo
  echo "=== Manual step (Eg. DNS registration in ZoneEdit) ==="
  echo "Delegate the subzone to Google Cloud DNS:"
  echo "  Subzone: ${DNS_DOMAIN}"
  echo "  NS records (add these in DNS registration system for ${DNS_DOMAIN}):"
  gcloud dns managed-zones describe "${ZONE_NAME}" --format='value(nameServers)'
  echo
  echo "A records are already created INSIDE the Cloud DNS zone:"
  echo "  ${ONYXIA_HOST} -> ${LB_IP}"
  echo "  *.${DNS_DOMAIN} -> ${LB_IP}"
  echo "  *.user.${DNS_DOMAIN} -> ${LB_IP}"
  echo
  echo "Run next step AFTER NS delegation has propagated:"
  echo "  bash scripts/01-dns-and-cert.sh"
}

ensure_project
enable_apis
create_cluster
install_ingress
setup_dns_zone_and_records
