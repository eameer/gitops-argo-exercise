# GitOps ArgoCD Exercise

Reproducible local GitOps setup: kind cluster bootstrapped with ArgoCD, CI/CD via GitHub Actions, dev/prod environment separation via Kustomize overlays.

## Architecture

| Layer | Technology | Notes |
|---|---|---|
| Cluster | [kind](https://kind.sigs.k8s.io/) | Runs in Docker, no cloud account needed |
| GitOps | ArgoCD — App of Apps pattern | Self-managing after bootstrap |
| Ingress | nginx ingress controller | Port-mapped to localhost 80/443 |
| DNS | nip.io | `*.127.0.0.1.nip.io` → 127.0.0.1, zero config |
| Environments | Kustomize overlays | dev and prod differ in replicas, resources, hostname, image tag |
| CI/CD | GitHub Actions + `GITHUB_TOKEN` | No extra secrets needed |
| Image registry | GHCR (ghcr.io) | Free, integrated with GitHub |
| Observability | Loki + Promtail + Grafana | Structured JSON logs from the app |

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [helm](https://helm.sh/docs/intro/install/)
- [argocd CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) — only needed to read the initial admin password

## Quick Start

### 1. Fork / clone and push to GitHub

The bootstrap script needs a reachable Git URL so ArgoCD can sync from it. Make sure you have at least one commit pushed to the `develop` branch.

### 2. Run the bootstrap script

```bash
./scripts/bootstrap-local.sh --repo https://github.com/your-org/your-repo.git
```

The script:
1. Creates a kind cluster with nginx-ready port mappings
2. Runs `helm dep update` to fetch sub-chart tarballs
3. Installs nginx ingress controller + ArgoCD via a single umbrella Helm chart
4. Creates the ArgoCD root Application declaratively (Helm post-install hook)
5. Prints the ArgoCD admin password and UI URL

### 3. Watch ArgoCD reconcile

Open **http://argocd.127.0.0.1.nip.io** and log in with `admin` / `<password printed by the script>`.

ArgoCD will deploy all child apps automatically:

| App | Namespace | What it installs |
|---|---|---|
| `monitoring` | `monitoring` | Loki + Promtail + Grafana |
| `sample-app` | `sample-app-dev` | App — dev overlay (1 replica, dev hostname) |
| `sample-app-prod` | `sample-app-prod` | App — prod overlay (2 replicas, prod hostname) |

### 4. Access the services

| Service | URL |
|---|---|
| Sample app (dev) | http://dev.sample-app.127.0.0.1.nip.io |
| Sample app (prod) | http://sample-app.127.0.0.1.nip.io |
| ArgoCD | http://argocd.127.0.0.1.nip.io |
| Grafana | http://grafana.127.0.0.1.nip.io — `admin` / `grafana` |

```bash
curl http://dev.sample-app.127.0.0.1.nip.io
# → Hello from sample-app!
```

## How It Works

### CI/CD flow

```
Push to app/** on develop branch
  → Build Docker image
  → Push to ghcr.io/<org>/<repo>/sample-app:<sha>
  → Update newTag in k8s/sample-app/overlays/dev/kustomization.yaml
  → Commit & push
  → ArgoCD detects change → syncs dev automatically

Merge develop → main
  → Read dev's current newTag
  → Write same tag into k8s/sample-app/overlays/prod/kustomization.yaml
  → Commit & push
  → ArgoCD detects change → syncs prod
```

> **Note:** GHCR packages are private by default. Either make the package public
> (GitHub → Packages → Change visibility) or add `imagePullSecrets` to the deployment.

### Environment differences (Kustomize overlays)

| | dev | prod |
|---|---|---|
| Namespace | `sample-app-dev` | `sample-app-prod` |
| Replicas | 1 | 2 |
| Hostname | `dev.sample-app.127.0.0.1.nip.io` | `sample-app.127.0.0.1.nip.io` |
| CPU limit | 100m | 500m |
| Memory limit | 128Mi | 512Mi |
| Image tag | updated on every push to `develop` | promoted on merge to `main` |

### Observability

The app emits structured JSON logs on every request:
```json
{"method": "GET", "path": "/", "status": 200, "duration_ms": 0.42, "client": "10.244.0.1"}
```

Promtail collects these automatically from container stdout and ships them to Loki. In Grafana (Explore → Loki) query by namespace:
```
{namespace="sample-app-dev"}
{namespace="sample-app-prod"}
```

## Teardown

```bash
kind delete cluster --name gitops-local
```

## Directory Structure

```
├── .github/workflows/
│   ├── app-build.yml          # Build → push to GHCR → update dev image tag
│   └── promote-prod.yml       # On merge to main → copy dev tag to prod overlay
├── app/
│   ├── Dockerfile
│   └── main.py                # Sample HTTP server (structured JSON logging)
├── bootstrap/
│   └── apps/
│       ├── monitoring.yaml    # Loki + Promtail + Grafana
│       ├── sample-app.yaml    # dev overlay
│       └── sample-app-prod.yaml  # prod overlay
├── charts/
│   └── cluster-bootstrap/    # Umbrella chart: nginx + ArgoCD + root Application hook
├── k8s/
│   ├── argocd-config/        # ArgoCD server URL and RBAC
│   └── sample-app/
│       ├── base/             # Shared manifests (deployment, service, ingress, namespace)
│       └── overlays/
│           ├── dev/          # dev namespace, resources, ingress hostname, image tag
│           └── prod/         # prod namespace, resources, replicas, ingress hostname, image tag
├── kind/
│   └── cluster-config.yaml   # kind cluster definition (port mappings)
└── scripts/
    └── bootstrap-local.sh    # One-shot setup script
```
