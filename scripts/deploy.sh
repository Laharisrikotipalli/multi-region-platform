#!/usr/bin/env bash
# deploy.sh – full multi-region platform deployment
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY}"
: "${ALERT_EMAIL:?Set ALERT_EMAIL}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. Bootstrap S3 state buckets ─────────────────────────────────────────────
for pair in "ap-southeast-1:mr-tfstate-aps1" "eu-west-1:mr-tfstate-euw1" "us-east-1:mr-tfstate-use1"; do
  region="${pair%%:*}"; bucket="${pair##*:}"
  log "Creating state bucket $bucket in $region..."
  aws s3api create-bucket --bucket "$bucket" --region "$region" \
    $([[ "$region" != "us-east-1" ]] && echo "--create-bucket-configuration LocationConstraint=$region") \
    2>/dev/null || true
  aws s3api put-bucket-versioning --bucket "$bucket" --versioning-configuration Status=Enabled
done

# ── 2. Deploy primary region first (RDS primary + Redis Global Datastore) ─────
log "==> Deploying ap-southeast-1 (primary)..."
cd terraform/envs/ap-southeast-1
terraform init -upgrade
terraform apply -auto-approve -var="alert_email=${ALERT_EMAIL}"
cd ../../..

# ── 3. Deploy replica regions in parallel ─────────────────────────────────────
log "==> Deploying eu-west-1 and us-east-1 (replicas)..."
(cd terraform/envs/eu-west-1  && terraform init -upgrade && terraform apply -auto-approve) &
(cd terraform/envs/us-east-1  && terraform init -upgrade && terraform apply -auto-approve) &
wait

# ── 4. Fetch kubeconfigs ───────────────────────────────────────────────────────
log "==> Fetching kubeconfigs..."
aws eks update-kubeconfig --region ap-southeast-1 --name mr-eks-aps1 --kubeconfig /tmp/kc-aps1
aws eks update-kubeconfig --region eu-west-1      --name mr-eks-euw1 --kubeconfig /tmp/kc-euw1
aws eks update-kubeconfig --region us-east-1      --name mr-eks-use1 --kubeconfig /tmp/kc-use1

# ── 5. Install ArgoCD and deploy application on each cluster ──────────────────
for pair in "aps1:/tmp/kc-aps1" "euw1:/tmp/kc-euw1" "use1:/tmp/kc-use1"; do
  region="${pair%%:*}"; kc="${pair##*:}"
  log "==> Bootstrapping ArgoCD on $region..."
  export KUBECONFIG="$kc"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
  kubectl apply -f k8s/namespace.yaml
  kubectl apply -f k8s/argocd-application.yaml
done

# ── 6. Install observability stack (Prometheus + Grafana + Loki + Tempo) ───────
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana              https://grafana.github.io/helm-charts
helm repo update

for pair in "aps1:/tmp/kc-aps1" "euw1:/tmp/kc-euw1" "use1:/tmp/kc-use1"; do
  region="${pair%%:*}"; kc="${pair##*:}"
  log "==> Installing observability on $region..."
  export KUBECONFIG="$kc"
  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

  AWS_REGION="$region" \
  GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-Admin@123}" \
  ONCALL_EMAIL="$ALERT_EMAIL" \
  PROMETHEUS_REMOTE_WRITE_URL="${PROMETHEUS_REMOTE_WRITE_URL:-http://localhost}" \
    envsubst < observability/prometheus-values.yaml > /tmp/prom-values.yaml
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring --values /tmp/prom-values.yaml --wait --timeout 10m

  helm upgrade --install loki grafana/loki-stack \
    -n monitoring --values observability/loki-values.yaml --wait --timeout 10m

  AWS_REGION="$region" envsubst < observability/tempo-values.yaml > /tmp/tempo-values.yaml
  helm upgrade --install tempo grafana/tempo \
    -n monitoring --values /tmp/tempo-values.yaml --wait --timeout 10m
done

log "==> Deploy complete!"
