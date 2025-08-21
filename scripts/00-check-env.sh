#!/usr/bin/env bash
set -euo pipefail

# ---- Load or create .env -----------------------------------------------------
if [[ -f ".env" ]]; then
  set -a; source .env; set +a
else
  echo "No .env found. Creating a minimal one from defaults..."
  cat > .env <<'EOF'
PROJECT_ID=
REGION=europe-north1
CLUSTER_NAME=onyxia-poc

NAMESPACE=default
ONYXIA_HOST=

DNS_DOMAIN=
ZONE_NAME=

ACME_EMAIL=
GSA_NAME=cm-dns01-solver
NGINX_NS=ingress-nginx
CM_NS=cert-manager
WILDCARD_SECRET=wildcard-lab-tls

CATALOG_URL=
CUSTOM_RESOURCES_URL=
EOF
  echo "Fill .env before re-running this script."
  exit 1
fi

reqs=(PROJECT_ID REGION CLUSTER_NAME DNS_DOMAIN ZONE_NAME ONYXIA_HOST ACME_EMAIL)
for v in "${reqs[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "Missing $v in .env"; exit 1; }
done

gcloud config set project "${PROJECT_ID}" >/dev/null
gcloud config set compute/region "${REGION}" >/dev/null

# ---- GKE Autopilot cluster ---------------------------------------------------
if ! gcloud container clusters describe "${CLUSTER_NAME}" --region "${REGION}" >/dev/null 2>&1; then
  echo "Creating Autopilot cluster ${CLUSTER_NAME} in ${REGION}..."
  gcloud container clusters create-auto "${CLUSTER_NAME}" --region "${REGION}"
else
  echo "Cluster ${CLUSTER_NAME} already exists."
fi

gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

# ---- Cloud DNS managed zone (child zone for DNS_DOMAIN) ----------------------
if ! gcloud dns managed-zones describe "${ZONE_NAME}" >/dev/null 2>&1; then
  echo "Creating Cloud DNS public managed zone ${ZONE_NAME} for ${DNS_DOMAIN}..."
  gcloud dns managed-zones create "${ZONE_NAME}" \
    --dns-name="${DNS_DOMAIN}." \
    --visibility="public" \
    --description="Child zone for lab services"
else
  echo "Managed zone ${ZONE_NAME} already exists."
fi

# Print nameservers you must delegate to in your parent zone (Zoneedit)
NSS=$(gcloud dns managed-zones describe "${ZONE_NAME}" --format="value(nameServers[])")
echo
echo "=== Delegate these NS in the parent zone for ${DNS_DOMAIN} ==="
echo "${NSS}" | tr ';' '\n'
echo
echo "Create 4 NS records in Zoneedit for host '${DNS_DOMAIN%.*}' in your parent zone,"
echo "one per nameserver above. Then wait for delegation to propagate."
