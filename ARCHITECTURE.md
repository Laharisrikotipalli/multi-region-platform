# Architecture

## Overview

The platform runs in three AWS regions — **ap-southeast-1 (primary)**,
**eu-west-1**, and **us-east-1** — each with its own EKS cluster, RDS
PostgreSQL instance, and ElastiCache Redis node. Global traffic routing,
data replication, and failover tie the three regions together into a
single logical platform.

## Module layout

`terraform/modules/network` and `terraform/modules/database` are shared
modules called once per region from `terraform/envs/{region}/main.tf`, with
`is_primary`/`name_prefix` as the only real differences between regions.
`terraform/modules/route53` and `terraform/modules/lambda` are singletons —
they're only instantiated from the `ap-southeast-1` env, since Route 53
hosted zones and the failover Lambda are global/primary-region concerns,
not per-region ones.

Each env's `main.tf` also calls the public `terraform-aws-modules/eks/aws`
module directly (not wrapped locally), since EKS cluster shape genuinely
differs per region (node counts, instance types) in a way that doesn't
benefit from a shared abstraction the way network/database provisioning
does.

## Traffic flow

1. A client resolves `app.multi-region-platform.internal`. Route 53
   latency-based routing (in `terraform/modules/route53`) returns the alias
   A record for whichever healthy region is closest to the client.
2. Route 53 health checks poll each region's `/health` endpoint every 30s
   (3-failure threshold). A failing region is automatically removed from
   the routing pool — this is the primary failover path.
3. Traffic lands on the regional EKS ingress, then application pods.

## Data layer

**PostgreSQL** — single writable primary in ap-southeast-1, with
asynchronous cross-region replicas in eu-west-1 and us-east-1
(`replicate_source_db`), each encrypted with its own regional KMS key
(cross-region replicas can't share the primary's key). A CloudWatch alarm
on `ReplicaLag` fires above 30s to protect the RPO target.

**Redis** — `terraform/modules/database` creates an
`aws_elasticache_global_replication_group` in the primary region, wrapping
the primary's replication group. Secondary regions join that global group
via `global_replication_group_id` instead of running independent caches.
This means a regional failover doesn't produce a cold cache — the
secondary region already has a warm, eventually-consistent copy of the
data. The trade-off is replication lag (typically sub-second) between the
primary write and secondary read; acceptable since Redis here backs a
cache, not the system of record.

## Failover mechanics

Two failover paths run in parallel, deliberately overlapping:

1. **DNS-level (automatic, ~30–90s):** Route 53 health check failure
   removes the failed region from the latency-routing pool.
2. **Database-level (Lambda-triggered):** a CloudWatch alarm on the
   primary RDS's connection count firing to zero publishes to an SNS
   topic, which invokes `lambda/lambda_function.py`. The Lambda confirms
   the primary is actually unreachable, promotes the target replica,
   removes the failed region's Route 53 record (looked up dynamically by
   `SetIdentifier`, matching the alias A record shape Terraform creates),
   and publishes an SNS alert.

See `RUNBOOK.md` for the full step-by-step procedure and RTO/RPO targets
(<5 min RTO, <30s RPO, ~15 min failback dominated by replica re-sync).

## GitOps

Each region runs its own ArgoCD instance watching the same GitHub repo,
rather than one central ArgoCD controlling all three clusters. A regional
outage can't take down the deployment pipeline for the other two regions.

## Observability

Prometheus in each region remote-writes to a central aggregator for a
federated cross-region metrics view. **Logs (Loki) and traces (Tempo) are
not yet centralized** — both run with local/filesystem storage per region.
This is the platform's most significant remaining observability gap.

## Known gaps / deliberate trade-offs

- **Logs and traces are regional, not centralized.**
- **Redis is eventually consistent globally**, by design — acceptable for
  cache data, not for a system of record.
- **VPC peering is not yet configured** between the three regional VPCs;
  RDS/Redis cross-region replication doesn't require it, but future
  pod-to-pod cross-region traffic would.
