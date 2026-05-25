# Disaster Recovery Runbook

## RTO / RPO Targets
| Metric | Target |
|---|---|
| RTO (Recovery Time Objective) | < 5 minutes |
| RPO (Recovery Point Objective) | < 30 seconds |
| Failback RTO | ~15 minutes (replica re-sync dominates) |

---

## Scenario 1: Regional Application Failure (ap-southeast-1)

### Detection
Route 53 health checks detect `/health` returning non-200 after 3 × 30s = 90 seconds.
CloudWatch Alarm fires when RDS `DatabaseConnections < 1` for 3 consecutive 1-minute periods.

```bash
# Confirm failure
export KUBECONFIG=/tmp/kc-aps1
kubectl get nodes
kubectl get pods --all-namespaces
```

### Failover Steps

**Step 1** — Trigger Lambda failover manually if CloudWatch has not auto-triggered:
```bash
aws lambda invoke \
  --function-name multi-region-failover \
  --region ap-southeast-1 \
  --payload '{"action":"failover","target_region":"eu-west-1"}' \
  --cli-binary-format raw-in-base64-out /tmp/failover.json
cat /tmp/failover.json
```

**Step 2** — Verify eu-west-1 is healthy:
```bash
export KUBECONFIG=/tmp/kc-euw1
kubectl get pods -n multi-region
kubectl get pods -n monitoring
```

**Step 3** — Confirm Route 53 has removed aps1 from rotation:
```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id <HOSTED_ZONE_ID> \
  --query "ResourceRecordSets[?Name=='app.multi-region-platform.internal.']"
```

**Step 4** — If RDS promotion did not complete automatically:
```bash
aws rds promote-read-replica \
  --db-instance-identifier mr-postgres-replica-euw1 \
  --region eu-west-1
# Wait for status: available
aws rds wait db-instance-available \
  --db-instance-identifier mr-postgres-replica-euw1 \
  --region eu-west-1
```

**Step 5** — Update application DATABASE_URL secret to point at the promoted euw1 endpoint:
```bash
NEW_DB_HOST=$(aws rds describe-db-instances \
  --db-instance-identifier mr-postgres-replica-euw1 \
  --region eu-west-1 \
  --query 'DBInstances[0].Endpoint.Address' --output text)

for KC in /tmp/kc-aps1 /tmp/kc-euw1 /tmp/kc-use1; do
  KUBECONFIG=$KC kubectl create secret generic app-secrets \
    -n multi-region \
    --from-literal=database-url="postgresql://postgres:${DB_PASSWORD}@${NEW_DB_HOST}/appdb" \
    --from-literal=redis-url="${REDIS_URL}" \
    --dry-run=client -o yaml | KUBECONFIG=$KC kubectl apply -f -
  KUBECONFIG=$KC kubectl rollout restart deployment/multi-region-app -n multi-region
done
```

---

## Scenario 2: Full Regional Failover Test (Simulation)

> **Important:** ArgoCD `selfHeal` is suspended before the test to prevent it from
> immediately restoring the scaled-down deployment and masking the failover.

**Step 1** — Confirm all regions healthy before starting:
```bash
for KC in /tmp/kc-aps1 /tmp/kc-euw1 /tmp/kc-use1; do
  export KUBECONFIG=$KC
  kubectl get pods -n multi-region
done
```

**Step 2** — Suspend ArgoCD auto-sync on aps1:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl patch application multi-region-app -n argocd \
  --type=merge -p '{"spec":{"syncPolicy":null}}'
```

**Step 3** — Scale down aps1 webapp to simulate failure:
```bash
kubectl scale deployment webapp           -n multi-region --replicas=0
kubectl scale deployment multi-region-app -n multi-region --replicas=0
```

**Step 4** — Trigger Lambda failover:
```bash
aws lambda invoke \
  --function-name multi-region-failover \
  --region ap-southeast-1 \
  --payload '{"action":"failover","target_region":"eu-west-1"}' \
  --cli-binary-format raw-in-base64-out /tmp/failover-response.json
cat /tmp/failover-response.json
```

**Step 5** — Wait 90 s for Route 53 health checks to propagate, then verify:
```bash
sleep 90
for KC in /tmp/kc-euw1 /tmp/kc-use1; do
  export KUBECONFIG=$KC
  ELB=$(kubectl get svc webapp -n multi-region \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  curl -s -o /dev/null -w "HTTP %{http_code} — ${ELB}/health\n" \
    --max-time 10 "http://${ELB}/health"
done
```

**Step 6** — Restore aps1 and re-enable ArgoCD:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl scale deployment webapp           -n multi-region --replicas=3
kubectl scale deployment multi-region-app -n multi-region --replicas=3
kubectl rollout status deployment/webapp            -n multi-region --timeout=3m
kubectl rollout status deployment/multi-region-app  -n multi-region --timeout=3m

kubectl patch application multi-region-app -n argocd \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

---

## Failback Procedure

### Prerequisites
- Primary region (ap-southeast-1) is healthy again
- `mr-postgres-replica-euw1` is running as standalone primary (promoted)

### Steps

**Step 1** — Verify aps1 cluster is fully healthy:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl get nodes
kubectl get pods --all-namespaces
```

**Step 2** — Re-sync ArgoCD on aps1:
```bash
kubectl patch application multi-region-app -n argocd \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
argocd app sync multi-region-app --server https://kubernetes.default.svc --insecure 2>/dev/null || true
```

**Step 3** — Create new RDS read replica in aps1 pointing to the euw1 primary:
```bash
EUW1_DB_ARN=$(aws rds describe-db-instances \
  --db-instance-identifier mr-postgres-replica-euw1 \
  --region eu-west-1 \
  --query 'DBInstances[0].DBInstanceArn' --output text)

aws rds create-db-instance-read-replica \
  --db-instance-identifier mr-postgres-primary \
  --source-db-instance-identifier "$EUW1_DB_ARN" \
  --region ap-southeast-1

# Monitor until available
aws rds wait db-instance-available \
  --db-instance-identifier mr-postgres-primary \
  --region ap-southeast-1
```

**Step 4** — Re-add aps1 Route 53 record. Update `TF_VAR_aps1_elb_dns` and re-run Terraform:
```bash
cd terraform/envs/ap-southeast-1
terraform apply -auto-approve -input=false
cd ../../..
```

**Step 5** — Once aps1 is confirmed serving traffic, optionally promote it back to primary and
demote euw1 back to replica (reverse of Step 3 above). Update Lambda env var `FAILED_REGION_ELB`
back to the euw1 ELB.

**Step 6** — Update Lambda env var to reflect restored topology:
```bash
aws lambda update-function-configuration \
  --function-name multi-region-failover \
  --region ap-southeast-1 \
  --environment "Variables={PRIMARY_REGION=ap-southeast-1,REPLICA_REGION=eu-west-1,...}"
```

---

## Monitoring URLs

| Region | Grafana URL |
|---|---|
| Singapore (aps1) | `http://<APS1_ELB>` — `kubectl get svc prometheus-grafana -n monitoring` |
| Ireland (euw1) | `http://<EUW1_ELB>` — `kubectl get svc prometheus-grafana -n monitoring` |
| Virginia (use1) | `http://<USE1_ELB>` — `kubectl get svc prometheus-grafana -n monitoring` |

Grafana login: `admin` / value of `$GRAFANA_PASSWORD` env var

Each Grafana instance has cross-region Prometheus datasources registered, providing a
single-pane-of-glass view of metrics from all three regions.
