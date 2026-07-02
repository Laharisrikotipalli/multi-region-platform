#!/usr/bin/env bash
# deploy.sh – full multi-region platform deployment
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?Set AWS_ACCESS_KEY_ID}"
: "${AWS_SECRET_ACCESS_KEY:?Set AWS_SECRET_ACCESS_KEY}"
: "${TF_VAR_alert_email:?Set TF_VAR_alert_email}"
: "${GRAFANA_PASSWORD:?Set GRAFANA_PASSWORD}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }

# ── 1. Bootstrap S3 state buckets ─────────────────────────────────────────────
# NOTE: these bucket names must exactly match the `backend "s3" { bucket = ... }` block in
# each terraform/envs/*/main.tf file. Terraform backend blocks can't use variables/interpolation,
# so if you ever fork this into a different AWS account, update BOTH this list and all three
# backend blocks to use your own account ID (S3 bucket names are globally unique across all
# AWS accounts — a name without an account-specific suffix will very likely collide with someone
# else's bucket and fail with AccessDenied/AllAccessDisabled).
for pair in "ap-southeast-1:mr-tfstate-aps1-515422922112" "eu-west-1:mr-tfstate-euw1-515422922112" "us-east-1:mr-tfstate-use1-515422922112"; do
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
terraform apply -auto-approve
cd ../../..

# ── 3. Deploy replica regions sequentially ────────────────────────────────────
# (Not run in parallel with `&`/`wait`: Git Bash's fork() emulation on Windows is
# unreliable under concurrent subprocess load and can fail with
# "dofork: child ... died unexpectedly" / "fork: retry: Resource temporarily
# unavailable". Sequential is slower but reliable across all shells/OSes.)
log "==> Deploying eu-west-1 (replica)..."
cd terraform/envs/eu-west-1
terraform init -upgrade
terraform apply -auto-approve
cd ../../..

log "==> Deploying us-east-1 (replica)..."
cd terraform/envs/us-east-1
terraform init -upgrade
terraform apply -auto-approve
cd ../../..

# ── 4. Fetch kubeconfigs ───────────────────────────────────────────────────────
log "==> Fetching kubeconfigs..."
aws eks update-kubeconfig --region ap-southeast-1 --name mr-eks-aps1 --kubeconfig /tmp/kc-aps1
aws eks update-kubeconfig --region eu-west-1      --name mr-eks-euw1 --kubeconfig /tmp/kc-euw1
aws eks update-kubeconfig --region us-east-1      --name mr-eks-use1 --kubeconfig /tmp/kc-use1

# ── 5. Install ArgoCD and deploy application on each cluster ──────────────────
for pair in "aps1:/tmp/kc-aps1:ap-southeast-1" "euw1:/tmp/kc-euw1:eu-west-1" "use1:/tmp/kc-use1:us-east-1"; do
  short="${pair%%:*}"; rest="${pair#*:}"; kc="${rest%%:*}"; region="${rest#*:}"
  log "==> Bootstrapping ArgoCD on $region..."
  export KUBECONFIG="$kc"
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  # --server-side avoids kubectl apply's client-side last-applied-configuration
  # annotation, which exceeds Kubernetes' 256KB limit for the large
  # applicationsets.argoproj.io CRD schema — a known Argo CD/kubectl issue.
  kubectl apply --server-side --force-conflicts -n argocd \
    -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
  kubectl apply -f k8s/namespace.yaml

  # ── app-secrets + cluster-config must exist BEFORE ArgoCD syncs the app, ────
  # ── otherwise the pods crash-loop on missing DATABASE_URL/REDIS_URL. ────────
  log "==> Fetching DB/Redis endpoints for $region from Terraform state..."
  DB_ENDPOINT=$(cd "terraform/envs/$region" && terraform output -raw db_endpoint)
  REDIS_ENDPOINT=$(cd "terraform/envs/$region" && terraform output -raw redis_endpoint)
  DATABASE_URL="postgresql://postgres:${TF_VAR_db_password}@${DB_ENDPOINT}:5432/appdb"
  REDIS_URL="redis://${REDIS_ENDPOINT}:6379"

  kubectl create secret generic app-secrets -n multi-region \
    --from-literal=database-url="$DATABASE_URL" \
    --from-literal=redis-url="$REDIS_URL" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create configmap cluster-config -n multi-region \
    --from-literal=aws-region="$region" \
    --dry-run=client -o yaml | kubectl apply -f -

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
  GRAFANA_PASSWORD="${GRAFANA_PASSWORD}" \
  ONCALL_EMAIL="${TF_VAR_alert_email}" \
  PROMETHEUS_REMOTE_WRITE_URL="${PROMETHEUS_REMOTE_WRITE_URL:-http://localhost:9090/api/v1/write}" \
    envsubst '${AWS_REGION} ${GRAFANA_PASSWORD} ${ONCALL_EMAIL} ${PROMETHEUS_REMOTE_WRITE_URL}' \
      < observability/prometheus-values.yaml > /tmp/prom-values.yaml
  helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring --values /tmp/prom-values.yaml --wait --timeout 10m

  helm upgrade --install loki grafana/loki-stack \
    -n monitoring --values observability/loki-values.yaml --wait --timeout 10m

  AWS_REGION="$region" envsubst < observability/tempo-values.yaml > /tmp/tempo-values.yaml
  helm upgrade --install tempo grafana/tempo \
    -n monitoring --values /tmp/tempo-values.yaml --wait --timeout 10m
done

log "==> Deploy complete!"