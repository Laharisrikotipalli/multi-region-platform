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
kubectl get pods -n argocd
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

**Step 1** — Scale down aps1 to simulate failure:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl scale deployment -n argocd --all --replicas=0
```

**Step 2** — Verify other regions still serving traffic:
```bash
export KUBECONFIG=/tmp/kc-euw1
kubectl get pods -n argocd
export KUBECONFIG=/tmp/kc-use1
kubectl get pods -n argocd
```

**Step 3** — Restore aps1:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl scale deployment -n argocd --all --replicas=1
kubectl get pods -n argocd -w
```

---

## Failback Procedure

**Step 1** — Verify aps1 is fully healthy:
```bash
export KUBECONFIG=/tmp/kc-aps1
kubectl get nodes
kubectl get pods --all-namespaces
```

**Step 2** — Re-sync ArgoCD applications:
```bash
kubectl get applications -n argocd
```

**Step 3** — Re-sync RDS replication:
```bash
aws rds describe-db-instances \
  --db-instance-identifier mr-rds-aps1 \
  --region ap-southeast-1 \
  --query 'DBInstances[0].DBInstanceStatus'
```

**Step 4** — Update Route 53 health checks back to aps1.

---

## Monitoring URLs

| Region | Grafana URL |
|--------|-------------|
| Singapore | http://a75d94efc91794d6690d676b2f64004c-720853056.ap-southeast-1.elb.amazonaws.com |
| Ireland | http://aa3c52757566a4b8891761d68327f0eb-282513953.eu-west-1.elb.amazonaws.com |
| Virginia | http://ad415091003f8448baded07298a77c2f-2057774029.us-east-1.elb.amazonaws.com |

Grafana login: `admin` / `Admin@123`
