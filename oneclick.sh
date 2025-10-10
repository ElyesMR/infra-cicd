#!/usr/bin/env bash
set -euo pipefail

# ---------- paramètres ----------
CLUSTER="${CLUSTER:-cicd}"
ARGO_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
REPO_URL="${REPO_URL:-https://github.com/ElyesMR/infra-cicd}"
REPO_BRANCH="${REPO_BRANCH:-main}"
# --------------------------------

# écris les logs sur STDERR pour ne pas polluer les sorties capturées
say(){ printf "\n\033[1;36m▶ %s\033[0m\n" "$*" >&2; }

need(){ command -v "$1" >/dev/null 2>&1; }

check_docker(){
  if ! need docker; then echo "❌ Installe Docker Desktop puis relance."; exit 1; fi
  if ! docker info >/dev/null 2>&1; then echo "❌ Docker daemon non démarré."; exit 1; fi
}

ensure_kubectl(){
  if ! need kubectl; then
    say "Install kubectl…"
    curl -fsSL "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" -o kubectl
    chmod +x kubectl && sudo mv kubectl /usr/local/bin/
  fi
}

ensure_k3d(){
  if ! need k3d; then
    say "Install k3d…"
    curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
  fi
}

clone_repo(){
  TMPDIR="$(mktemp -d)"
  say "Clonage de l'infra: $REPO_URL ($REPO_BRANCH)"
  git clone -q --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$TMPDIR/infra-cicd"
  echo "$TMPDIR"
}

create_cluster(){
  if k3d cluster list | awk 'NR>1{print $1}' | grep -qx "$CLUSTER"; then
    say "Cluster k3d '$CLUSTER' déjà présent — on continue."
  else
    say "Création du cluster k3d '$CLUSTER'…"
    k3d cluster create "$CLUSTER" --wait
  fi
  kubectl config use-context "k3d-$CLUSTER" >/dev/null
}

install_argo(){
  ROOT="$1"
  say "Namespaces + Argo CD"
  kubectl apply -f "$ROOT/namespaces/"
  kubectl apply -n argocd -f "$ARGO_MANIFEST"
  say "Attente argocd-server…"
  kubectl -n argocd rollout status deploy/argocd-server --timeout=300s || true
}

apply_app(){
  ROOT="$1"
  say "Application Argo CD"
  kubectl apply -n argocd -f "$ROOT/argocd/app.yaml"
  kubectl -n argocd annotate app app-cicd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

wait_and_probe(){
  say "Attente du déploiement applicatif…"
  kubectl -n dev rollout status deploy/app-cicd --timeout=300s || true

  say "Test HTTP (port-forward auto)"
  kubectl -n dev port-forward svc/app-cicd 8888:8888 >/dev/null 2>&1 &
  PF=$!
  sleep 2
  curl -fsS http://localhost:8888/ || echo "⚠ Test HTTP non concluant."
  kill $PF >/dev/null 2>&1 || true
}

main(){
  check_docker
  ensure_kubectl
  ensure_k3d
  WORKDIR="$(clone_repo)"
  pushd "$WORKDIR/infra-cicd" >/dev/null
  create_cluster
  install_argo "$(pwd)"
  apply_app "$(pwd)"
  wait_and_probe
  popd >/dev/null

  say "Terminé ✅"
  cat <<EOF

Commandes utiles :
  kubectl -n argocd get application app-cicd -o jsonpath='{.status.sync.status}{" / "}{.status.health.status}{"\n"}'
  kubectl -n dev get pods,svc
  kubectl -n dev port-forward svc/app-cicd 8888:8888

UI ArgoCD :
  kubectl -n argocd port-forward svc/argocd-server 8080:80
  # http://localhost:8080  (user: admin)
  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
EOF
}
main "$@"
