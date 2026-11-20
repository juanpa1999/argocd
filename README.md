# argocd

GitOps deployment, with **ArgoCD**, of the three-tier sensor monitoring application
(temperature, humidity and weight): **db** (PostgreSQL), **backend**, **frontend** and
**ingress**.

This repo (`https://github.com/juanpa1999/argocd`) contains **no charts** — it only
declares *what* is deployed and *with which values*. Two repos are involved:

| Repo | Role |
|------|------|
| `juanpa1999/argocd` (this one) | `root.yaml` + `apps/<app>/{application,values}.yaml`. ArgoCD watches it. |
| `juanpa1999/helm-chart` | Chart sources + `charts/*.tgz` + `index.yaml`, served by GitHub Pages as the Helm repo `https://juanpa1999.github.io/helm-chart`. |

Each ArgoCD `Application` pulls a **pinned chart version** from that Helm repo and
combines it with the overrides in `apps/<app>/values.yaml` from this repo (ArgoCD
multi-source).

The target cluster is **k3s / k3d**, with **Traefik** as ingress controller
(IngressClass `traefik`). The `ingress` chart depends on it (Traefik `Middleware` CRD).

## Architecture

```
  git: juanpa1999/argocd                         Helm repo (GitHub Pages, repo juanpa1999/helm-chart)
  ├── root.yaml                                  juanpa1999.github.io/helm-chart
  └── apps/<app>/{application,values}.yaml       db 0.1.0 · backend 0.3.0 · frontend 0.2.0 · ingress 0.1.0
                 │                                          │
                 ▼                                          │
   ArgoCD  Application "root"  (app-of-apps, ns argocd)     │
                 │ creates one Application per apps/*/application.yaml
                 ▼                                          │
   ┌────────┬───────────┬────────────┬───────────┐          │
   │ db     │ backend   │ frontend   │ ingress   │ ◄────────┘ chart (pinned version)
   │ wave 0 │ wave 1    │ wave 2     │ wave 3    │ ◄── $values/apps/<app>/values.yaml (git)
   └───┬────┴─────┬─────┴─────┬──────┴─────┬─────┘
       ▼          ▼           ▼            ▼
                 namespace "default"

                  Browser → http://pablodevops.store
                                │
          kubectl port-forward svc/traefik 80:80 (kube-system)
                                ▼
                 Traefik (host: pablodevops.store)
             /api (StripPrefix) │            │ /
                                ▼            ▼
                back-service :8000       front-service :3000
                                │
                                ▼
                       db-service :5432
```

| App        | Chart (version)    | Image               | Service                    | Resources                                               | Wave |
|------------|--------------------|---------------------|----------------------------|---------------------------------------------------------|------|
| `db`       | `db` 0.1.0         | `jpcc141999/db1`    | `db-service` :5432         | `db-deployment`                                         | 0    |
| `backend`  | `backend` 0.3.0    | `jpcc141999/back3`  | `back-service` :8000       | `back-deployment` + Job `back-deployment-migrate` (PostSync) | 1 |
| `frontend` | `frontend` 0.2.0   | `jpcc141999/front4` | `front-service` :3000      | `front-deploy`                                          | 2    |
| `ingress`  | `ingress` 0.1.0    | —                   | — (uses Traefik)           | Ingress `ingress-backend`, `ingress-frontend` + Middleware `ingress-strip-api` | 3 |

## Structure

```
.
├── root.yaml                  # app-of-apps: the only manual kubectl apply
├── argocd-cm-patch.yaml       # Application health check so sync-waves wait for Healthy
├── apps/
│   ├── db/{application,values}.yaml
│   ├── backend/{application,values}.yaml
│   ├── frontend/{application,values}.yaml
│   └── ingress/{application,values}.yaml
└── sql/
    └── seed_pablodevops.sql   # Test data (user, sensors, 24 h of readings) — applied manually
```

- `application.yaml`: chart + **pinned version** (`targetRevision`), `releaseName`,
  sync-wave, destination namespace `default`.
- `values.yaml`: **only the overrides** over the chart's own `values.yaml`.
- `root.yaml` only reads `apps/*/application.yaml` (`directory.include`), so the
  `values.yaml` files are never applied as manifests.

## Requirements

- A k3s / k3d cluster with Traefik enabled and `kubectl` pointing at it.
- ArgoCD **2.6+** (multi-source Applications).
- This folder pushed to `https://github.com/juanpa1999/argocd.git`, branch `main`, with
  `apps/` and `root.yaml` at the **repo root** (`root.yaml` and the `$values` source of
  each app point there).
- The chart versions referenced in `apps/*/application.yaml` published in
  `https://juanpa1999.github.io/helm-chart` (`helm search repo pablo-charts --versions`).
- If `juanpa1999/argocd` is private, register it in ArgoCD
  (`argocd repo add https://github.com/juanpa1999/argocd.git --username ... --password <PAT>`).

## Deploy

```bash
# 1. Install ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 2. Make sync-waves wait for each Application to be Healthy
kubectl -n argocd patch configmap argocd-cm --patch-file argocd-cm-patch.yaml

# 3. Bootstrap the app-of-apps (only manual apply)
kubectl apply -f root.yaml

# 4. Test data (user, sensors, readings) — idempotent, after db is Healthy
kubectl -n default exec -i deploy/db-deployment -- \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 < sql/seed_pablodevops.sql
```

ArgoCD UI:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443   # https://localhost:8080, user admin
```

**Test user:** the seed creates the user `pablodevops` (role `master`).

## Day-2 changes (always via git commit)

| Change                                     | Where                                                      |
|--------------------------------------------|------------------------------------------------------------|
| Config / image tag / replicas              | `apps/<app>/values.yaml`                                   |
| New chart version                          | Publish it from `juanpa1999/helm-chart`, then bump `targetRevision` in `apps/<app>/application.yaml` here |
| Rollback                                   | Revert the commit (or set the previous `targetRevision`)   |

All Applications use `automated` sync with `prune: true` and `selfHeal: true`: manual
`kubectl`/`helm` changes on these resources are reverted by ArgoCD.

### Gotchas

- **`latest` tags**: ArgoCD only redeploys when the rendered manifest changes in git.
  Pushing a new image under the same `latest` tag does nothing — pin real tags in
  `apps/<app>/values.yaml`.
- **Migrations**: the chart's `post-install,post-upgrade` hook runs as an ArgoCD
  `PostSync` hook, i.e. `alembic upgrade head` on **every** sync of `backend`. If it
  fails the Job is kept: `kubectl -n default logs job/back-deployment-migrate`.
- **`releaseName` of `ingress` must stay `ingress`**: the Traefik Middleware annotation is
  built as `<namespace>-<release>-strip-api@kubernetescrd` (`default-ingress-strip-api`).
- **DB persistence** is disabled (`apps/db/values.yaml`): if the pod is recreated, data
  and the seed are lost. Enable `persistence.enabled` to keep them.
- **Secrets**: `DB_PASSWORD` is a plain value in the backend chart (`extraEnv`) and the DB
  credentials live inside the `jpcc141999/db1` image. Fine for local, not for real envs.

### Values that must stay in sync

| What                  | Where                                                                                       |
|-----------------------|---------------------------------------------------------------------------------------------|
| DB service name       | `db` → `service.name` = `backend` → `db.host` (`db-service`)                                |
| Backend service name  | `backend` → `service.name` = `ingress` → `backend.serviceName` (`back-service`)             |
| Frontend service name | `frontend` → `service.name` = `ingress` → `frontend.serviceName` (`front-service`)          |
| Public host           | `ingress` → `host` + `frontend` → `REACT_APP_API_URL` + `backend` → `NGROK` (CORS) + `/etc/hosts` |
| API path              | `ingress` → `backend.path` (`/api`) = suffix of `frontend` → `REACT_APP_API_URL`            |

Preview what ArgoCD will render (run outside a folder that contains chart dirs, or Helm
uses the local chart instead of the repo):

```bash
helm template backend backend --repo https://juanpa1999.github.io/helm-chart \
  --version 0.3.0 -n default -f apps/backend/values.yaml
```

## Local access through the Ingress

1. Point the host to localhost in `/etc/hosts` (Windows:
   `C:\Windows\System32\drivers\etc\hosts`):

   ```
   127.0.0.1   pablodevops.store
   ```

   On macOS flush DNS if needed: `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`.

2. Port-forward Traefik on **local port 80** (the frontend calls
   `http://pablodevops.store/api` and CORS only allows that origin, both without port):

   ```bash
   kubectl -n kube-system port-forward svc/traefik 80:80
   ```

   Or create the k3d cluster with `-p "80:80@loadbalancer"` and skip the port-forward.

| URL                                   | Goes to                                         |
|---------------------------------------|-------------------------------------------------|
| `http://pablodevops.store/`           | `front-service:3000`                            |
| `http://pablodevops.store/api/<path>` | `back-service:8000/<path>` (`/api` is stripped) |

Quick checks:

```bash
kubectl -n argocd get applications
kubectl -n default get pods,svc,ingress,middleware
curl -i -H 'Host: pablodevops.store' http://127.0.0.1/
```

## Cleanup

```bash
# No Application has the resources-finalizer, so deleting them does NOT delete the
# workloads: delete root + the 4 apps, then the namespace.
kubectl -n argocd delete application root db backend frontend ingress
kubectl delete namespace default
```

Remove the `pablodevops.store` line from your hosts file if you no longer need it.
