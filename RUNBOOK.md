# Disaster Recovery Runbook

## RTO / RPO Targets
- **RTO (Recovery Time Objective):** < 5 minutes
- **RPO (Recovery Point Objective):** < 30 seconds

---

## Scenario 1: Regional Application Failure (ap-southeast-1)

### Detection
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl get pods --all-namespaces
```

### Failover Steps
**Step 1** — Trigger Lambda failover:
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

**Step 3** — Promote RDS replica to primary (if DB affected):
```bash
aws rds promote-read-replica \
  --db-instance-identifier mr-rds-replica-euw1 \
  --region eu-west-1
```

**Step 4** — Update Route 53 to point to eu-west-1 ELB.

---

## Scenario 2: Full Regional Failover Test (Simulation)

> **Note:** Before running this test, ArgoCD auto-sync is suspended on aps1 to prevent
> selfHeal from immediately restoring the scaled-down deployment and masking a real failover.

**Step 1** — Suspend ArgoCD auto-sync on aps1 to allow the simulation to hold:
```bash
export KUBECONFIG=/tmp/kc-aps1
argocd app set multi-region-app --sync-policy none
```

**Step 2** — Scale down the webapp to simulate failure:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl scale deployment webapp -n multi-region --replicas=0
```

**Step 3** — Verify other regions still serving traffic:
```bash
export KUBECONFIG=/tmp/kc-euw1
kubectl get pods -n multi-region
export KUBECONFIG=/tmp/kc-use1
kubectl get pods -n multi-region
```

**Step 4** — Restore aps1 webapp and re-enable auto-sync:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl scale deployment webapp -n multi-region --replicas=3
kubectl rollout status deployment/webapp -n multi-region --timeout=3m
argocd app set multi-region-app --sync-policy automated
```

---

## Failback Procedure

### Prerequisites
- Primary region (ap-southeast-1) is healthy again
- Promoted replica (eu-west-1) is running as standalone primary

### Steps

**Step 1** — Verify aps1 is fully healthy:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl get nodes
kubectl get pods --all-namespaces
```

**Step 2** — Re-sync ArgoCD applications:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl get applications -n argocd
argocd app sync multi-region-app
```

**Step 3** — Create new RDS read replica in ap-southeast-1 pointing to the euw1 primary:
```bash
# Monitor replica lag until it reaches 0
aws rds describe-db-instances \
  --db-instance-identifier mr-rds-aps1 \
  --region ap-southeast-1 \
  --query 'DBInstances[0].DBInstanceStatus'
```

**Step 4** — Re-add aps1 Route 53 record to DNS rotation and verify ELB returns HTTP 200.

**Step 5** — Once aps1 is confirmed healthy, optionally promote it back to primary
and demote euw1 back to replica.

**Step 6** — Update Lambda env var `FAILED_REGION_ELB` back to the euw1 ELB.

### RTO for failback: ~15 minutes (replica sync time dominates)

---

## Monitoring URLs

| Region | Grafana URL |
|--------|-------------|
| Singapore | http://a75d94efc91794d6690d676b2f64004c-720853056.ap-southeast-1.elb.amazonaws.com |
| Ireland | http://aa3c52757566a4b8891761d68327f0eb-282513953.eu-west-1.elb.amazonaws.com |
| Virginia | http://ad415091003f8448baded07298a77c2f-2057774029.us-east-1.elb.amazonaws.com |

Grafana login: `admin` / `<value of $GRAFANA_PASSWORD env var>`