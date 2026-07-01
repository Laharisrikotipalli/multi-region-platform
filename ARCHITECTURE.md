# Architecture Documentation

## Overview
This platform is a production-grade, multi-region Kubernetes infrastructure deployed across three AWS regions:
`ap-southeast-1` (Singapore — primary), `eu-west-1` (Ireland), and `us-east-1` (N. Virginia).

## Architecture Diagram

```
                    ┌──────────────────────────────────┐
                    │       Route 53 (Global DNS)       │
                    │  Latency-based + health-check     │
                    │  gated routing (30s/3 failures)   │
                    └──────┬──────────┬─────────────┬──┘
                           │          │             │
          ┌────────────────┘          │             └──────────────────┐
          │                           │                                │
┌─────────▼──────────┐   ┌────────────▼────────────┐   ┌──────────────▼──────┐
│  ap-southeast-1    │   │     eu-west-1           │   │     us-east-1       │
│  (PRIMARY)         │   │     (replica)           │   │     (replica)       │
│  EKS 1.30          │   │  EKS 1.30               │   │  EKS 1.30           │
│  ArgoCD            │   │  ArgoCD                 │   │  ArgoCD             │
│  Prometheus/Grafana│   │  Prometheus/Grafana     │   │  Prometheus/Grafana │
│  Loki / Tempo      │   │  Loki / Tempo           │   │  Loki / Tempo       │
│  RDS primary ──────┼──►│  RDS read replica       │   │  RDS read replica   │
│  ElastiCache Redis │   │  ElastiCache Redis      │   │  ElastiCache Redis  │
│  Lambda (DR)       │   │                         │   │                     │
└────────────────────┘   └─────────────────────────┘   └─────────────────────┘
        │                                                            ▲
        └──────────────────── async replication ─────────────────────┘
```

All three regions are Route 53 routing targets. Health checks poll `/health` on each regional
ELB every 30 s; after 3 consecutive failures the region is automatically removed from DNS
rotation — no manual intervention required.

## Components

### Compute — EKS Clusters
| Attribute | Value |
|---|---|
| Instance type | t3.small (2 vCPU, 2 GB RAM) |
| Kubernetes version | 1.30 |
| Nodes per region | 2 (auto-scalable to 3) |
| Regions | ap-southeast-1, eu-west-1, us-east-1 |

### GitOps — ArgoCD
- Deployed on all 3 clusters independently (no central ArgoCD — resilience over simplicity)
- `selfHeal: true` auto-corrects drift; **suspend sync before DR drills** (see Runbook)
- Syncs from `k8s/` directory in this repository

### Observability — Prometheus + Grafana + Loki + Tempo
- `kube-prometheus-stack` deployed on every cluster via Helm (`observability/prometheus-values.yaml`)
- Loki for log aggregation, Tempo for distributed traces (OTLP on port 4317)
- **Federated view today:** each region runs its own Prometheus; Grafana is pre-provisioned
  (`observability/grafana-datasources.yaml`) with all three Prometheus instances registered as
  named datasources, giving a single dashboard that can query metrics from any region —
  this is the federation mechanism actually deployed and demonstrated in the video walkthrough.
- **Scaffolded, not yet live:** `prometheus-values.yaml` also configures `remoteWrite` to a
  `PROMETHEUS_REMOTE_WRITE_URL` placeholder. No Thanos/Cortex/Mimir receiver is deployed in this
  repo yet, so long-term centralized storage of metrics is **not** functional out of the box —
  set that env var to a real remote-write endpoint (e.g. a Mimir or Cortex instance) to activate it.
  Tracked as a follow-up, not claimed as complete.
- Alerting rules for replication lag (`RDSReplicationLagHigh`, `RedisReplicationDown`) are wired
  to Alertmanager → email, on every regional Prometheus.

### Networking
- Independent VPC per region (10.0.0.0/16, 10.1.0.0/16, 10.2.0.0/16) — no VPC peering required
- EKS nodes in private subnets; workloads exposed via AWS LoadBalancer Service
- **NetworkPolicy** manifests enforce default-deny in `multi-region` namespace; explicit rules
  allow only: inbound on 8000 (app), DNS (53), PostgreSQL (5432), Redis (6379), Tempo (4317)

### Data Layer

#### PostgreSQL (RDS)
- Primary instance in `ap-southeast-1` with `backup_retention_period = 7`
- Read replicas in `eu-west-1` and `us-east-1` via `replicate_source_db`
- **Replication mode:** asynchronous (lower write latency, RPO ~seconds)
- On failover: Lambda promotes `mr-postgres-replica-euw1` to standalone primary

#### Redis (ElastiCache)
- Independent `cache.t3.micro` cluster per region
- Primary in `ap-southeast-1`; replicas join via `global_replication_group_id`
- After RDS failover: Redis clusters remain independently available (no cross-region failover needed for cache)

### Disaster Recovery — Lambda

The `multi-region-failover` Lambda function (Python 3.12, `ap-southeast-1`) is triggered by:
- **Automatic:** CloudWatch Alarm on RDS primary `DatabaseConnections < 1` for 3 minutes → SNS → Lambda
- **Manual:** `aws lambda invoke --payload '{"action":"failover",...}'`

**Failover steps the Lambda performs:**
1. Parses CloudWatch alarm state from the SNS event
2. Checks primary RDS status — if still `available/backing-up/modifying`, aborts (false-positive guard)
3. Calls `rds:PromoteReadReplica` on `mr-postgres-replica-euw1` in `eu-west-1`
4. Waits for replica to become `available` (waiter, up to 5 min)
5. Deletes the Route 53 latency record for `ap-southeast-1`, removing it from DNS rotation
6. Publishes SNS notification to ops team

**RTO target:** < 5 minutes | **RPO target:** < 30 seconds

### Route 53 Health Check Configuration
| Parameter | Value |
|---|---|
| Protocol | HTTP |
| Path | `/health` |
| Interval | 30 seconds |
| Failure threshold | 3 consecutive failures |
| Routing policy | Latency-based with health check gating |
| Record type | A (alias to ELB) |

The `/health` endpoint (app code) performs: web process check + `SELECT 1` against RDS + `PING` against Redis.
Returns `{"status":"ok"}` HTTP 200 when all pass, HTTP 503 when any dependency fails.

## Design Decisions & Trade-offs

| Decision | Choice | Trade-off |
|---|---|---|
| DB replication | Async (streaming) | Lower write latency vs small RPO risk (~seconds of data loss on hard crash) |
| Node size | t3.small | Cost-optimised (~$0.023/hr) vs limited pod density (11 pods/node) |
| ArgoCD | Per-cluster | Higher resilience (no single GitOps control plane to fail) vs central management |
| Prometheus | Per-cluster + Grafana federated view | Data locality / no cross-region query latency vs no single long-term global store (remote-write to Mimir/Cortex scaffolded but not deployed) |
| Topology spread | `ScheduleAnyway` | Availability on 2-node clusters vs strict spread enforcement (which would cause Pending) |
| VPC design | Isolated per region | Simplicity / no cross-region blast radius vs no direct inter-region private connectivity |
| Redis failover | Independent clusters | Fast local cache availability vs possible cache cold-start after failover |
| Route 53 | Latency-based + health checks | True geo-routing + automatic failover vs higher TTL propagation time (~90 s) |

## Requirements Coverage

Explicit mapping from the task's core requirements to where each is implemented, so this
document can be audited line-by-line against the code.

| Requirement | Status | Where |
|---|---|---|
| K8s clusters in 3+ regions via IaC | ✅ Done | `terraform/envs/{ap-southeast-1,eu-west-1,us-east-1}/main.tf` |
| Identical core components per cluster | ✅ Done | Same Helm charts / manifests applied in every env |
| Global load balancing, latency-based DNS, health-check failover | ✅ Done | `terraform/modules/route53/main.tf` |
| Robust endpoint health checks | ✅ Done | `app/main.py` `/health` — checks Postgres + Redis, returns 503 on failure |
| Stateless app deployed to all clusters | ✅ Done | `k8s/app/deployment.yaml` |
| GitOps controller (ArgoCD) synced from central repo | ✅ Done | `k8s/argocd/argocd-application.yaml` |
| PostgreSQL per region + cross-region replication | ✅ Done | `terraform/envs/*/main.tf` (`aws_db_instance.postgres` / `.postgres_replica`, via `replicate_source_db` + `terraform_remote_state`) |
| Replication lag monitored | ✅ Done | `RDSReplicationLagHigh` alert + `aws_cloudwatch_metric_alarm.replication_lag` |
| Redis per region + cross-region replication | ✅ Done | `aws_elasticache_global_replication_group` |
| Federated monitoring / unified dashboard | ⚠️ Partial | Per-cluster Prometheus + Grafana cross-region datasources deployed; central long-term store (Mimir/Cortex via remote-write) is scaffolded, not yet deployed |
| Centralized logging | ✅ Done | Loki per cluster (`observability/loki-values.yaml`), queried via Grafana |
| Distributed tracing across regions | ✅ Done | Tempo + OTLP instrumentation in `app/main.py`, `k8s/monitoring/jaeger.yaml` |
| Automated DR runbook/scripts | ✅ Done | `lambda/lambda_function.py`, `lambda/handler.py`, `RUNBOOK.md` |
| RTO/RPO defined and justified | ✅ Done | RTO < 5 min, RPO < 30 s (see Disaster Recovery section above) |
| Survive full regional shutdown | ✅ Done | Demonstrated via `scripts/test-failover.sh` |
| Network security policies | ✅ Done | Security groups (`terraform/envs/*/main.tf`) + `k8s/network-policies/` |
| Consistent resource tagging | ✅ Done | `local.common_tags` applied to every resource across all three env files |

## Known Limitations / Next Steps

Documented here deliberately, rather than glossed over, to keep this doc aligned with the code:

1. **Federated metrics store not deployed.** See Observability section above — `remoteWrite` is
   configured but points at a placeholder; no Mimir/Cortex/Thanos receiver exists in this repo yet.
2. **Redis has no automated cross-region failover.** Global Datastore replication is configured,
   but nothing promotes a secondary automatically if the primary region's Redis becomes
   unreachable — the app degrades to cache-miss/DB reads in that case, which is acceptable given
   Redis here is a cache (not a system of record), but is not "automated Redis failover."
3. **`terraform/modules/database/` and `terraform/modules/network/` were removed.** They were
   leftover scaffolding from an earlier design that none of the three `terraform/envs/*/main.tf`
   files ever actually called — each env provisions its RDS/ElastiCache/security-group resources
   inline, and VPCs come from the public `terraform-aws-modules/vpc/aws` registry module instead.
   Keeping unused modules around risked exactly the kind of doc/code mismatch this section exists
   to prevent, so they were deleted rather than left to rot.
4. **`k8s/app/deployment.yaml` previously deployed a placeholder nginx container** with a static
   `/health` response, while the real FastAPI app (with genuine Postgres/Redis health checks,
   OpenTelemetry tracing, and Prometheus metrics) sat unused in a root-level `clean-deploy.yaml`.
   This has been fixed: `k8s/app/deployment.yaml` now deploys the real app
   (`laharisri/multi-region-app:v3`) under the same `webapp` Deployment/Service names everything
   else (Route 53, the Lambda, `RUNBOOK.md`, `submission.yml`) already expects, and the orphaned
   `clean-deploy.yaml` was removed.
5. **`app-secrets` (DATABASE_URL/REDIS_URL) and `cluster-config` (AWS_REGION) are now created
   automatically** by both `scripts/deploy.sh` and `submission.yml`'s `deploy` step, immediately
   before ArgoCD syncs the app — pulled from real Terraform outputs (`db_endpoint`, `redis_endpoint`)
   plus `TF_VAR_db_password`, per region. Previously these were referenced in `RUNBOOK.md` but never
   actually created anywhere, which would have caused the app to crash-loop on first deploy.
6. **`submission.yml` previously never bootstrapped its own Terraform state buckets** and referenced
   a non-existent output (`rds_arn` instead of the real `primary_db_arn`), masked by a silent
   fallback. Both are fixed: the bucket bootstrap loop now matches `scripts/deploy.sh` exactly, and
   the dead output reference was removed (replica regions already pull the primary's DB ARN via
   `terraform_remote_state`, not a passed `-var`).

## Security

- VPC per region with EKS nodes in **private subnets** only
- **NetworkPolicy** default-deny in `multi-region` namespace; explicit allow rules for required ports
- Security groups restrict RDS (5432) and Redis (6379) to VPC CIDR only
- IAM roles follow least-privilege — Lambda has only `rds:Describe/Promote`, `sns:Publish`, `logs:*`
- **No credentials in code** — RDS password passed via `TF_VAR_db_password` env var (`sensitive = true`)
- Kubernetes Secrets (`app-secrets`) hold DATABASE_URL and REDIS_URL; never committed to repo
- Grafana admin password passed via `GRAFANA_PASSWORD` env var at deploy time