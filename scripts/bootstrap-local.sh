#!/usr/bin/env bash
# bootstrap-local.sh — Full local GitOps setup in one command.
#
# Usage:
#   ./scripts/bootstrap-local.sh --repo https://github.com/your-org/your-repo.git
#   ./scripts/bootstrap-local.sh --repo https://github.com/your-org/your-repo.git --api-key my-secret
#
# Prerequisites: kind, helm, docker, argocd (CLI)
set -euo pipefail

CLUSTER_NAME="gitops-local"
ARGOCD_NAMESPACE="argocd"
ARGOCD_VERSION="7.7.16"
ARGOCD_HOSTNAME="argocd.127.0.0.1.nip.io"
NGINX_INGRESS_VERSION="4.10.1"
REPO_URL=""
API_KEY="local-dev-key"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─── Colors ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[info]${NC} $*"; }
success() { echo -e "${GREEN}[ok]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[warn]${NC} $*"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)    REPO_URL="$2";  shift 2 ;;
    --api-key) API_KEY="$2";   shift 2 ;;
    *) echo "Unknown argument: $1" >&2
       echo "Usage: $0 --repo <url> [--api-key <value>]" >&2
       exit 1 ;;
  esac
done

if [[ -z "$REPO_URL" ]]; then
  echo "Error: --repo is required." >&2
  echo "Usage: $0 --repo https://github.com/your-org/your-repo.git" >&2
  exit 1
fi

# ─── Prerequisite check ───────────────────────────────────────────────────────
info "Checking prerequisites..."
for cmd in kind helm docker argocd; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: '$cmd' is not installed. Please install it and retry." >&2
    exit 1
  fi
done
success "All prerequisites found."

# ─── Create kind cluster ──────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  info "Creating kind cluster '${CLUSTER_NAME}'..."
  kind create cluster \
    --name "$CLUSTER_NAME" \
    --config "${REPO_ROOT}/kind/cluster-config.yaml"
  success "Cluster created."
fi

# ─── Helm repos ───────────────────────────────────────────────────────────────
info "Updating Helm repos..."
helm repo add argo           https://argoproj.github.io/argo-helm  --force-update
helm repo add ingress-nginx  https://kubernetes.github.io/ingress-nginx --force-update
helm repo update argo ingress-nginx

# ─── nginx ingress controller ─────────────────────────────────────────────────
info "Installing nginx ingress controller ${NGINX_INGRESS_VERSION}..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --version "$NGINX_INGRESS_VERSION" \
  --set controller.hostPort.enabled=true \
  --set controller.tolerations[0].key="node-role.kubernetes.io/control-plane" \
  --set controller.tolerations[0].operator="Equal" \
  --set controller.tolerations[0].effect="NoSchedule" \
  --set-string controller.nodeSelector."ingress-ready"="true" \
  --set controller.service.type=NodePort \
  --wait \
  --timeout 3m
success "nginx ingress ready."

# ─── ArgoCD ───────────────────────────────────────────────────────────────────
info "Installing ArgoCD ${ARGOCD_VERSION}..."
helm upgrade --install argocd argo/argo-cd \
  --namespace "$ARGOCD_NAMESPACE" \
  --create-namespace \
  --version "$ARGOCD_VERSION" \
  --values "${REPO_ROOT}/kind/argocd-values.yaml" \
  --wait \
  --timeout 5m
success "ArgoCD installed."

# ─── ArgoCD login ─────────────────────────────────────────────────────────────
ARGOCD_PASSWORD=$(argocd admin initial-password -n "$ARGOCD_NAMESPACE" | head -1)

info "Logging in to ArgoCD..."
argocd login "$ARGOCD_HOSTNAME" \
  --username admin \
  --password "$ARGOCD_PASSWORD" \
  --insecure \
  --grpc-web
success "Logged in."

# ─── Source secret (ESO reads from this) ──────────────────────────────────────
info "Creating ESO source secret..."
helm upgrade --install source-secrets "${REPO_ROOT}/charts/source-secrets" \
  --namespace external-secrets \
  --create-namespace \
  --set apiKey="${API_KEY}"
success "Source secret created."

# ─── Bootstrap App of Apps ────────────────────────────────────────────────────
info "Creating ArgoCD root application..."
argocd app create root \
  --repo "$REPO_URL" \
  --path bootstrap/apps \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace "$ARGOCD_NAMESPACE" \
  --sync-policy automated \
  --auto-prune \
  --self-heal \
  --upsert
success "Root app created — ArgoCD is now managing the cluster."

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Bootstrap complete                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ArgoCD:    ${CYAN}http://${ARGOCD_HOSTNAME}${NC}"
echo -e "  Username:  admin"
echo -e "  Password:  ${YELLOW}${ARGOCD_PASSWORD}${NC}"
echo ""
echo -e "  Sample app: ${CYAN}http://sample-app.127.0.0.1.nip.io${NC}"
echo -e "              (available once ArgoCD syncs sample-app)"
echo ""
echo -e "${YELLOW}Teardown:${NC} kind delete cluster --name ${CLUSTER_NAME}"
echo ""
