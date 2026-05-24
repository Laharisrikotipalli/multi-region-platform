# Architecture Documentation

## Overview
This platform is a production-grade, multi-region Kubernetes infrastructure deployed across three AWS regions: ap-southeast-1 (Singapore), eu-west-1 (Ireland), and us-east-1 (N. Virginia).

## Architecture Diagram

```
                    ┌─────────────────────────────┐
                    │      Route 53 (Global DNS)   │
                    │   Latency-based routing       │
                    └──────┬──────────┬─────────┬──┘
                           │          │         │
          ┌────────────────┘          │         └──────────────────┐
          │                           │                            │
┌─────────▼──────────┐   ┌────────────▼────────────┐   ┌──────────▼──────────┐
│  ap-southeast-1    │   │     eu-west-1           │   │     us-east-1       │
│  EKS + ArgoCD      │   │  EKS + ArgoCD           │   │  EKS + ArgoCD       │
│  Prometheus/Grafana│   │  Prometheus/Grafana     │   │  Prometheus/Grafana │
│  RDS Primary       │──▶│  RDS Replica            │   │  RDS Replica        │
│  ElastiCache Redis │   │  ElastiCache Redis      │   │  ElastiCache Redis  │
└────────────────────┘   └─────────────────────────┘   └─────────────────────┘
        │                                                          ▲
        └──────────────────── replication ────────────────────────┘
```

All three regions are direct Route 53 routing targets. Route 53 health checks poll
`/health` on each regional ELB (interval: 30s, failure threshold: 3) and automatically
remove an unhealthy region from DNS rotation without manual intervention.

## Components

### Compute — EKS Clusters
- **Instance type:** t3.small (2 vCPU, 2GB RAM, 11 pods/node)
- **Kubernetes version:** 1.30
- **Nodes per region:** 2 (auto-scalable to 4)
- **Regions:** ap-southeast-1, eu-west-1, us-east-1

### GitOps — ArgoCD
- Deployed on all 3 clusters
- Syncs application manifests from GitHub repository
- Ensures identical deployments across all regions
- `selfHeal: true` — ArgoCD auto-corrects drift; suspend sync before DR drills
  (see Runbook Scenario 2)

### Observability — Prometheus + Grafana + Loki + Tempo
- kube-prometheus-stack deployed on all 3 clusters
- Loki for log aggregation, Tempo for distributed traces (OTLP on port 4317)
- Grafana exposed via AWS LoadBalancer per region
- Metrics: node CPU/memory, pod health, replication lag

### Data Layer
- **RDS PostgreSQL:** Primary in ap-southeast-1, read replicas in eu-west-1 and us-east-1
- **ElastiCache Redis:** Independent cluster per region for low-latency caching
- **Replication strategy:** Asynchronous replication (lower latency, RPO ~seconds)

### Disaster Recovery — Lambda Failover
- Lambda function `multi-region-failover` in ap-southeast-1
- Triggers DNS-level failover via Route 53
- RTO target: < 5 minutes | RPO target: < 30 seconds

### Route 53 Health Check Configuration
| Parameter | Value |
|-----------|-------|
| Protocol | HTTP |
| Path | `/health` |
| Interval | 30 seconds |
| Failure threshold | 3 consecutive failures |
| Routing policy | Latency-based with health check gating |

## Design Decisions & Trade-offs

| Decision | Choice | Trade-off |
|----------|--------|-----------|
| DB replication | Async | Lower latency vs small RPO risk |
| Node size | t3.small | Cost vs capacity (11 pods/node) |
| ArgoCD per cluster | Yes | Resilience vs central management |
| Prometheus per region | Yes | Data locality vs federation complexity |
| Topology spread | ScheduleAnyway | Availability on 2-node clusters vs strict spread enforcement |

## Security
- VPC per region with private subnets for EKS nodes
- Security groups restrict inter-service traffic
- IAM roles follow least-privilege principle
- No credentials stored in code — all via environment variables