#!/usr/bin/env bash
set -euo pipefail
set -a; source .env; set +a

gcloud config set project "${PROJECT_ID}" >/dev/null

echo "Cloud DNS nameservers for ${DNS_DOMAIN}:"
gcloud dns managed-zones describe "${ZONE_NAME}" --format="value(nameServers[]) " | tr ';' '\n'
echo

echo "Public check (NS ${DNS_DOMAIN}):"
dig +short NS "${DNS_DOMAIN}"
echo

echo "Ingress LoadBalancer IP:"
LB_IP="$(kubectl -n "${NGINX_NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
echo "LB_IP=${LB_IP:-<pending>}"
