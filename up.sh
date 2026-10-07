#!/usr/bin/env bash
# Instala ArgoCD con kubectl y arranca el app-of-apps (root.yaml) de este repo.
# Uso: ./up.sh            (contra el contexto actual de kubectl, debe ser k3d-*)
#      ALLOW_CONTEXT=1 ./up.sh   (para saltarse la validación del contexto)
set -euo pipefail
cd "$(dirname "$0")"

ARGOCD_VERSION="${ARGOCD_VERSION:-stable}"   # o un tag fijo, ej. v2.13.1
APP_NAMESPACE="sensores"

# 0. Protección: no instalar en un cluster que no sea el local
CONTEXT="$(kubectl config current-context)"
if [[ "$CONTEXT" != k3d-* && "${ALLOW_CONTEXT:-0}" != "1" ]]; then
  echo "El contexto actual es '$CONTEXT', no un cluster k3d. Abortando."
  echo "Cambia con: kubectl config use-context k3d-<nombre>  (o ALLOW_CONTEXT=1 ./up.sh)"
  exit 1
fi
echo ">> Contexto: $CONTEXT"

# 1. Instalar ArgoCD
echo ">> Instalando ArgoCD ($ARGOCD_VERSION)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd --server-side --force-conflicts \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# 2. Health check de Applications (para que las sync-waves esperen a Healthy)
echo ">> Aplicando argocd-cm-patch.yaml"
kubectl -n argocd patch configmap argocd-cm --patch-file argocd-cm-patch.yaml
kubectl -n argocd rollout restart statefulset/argocd-application-controller
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# 3. App-of-apps: crea db, backend, frontend e ingress desde apps/
echo ">> Aplicando root.yaml"
kubectl apply -f root.yaml

# 4. Esperar al backend (su Job PostSync corre alembic y crea el esquema) y cargar el seed
echo ">> Esperando a que exista la Application backend..."
until kubectl -n argocd get application backend >/dev/null 2>&1; do sleep 5; done
kubectl -n argocd wait application/backend \
  --for=jsonpath='{.status.operationState.phase}'=Succeeded --timeout=900s
kubectl -n argocd wait application/backend \
  --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s

echo ">> Cargando seed (idempotente)"
kubectl -n "$APP_NAMESPACE" rollout status deploy/db-deployment --timeout=300s
kubectl -n "$APP_NAMESPACE" exec -i deploy/db-deployment -- \
  psql -U postgres -d postgres -v ON_ERROR_STOP=1 < sql/seed_pablodevops.sql

# 5. Resumen
echo
kubectl -n argocd get applications
echo
echo ">> Password admin de ArgoCD:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo ">> UI:  kubectl -n argocd port-forward svc/argocd-server 8080:443   -> https://localhost:8080 (admin)"
echo ">> App: http://pablodevops.store  (requiere 127.0.0.1 pablodevops.store en /etc/hosts"
echo "        y k3d con -p \"80:80@loadbalancer\" o: kubectl -n kube-system port-forward svc/traefik 80:80)"
