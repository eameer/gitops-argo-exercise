#!/usr/bin/env bash
# Sets up a local GitOps cluster using kind + ArgoCD.
# Usage: ./scripts/bootstrap-local.sh --repo <github-url>
set -euo pipefail

CLUSTER_NAME="gitops-local"
ARGOCD_NAMESPACE="argocd"
ARGOCD_HOSTNAME="argocd.127.0.0.1.nip.io"
REPO_URL=""

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# parse args
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo) REPO_URL="$2"; shift 2 ;;
    *) echo "unknown arg: $1. Usage: $0 --repo <url>" >&2; exit 1 ;;
  esac
done

if [[ -z "$REPO_URL" ]]; then
  echo "error: --repo is required" >&2
  echo "  e.g. $0 --repo https://github.com/you/gitops-argo-exercise.git" >&2
  exit 1
fi

# check deps
echo "checking prerequisites..."
for cmd in kind helm docker argocd; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "  missing: $cmd — install it and re-run" >&2
    exit 1
  fi
done
echo "  all good"

# create cluster (skip if it already exists)
if kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; then
  echo "cluster '$CLUSTER_NAME' already exists, skipping"
else
  echo "creating kind cluster..."
  kind create cluster --name "$CLUSTER_NAME" --config "$REPO_ROOT/kind/cluster-config.yaml"
fi

# install keycloak-realm chart
# echo "installing keycloak realm chart..."
# helm upgrade --install keycloak-realm "$REPO_ROOT/charts/keycloak-realm" \
#   --namespace keycloak \
#   --create-namespace \
#   --wait --timeout 5m

# # install keycloak
# echo "installing keycloak..."
# helm repo add bitnami https://charts.bitnami.com/bitnami
# helm repo update
# helm upgrade --install keycloak bitnami/keycloak \
#   --namespace keycloak \
#   --create-namespace \
#   --set auth.adminUser=admin \
#   --set auth.adminPassword=admin \
#   --set production=false \
#   --set ingress.enabled=true \
#   --set ingress.ingressClassName=nginx \
#   --set ingress.hostname=keycloak.127.0.0.1.nip.io \
#   --set "extraEnvVars[0].name=KEYCLOAK_EXTRA_ARGS" \
#   --set "extraEnvVars[0].value=--import-realm" \
#    --set "extraVolumes[0].name=realm-config" \
#    --set "extraVolumes[0].configMap.name=keycloak-realm" \
#    --set "extraVolumeMounts[0].name=realm-config" \
#   --set "extraVolumeMounts[0].mountPath=/opt/bitnami/keycloak/data/import" \
#   --wait --timeout 5m

# install nginx and argocd
echo "installing cluster bootstrap..."
helm dep update "$REPO_ROOT/charts/cluster-bootstrap"
helm upgrade --install cluster-bootstrap "$REPO_ROOT/charts/cluster-bootstrap" \
  --namespace "$ARGOCD_NAMESPACE" \
  --create-namespace \
  --set rootApp.repoURL="$REPO_URL" \
  --wait --timeout 5m

# just reading the password to print it — no login needed
ARGOCD_PASSWORD=$(argocd admin initial-password -n "$ARGOCD_NAMESPACE" | head -1)

echo ""
echo "done!"
echo ""
echo "  keycloak:   http://keycloak.127.0.0.1.nip.io"
echo "  user:       admin"
echo "  password:   admin"
# echo "  (An 'argocd' realm was created with a test user)"
# echo "  test user:  gitops"
# echo "  password:   gitops"
echo ""
echo "  argocd:     http://$ARGOCD_HOSTNAME"
echo "  user:       admin"
echo "  password:   $ARGOCD_PASSWORD"
echo ""
echo "  sample app: http://sample-app.127.0.0.1.nip.io"
echo "              (give argocd a minute to sync)"
echo ""
echo "  to tear down: kind delete cluster --name $CLUSTER_NAME"
