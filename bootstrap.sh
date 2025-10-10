#!/usr/bin/env bash
set -euo pipefail

CLUSTER=cicd

echo "1) Création du cluster k3d..."
k3d cluster create "$CLUSTER" --wait

echo "2) Namespaces..."
kubectl apply -f namespaces/

echo "3) Installation d'Argo CD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "4) Attente du serveur ArgoCD..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s || true

echo "5) Déclaration de l'application..."
kubectl apply -n argocd -f argocd/app.yaml

echo " Terminé."
echo "Test:"
echo "  kubectl -n dev port-forward svc/app-cicd 8888:8888"
echo "  curl http://localhost:8888/"
