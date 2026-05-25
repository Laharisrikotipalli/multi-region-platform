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
- `kube-prometheus-stack` deployed on every cluster via Helm
- Loki for log aggregation, Tempo for distributed traces (OTLP on port 4317)
- Grafana configured with **cross-region datasources** pointing at all 3 Prometheus instances
  for a single-pane-of-glass view of metrics, logs, and traces
- All three Prometheus endpoints are registered as named datasources in Grafana

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
| Prometheus | Per-cluster | Data locality / no cross-region query latency vs federation complexity |
| Topology spread | `ScheduleAnyway` | Availability on 2-node clusters vs strict spread enforcement (which would cause Pending) |
| VPC design | Isolated per region | Simplicity / no cross-region blast radius vs no direct inter-region private connectivity |
| Redis failover | Independent clusters | Fast local cache availability vs possible cache cold-start after failover |
| Route 53 | Latency-based + health checks | True geo-routing + automatic failover vs higher TTL propagation time (~90 s) |

## Security

- VPC per region with EKS nodes in **private subnets** only
- **NetworkPolicy** default-deny in `multi-region` namespace; explicit allow rules for required ports
- Security groups restrict RDS (5432) and Redis (6379) to VPC CIDR only
- IAM roles follow least-privilege — Lambda has only `rds:Describe/Promote`, `sns:Publish`, `logs:*`
- **No credentials in code** — RDS password passed via `TF_VAR_db_password` env var (`sensitive = true`)
- Kubernetes Secrets (`app-secrets`) hold DATABASE_URL and REDIS_URL; never committed to repo
- Grafana admin password passed via `GRAFANA_PASSWORD` env var at deploy time
