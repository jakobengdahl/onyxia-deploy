#!/usr/bin/env bash
set -euo pipefail
# Installs/updates cert-manager + ingress-nginx, makes nginx default ingress class, prints LB IP.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${ROOT_DIR}/.env"; set +a

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add onyxia https://inseefrlab.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  -n "${CM_NS}" --create-namespace \
  --version v1.18.2 \
  --set crds.enabled=true \
  --set startupapicheck.enabled=false \
  --set global.leaderElection.namespace="${CM_NS}" \
  --wait --timeout 10m

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n "${NGINX_NS}" --create-namespace \
  --set controller.ingressClassResource.name=nginx \
  --set controller.ingressClassResource.enabled=true \
  --set controller.ingressClassResource.default=true \
  --set controller.watchIngressWithoutClass=true \
  --set controller.useIngressClassOnly=false \
  --set controller.extraArgs.ingress-class-by-name=true \
  --wait

kubectl annotate ingressclass nginx \
  ingressclass.kubernetes.io/is-default-class="true" --overwrite

LB_IP="$(kubectl -n "${NGINX_NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "LoadBalancer IP: ${LB_IP:-<pending>}"
