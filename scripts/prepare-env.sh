#!/usr/bin/env bash
set -euo pipefail

# Load local env if present (safe; .env is gitignored)
if [[ -f ".env" ]]; then
  # shellcheck disable=SC1091
  source .env
fi

: "${PROJECT_ID:=$(gcloud config get-value core/project 2>/dev/null || true)}"
: "${REGION:=$(gcloud config get-value compute/region 2>/dev/null || true)}"
: "${CLUSTER_NAME:?Set CLUSTER_NAME in .env or env}"

: "${NAMESPACE:=default}"
: "${CM_NS:=cert-manager}"
: "${NGINX_NS:=ingress-nginx}"

echo "== Context =="
echo "Project: ${PROJECT_ID}"
echo "Region:  ${REGION}"
echo "Cluster: ${CLUSTER_NAME}"
echo "NS: onyxia=${NAMESPACE}, cert-manager=${CM_NS}, ingress-nginx=${NGINX_NS}"
echo

echo "== gcloud context & kubeconfig =="
gcloud config set project "${PROJECT_ID}" >/dev/null
if [[ -n "${REGION:-}" ]]; then
  gcloud config set compute/region "${REGION}" >/dev/null
fi
gcloud container clusters get-credentials "${CLUSTER_NAME}" --region "${REGION}" >/dev/null

echo "== Ensure namespaces =="
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create ns "${NAMESPACE}"
kubectl get ns "${CM_NS}"       >/dev/null 2>&1 || kubectl create ns "${CM_NS}"
kubectl get ns "${NGINX_NS}"    >/dev/null 2>&1 || kubectl create ns "${NGINX_NS}"

echo "== Helm repos =="
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update >/dev/null

echo "== Install/upgrade cert-manager (idempotent) =="
helm upgrade --install cert-manager jetstack/cert-manager \
  -n "${CM_NS}" \
  --version v1.18.2 \
  --set crds.enabled=true \
  --set startupapicheck.enabled=false \
  --set global.leaderElection.namespace="${CM_NS}" \
  --wait

echo "== Install/upgrade ingress-nginx (no default cert yet) =="
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n "${NGINX_NS}" \
  --set controller.ingressClassResource.name=nginx \
  --set controller.ingressClassResource.enabled=true \
  --set controller.ingressClassResource.default=true \
  --set controller.watchIngressWithoutClass=true \
  --set controller.useIngressClassOnly=false \
  --wait

echo "== Make nginx the default IngressClass (idempotent) =="
kubectl annotate ingressclass nginx \
  ingressclass.kubernetes.io/is-default-class="true" --overwrite

echo "== Get external LB IP =="
LB_IP="$(kubectl -n "${NGINX_NS}" get svc ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
echo "LB_IP=${LB_IP}"

echo
echo "Next steps:"
echo "  • Delegate/point DNS for your domain/subdomains to '${LB_IP}'."
echo "  • Then run: scripts/prepare-dns.sh  (to add/update A records in Cloud DNS)"
echo "  • Finally run: scripts/deploy.sh"
