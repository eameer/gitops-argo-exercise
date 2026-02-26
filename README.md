# GitOps ArgoCD Exercise

Reproducible local GitOps setup: kind cluster bootstrapped with ArgoCD, CI/CD via GitHub Actions.

## Architecture

| Layer | Technology | Notes |
|---|---|---|
| Cluster | [kind](https://kind.sigs.k8s.io/) | Runs in Docker, no cloud account needed |
| GitOps | ArgoCD — App of Apps pattern | Self-managing after bootstrap |
| Ingress | nginx ingress controller | Port-mapped to localhost 80/443 |
| DNS | nip.io | `*.127.0.0.1.nip.io` → 127.0.0.1, zero config |
| CI/CD | GitHub Actions + `GITHUB_TOKEN` | No extra secrets needed |
| Image registry | GHCR (ghcr.io) | Free, integrated with GitHub |
| Secrets | External Secrets Operator → K8s secret | kubernetes provider, no cloud deps |

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [helm](https://helm.sh/docs/intro/install/)
- [argocd CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/)

## Quick Start

### 1. Fork / clone this repo and push it to GitHub

The bootstrap script needs a reachable Git URL so ArgoCD can sync from it.

### 2. Run the bootstrap script

```bash
./scripts/bootstrap-local.sh --repo https://github.com/your-org/your-repo.git
```

Pass `--api-key` to set a custom API key value (defaults to `local-dev-key`):

```bash
./scripts/bootstrap-local.sh \
  --repo https://github.com/your-org/your-repo.git \
  --api-key my-secret
```

The script:
1. Creates a kind cluster with nginx-ready port mappings
2. Installs the nginx ingress controller via Helm
3. Installs ArgoCD via Helm and logs in automatically
4. Creates the ESO source secret via Helm (no kubectl needed)
5. Creates the ArgoCD root application — cluster is self-managing from here

### 3. Watch ArgoCD reconcile

Open **http://argocd.127.0.0.1.nip.io** and log in with `admin` / `<password printed by the script>`.

ArgoCD will deploy:
- **external-secrets** — ESO operator
- **sample-app** — your application

### 4. Access the sample app

```bash
curl http://sample-app.127.0.0.1.nip.io
# → Hello from sample-app!
```

## How It Works

### Secrets flow

```
helm install source-secrets (app-source-secrets) → external-secrets ns
  ↓  ESO kubernetes provider  (ClusterSecretStore: local-k8s-store)
K8s Secret (my-app-secret)    → sample-app ns
  ↓  secretKeyRef
sample-app pod env var (API_KEY)
```

### CI/CD flow (GitHub Actions)

```
git push app/**
  → Build Docker image
  → Push to ghcr.io/<org>/<repo>/sample-app:<sha>
  → Update image tag in k8s/sample-app/deployment.yaml
  → Commit & push
  → ArgoCD detects git change → syncs deployment
```

The workflow uses `GITHUB_TOKEN` (built-in) for GHCR — no extra secrets required.

> **Note:** GHCR packages are private by default. Either make the package public
> (GitHub → Packages → Change visibility) or add `imagePullSecrets` to the deployment
> (see the commented-out block in [k8s/sample-app/deployment.yaml](k8s/sample-app/deployment.yaml)).

## Teardown

```bash
kind delete cluster --name gitops-local
```

## Directory Structure

```
├── .github/workflows/
│   └── app-build.yml          # Build → push to GHCR → update manifest tag
├── app/
│   ├── Dockerfile
│   └── main.py                # Sample HTTP server
├── bootstrap/
│   └── apps/
│       ├── external-secrets.yaml
│       └── sample-app.yaml
├── charts/
│   └── source-secrets/        # Helm chart — creates the ESO source secret
├── k8s/
│   ├── argocd-config/         # ArgoCD server URL and RBAC
│   ├── external-secrets/      # ClusterSecretStore (kubernetes provider) + ExternalSecret
│   └── sample-app/            # Namespace, Deployment, Service, Ingress
├── kind/
│   ├── cluster-config.yaml    # kind cluster definition (port mappings)
│   └── argocd-values.yaml     # ArgoCD Helm values for local use
└── scripts/
    └── bootstrap-local.sh     # One-shot setup script
```
