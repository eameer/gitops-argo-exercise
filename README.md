# GitOps ArgoCD Exercise

A local GitOps playground using kind, ArgoCD, and GitHub Actions. No cloud account needed — everything runs on your laptop.

---

## How it works (big picture)

```
                        GitHub
          ┌─────────────────────────────────┐
          │                                 │
          │  push to app/** on develop      │
          │    → build + push image (GHCR)  │
          │    → commit new tag to dev      │
          │                                 │
          │  merge develop → main           │
          │    → copy dev tag → prod        │
          │                                 │
          └──────────────┬──────────────────┘
                         │ ArgoCD polls git
                         ▼
          ┌──────────────────────────────────────────┐
          │              kind cluster                 │
          │                                           │
          │  ArgoCD (App of Apps)                     │
          │    root app → bootstrap/apps/             │
          │      ├── monitoring                       │
          │      ├── sample-app      (dev overlay)    │
          │      └── sample-app-prod (prod overlay)   │
          │                                           │
          │  nginx ingress → *.127.0.0.1.nip.io       │
          └──────────────────────────────────────────┘
```

The repo is the source of truth. ArgoCD watches it and keeps the cluster in sync. If something drifts (someone `kubectl apply`s manually, a pod crashes, etc.), ArgoCD fixes it.

| Layer | What | Notes |
|---|---|---|
| Cluster | kind | Single node in Docker |
| GitOps | ArgoCD | App of Apps pattern |
| Ingress | nginx | Ports 80/443 mapped to localhost |
| DNS | nip.io | `*.127.0.0.1.nip.io` → 127.0.0.1 — no `/etc/hosts` needed |
| Environments | Kustomize overlays | dev and prod have separate namespaces, resources, hostnames, image tags |
| CI/CD | GitHub Actions | Uses `GITHUB_TOKEN` — no extra secrets |
| Images | GHCR | Free with GitHub |
| Observability | Loki + Promtail + Prometheus + Grafana | Logs and metrics |

---

## Prerequisites

- Docker
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [helm](https://helm.sh/docs/intro/install/)
- [argocd CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/) (just for reading the initial password)

---

## Standing up the cluster

### 1. Fork this repo and push to GitHub

ArgoCD needs to pull from a real remote. Fork it, push to `develop`, and grab the URL — you'll need it in the next step.

One thing to sort out early: GHCR packages are private by default. After the first CI run creates the image, go to GitHub → Packages → the package → Change visibility → Public. Otherwise the kind cluster can't pull it (you'd need `imagePullSecrets`).

### 2. Run the bootstrap script

```bash
./scripts/bootstrap-local.sh --repo https://github.com/your-org/your-repo.git
```

This does everything in one shot:
1. Creates a kind cluster with ports 80/443 mapped to localhost
2. Downloads the nginx and ArgoCD Helm chart tarballs (`helm dep update`)
3. Installs both via a single umbrella chart release
4. Drops a root ArgoCD `Application` via a Helm post-install hook — from here the cluster manages itself
5. Prints the admin password

### 3. Open ArgoCD and wait

```
http://argocd.127.0.0.1.nip.io
admin / <password from the script>
```

ArgoCD picks up everything in `bootstrap/apps/` and starts syncing. Give it a few minutes. When all apps are green:

| URL | What |
|---|---|
| http://dev.sample-app.127.0.0.1.nip.io | Sample app (dev) |
| http://sample-app.127.0.0.1.nip.io | Sample app (prod) |
| http://grafana.127.0.0.1.nip.io | Grafana — `admin` / `grafana` |

---

## Deploying via GitOps

The app manifests are in `k8s/sample-app/` split into a base and two overlays:

```
k8s/sample-app/
  base/          ← Deployment, Service, Ingress, Namespace (no hardcoded env details)
  overlays/
    dev/         ← sets namespace, image tag, hostname, resource limits
    prod/        ← same + 2 replicas and higher limits
```

ArgoCD watches the repo and reconciles on every git change. There's no `helm install`, no `kubectl apply` — you just push to git.

What's different between environments:

| | dev | prod |
|---|---|---|
| Namespace | `sample-app-dev` | `sample-app-prod` |
| Replicas | 1 | 2 |
| CPU limit | 100m | 500m |
| Memory limit | 128Mi | 512Mi |
| Image tag | auto-updated by CI | promoted from dev on merge to `main` |

---

## Triggering an update

### Updating dev (automatic)

Push a change under `app/**` to `develop`:

```bash
git push origin develop
```

CI (`app-build.yml`) builds the image, pushes it to GHCR with the commit SHA as the tag, then commits the new tag into `overlays/dev/kustomization.yaml`. ArgoCD sees the manifest change and syncs dev.

### Promoting to prod

Open a PR from `develop` to `main` and merge it. CI (`promote-prod.yml`) reads the current tag from the dev overlay and writes it into the prod overlay. ArgoCD syncs prod to that exact image.

Prod never gets an image that wasn't in dev first — the promotion copies a specific SHA, not "latest".

### Forcing a sync manually

```bash
argocd app sync sample-app
argocd app sync sample-app-prod
```

---

## Observability

The app logs one JSON line per request to stdout:

```json
{"method": "GET", "path": "/", "status": 200, "duration_ms": 0.42, "client": "10.244.0.1"}
```

Promtail picks that up automatically (no sidecar, no log files) and ships it to Loki. Prometheus scrapes pod/node metrics cluster-wide. Both are pre-wired into Grafana.

In Grafana → Explore:
- Logs: `{namespace="sample-app-dev"}` or `{namespace="sample-app-prod"}`
- Metrics: standard PromQL against the Prometheus datasource

---

## Reliability considerations

- **Readiness + liveness probes** on `/health` — pods only get traffic when ready, and get restarted if they hang
- **2 replicas in prod** — tolerates a single pod failure; on a real multi-node cluster this also handles node failures
- **ArgoCD self-heal** — drift gets corrected automatically within the sync interval
- **Image promotion gate** — prod always runs a tag that was previously live in dev

What this setup doesn't have that a real system would: pod disruption budgets, horizontal autoscaling, and anti-affinity rules (hard to demonstrate on a single-node cluster).

---

## Security considerations

**ArgoCD RBAC** — `policy.default: role:readonly` means any authenticated user that isn't explicitly granted a role gets read-only access. The `admin` account is mapped to `role:admin` in `argocd-rbac-cm`.

**No stored credentials in CI** — GHCR auth uses the built-in `GITHUB_TOKEN`, scoped to the repo and gone after each run. The only permission the workflow requests is `contents: write` (to commit the tag back) and `packages: write` (to push the image).

**Namespace isolation** — dev and prod are in separate namespaces, so a bad deploy in dev can't directly affect prod.

**Resource limits** — every container has limits set per overlay to prevent runaway resource usage.

**What's intentionally skipped here:** TLS is disabled (`server.insecure: true`) because self-signed certs add friction for a local exercise. In production you'd use cert-manager at the ingress. Similarly, the ArgoCD `admin` account should be replaced with a named user (or SSO) before anything goes near a real environment.

---

## Assumptions and tradeoffs

**kind as the cluster** — kind is a single Docker container, not production-grade. Persistent volumes don't survive cluster deletion. The tradeoff is zero cost and one-command reproducibility. Good enough for demonstrating the GitOps pattern.

**nip.io for DNS** — convenient because it requires no setup, but it makes a network call to an external DNS service. A fully offline setup would need something like a local CoreDNS override or `/etc/hosts` entries instead.

**Automated sync on prod** — both dev and prod sync automatically. A lot of teams would gate prod on a manual approval. I left it automated here because the promotion workflow already acts as a gate (you have to explicitly merge to `main`), but it's a reasonable thing to change.

**Prometheus retention is ephemeral** — metrics live in Prometheus inside the cluster. Delete the cluster, lose the history. For anything real you'd want remote storage (Thanos, Grafana Mimir, or a managed option).

**Single branch as ArgoCD source** — both ArgoCD apps point at `develop`. The image tag differs, but infrastructure changes (manifest edits) hit both environments at the same time. A stricter setup would have prod track a separate branch or a tagged release.

---

## What I'd improve with more time

**Named ArgoCD user** — the built-in `admin` account can't be audited per-action. I'd add a named account in `argocd-cm`, map it to `role:admin`, and disable `admin`. Simple config change, but it makes audit logs meaningful.

**TLS** — cert-manager is easy to add to the bootstrap, and a self-signed ClusterIssuer takes about 10 lines. ArgoCD and Grafana should be serving HTTPS even locally to match production posture.

**Manual prod sync** — remove `automated:` from `sample-app-prod`'s sync policy so a human has to click "Sync" (or use the ArgoCD CLI) to push to prod. The current flow is fine, but a lot of orgs want that extra confirmation step.

**Image scanning** — add a `trivy` step in `app-build.yml` that blocks the push if the image has high/critical CVEs. Currently anything that builds gets deployed.

**PR validation** — a GitHub Actions workflow that runs `kustomize build` on pull requests catches broken manifests before they merge. Takes about 5 minutes to add, saves a lot of "why is ArgoCD red" debugging.

**HPA on prod** — replace the fixed `replicas: 2` with a HorizontalPodAutoscaler that scales based on CPU. Makes the resource limits and Prometheus setup actually do something interesting.

---

## Teardown

```bash
kind delete cluster --name gitops-local
```

That's it. GHCR images and the Git repo are untouched.

---

## Repo layout

```
├── .github/workflows/
│   ├── app-build.yml           # build → push → update dev tag
│   └── promote-prod.yml        # merge to main → copy dev tag to prod
├── app/
│   ├── Dockerfile
│   └── main.py                 # tiny HTTP server, JSON logs
├── bootstrap/
│   └── apps/                   # ArgoCD Applications (App of Apps children)
│       ├── monitoring.yaml
│       ├── sample-app.yaml
│       └── sample-app-prod.yaml
├── charts/
│   └── cluster-bootstrap/      # umbrella chart: nginx + ArgoCD + root Application hook
├── k8s/
│   ├── argocd-config/          # argocd-cm and argocd-rbac-cm
│   └── sample-app/
│       ├── base/
│       └── overlays/
│           ├── dev/
│           └── prod/
├── kind/
│   └── cluster-config.yaml
└── scripts/
    └── bootstrap-local.sh
```
