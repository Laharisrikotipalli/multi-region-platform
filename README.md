# Multi-Region Platform on AWS

High-availability Kubernetes platform deployed across three AWS regions using Amazon EKS, RDS PostgreSQL, ElastiCache Redis, and Amazon Route 53.

## Architecture

| Layer | Technology | Details |
|---|---|---|
| Compute | Amazon EKS 1.30 | One cluster per region: `ap-southeast-1`, `eu-west-1`, `us-east-1` |
| Networking | AWS VPC | Each cluster has its own VPC with public/private subnets and NAT gateway |
| Load Balancing | Kubernetes `Service: LoadBalancer` | Creates an AWS ELB per region automatically |
| Traffic Management | Amazon Route 53 | Latency-based routing; health checks remove unhealthy regions |
| Database | Amazon RDS PostgreSQL 15 | Primary in `ap-southeast-1`; read replicas in `eu-west-1` and `us-east-1` |
| Cache | Amazon ElastiCache Redis | Primary in `ap-southeast-1` joined to a Global Datastore; secondaries in other regions |
| GitOps | ArgoCD | Installed on every cluster; syncs from this repo |
| Observability | Prometheus + Grafana + Loki + Tempo | Deployed via Helm on every cluster; single-pane-of-glass via Grafana |
| DR Automation | AWS Lambda + CloudWatch Alarm | Promotes RDS replica automatically when primary fails |

## Regions

```
ap-southeast-1  (primary)   VPC 10.0.0.0/16   mr-eks-aps1
eu-west-1       (replica)   VPC 10.1.0.0/16   mr-eks-euw1
us-east-1       (replica)   VPC 10.2.0.0/16   mr-eks-use1
```

## Required Environment Variables

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export GRAFANA_PASSWORD=...          # Grafana admin password — never commit this
export DATABASE_URL=...              # postgresql://user:pass@host/db
export REDIS_URL=...                 # redis://host:6379
export ALERT_EMAIL=ops@example.com
```

## Deployment

```bash
bash scripts/deploy.sh
```

The deploy script will:
1. Run `terraform apply` across all three regions
2. Install ArgoCD, Prometheus, Loki, Tempo, and the webapp on each cluster
3. Create the `app-secrets` Kubernetes Secret on each cluster
4. Wait for all rollouts to complete

## Health Check

The `/health` endpoint verifies:
- Web service is running
- Database connectivity (`SELECT 1`)
- Redis connectivity (`PING`)

Returns `{"status": "ok"}` with HTTP 200 when all pass, or HTTP 503 when any dependency fails. Route 53 uses this to automatically remove unhealthy regions from DNS rotation.

## Failover Test

```bash
export ROUTE53_FQDN=app.example.com
bash scripts/test-failover.sh
```

Suspends ArgoCD auto-sync, scales `ap-southeast-1` to zero replicas, and verifies traffic
reroutes to another region within 120 seconds. Restores aps1 and re-enables auto-sync on completion.

## Observability

Grafana dashboards provide a single view of:
- CPU / memory / pod metrics (Prometheus)
- Container logs (Loki)
- Distributed traces (Tempo / OpenTelemetry)

Access Grafana:
```bash
kubectl port-forward svc/prometheus-grafana 3000:80 -n monitoring
```
Open `http://localhost:3000` — credentials are set via the `$GRAFANA_PASSWORD` environment variable at deploy time.