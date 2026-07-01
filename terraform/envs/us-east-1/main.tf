# ── us-east-1 — REPLICA REGION ───────────────────────────────────────────────
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.30" }
  }
  backend "s3" {
    bucket = "mr-tfstate-use1-487542879245"
    key    = "us-east-1/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" { region = "us-east-1" }

data "terraform_remote_state" "primary" {
  backend = "s3"
  config = {
    bucket = "mr-tfstate-aps1-487542879245"
    key    = "ap-southeast-1/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  common_tags = {
    project     = "multi-region-platform"
    environment = "prod"
    region      = "us-east-1"
    managed_by  = "terraform"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"
  name            = "mr-vpc-use1"
  cidr            = "10.2.0.0/16"
  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.2.1.0/24", "10.2.2.0/24"]
  private_subnets = ["10.2.3.0/24", "10.2.4.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true
  tags = local.common_tags
  public_subnet_tags  = { "kubernetes.io/role/elb"          = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"
  cluster_name                             = "mr-eks-use1"
  cluster_version                          = "1.30"
  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true
  subnet_ids = module.vpc.private_subnets
  vpc_id     = module.vpc.vpc_id
  eks_managed_node_groups = {
    default = {
      desired_size   = 2; min_size = 1; max_size = 3
      instance_types = ["t3.small"]
      ami_type       = "AL2_x86_64"
      tags           = local.common_tags
    }
  }
  tags = local.common_tags
}

resource "aws_kms_key" "rds" {
  description             = "RDS replica encryption key us-east-1"
  deletion_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_db_subnet_group" "rds" {
  name       = "mr-rds-subnet-use1"
  subnet_ids = module.vpc.private_subnets
  tags       = local.common_tags
}

resource "aws_security_group" "rds" {
  name   = "mr-rds-sg-use1"
  vpc_id = module.vpc.vpc_id
  tags   = local.common_tags
  ingress { from_port = 5432; to_port = 5432; protocol = "tcp"; cidr_blocks = ["10.2.0.0/16"] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_db_instance" "postgres_replica" {
  identifier             = "mr-postgres-replica-use1"
  replicate_source_db    = data.terraform_remote_state.primary.outputs.primary_db_arn
  instance_class         = "db.t3.micro"
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  storage_encrypted      = true
  kms_key_id             = aws_kms_key.rds.arn
  skip_final_snapshot    = true
  publicly_accessible    = false
  tags                   = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "replication_lag" {
  alarm_name          = "mr-rds-replica-lag-use1"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 30
  alarm_description   = "RDS replication lag > 30s — RPO at risk"
  treat_missing_data  = "breaching"
  tags                = local.common_tags
  dimensions          = { DBInstanceIdentifier = "mr-postgres-replica-use1" }
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "mr-redis-subnet-use1"
  subnet_ids = module.vpc.private_subnets
  tags       = local.common_tags
}

resource "aws_security_group" "redis" {
  name   = "mr-redis-sg-use1"
  vpc_id = module.vpc.vpc_id
  tags   = local.common_tags
  ingress { from_port = 6379; to_port = 6379; protocol = "tcp"; cidr_blocks = ["10.2.0.0/16"] }
  egress  { from_port = 0;    to_port = 0;    protocol = "-1";  cidr_blocks = ["0.0.0.0/0"] }
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id        = "mr-redis-use1"
  description                 = "Redis replica us-east-1"
  engine                      = "redis"
  node_type                   = "cache.t3.micro"
  num_cache_clusters          = 1
  automatic_failover_enabled  = false
  global_replication_group_id = data.terraform_remote_state.primary.outputs.global_replication_group_id
  subnet_group_name           = aws_elasticache_subnet_group.redis.name
  security_group_ids          = [aws_security_group.redis.id]
  tags                        = local.common_tags
}

resource "aws_route53_health_check" "app" {
  fqdn              = var.use1_elb_dns
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  tags              = merge(local.common_tags, { Name = "mr-hc-use1" })
}

resource "aws_route53_record" "app" {
  count          = var.use1_elb_dns != "" && var.hosted_zone_id != "" ? 1 : 0
  zone_id        = var.hosted_zone_id
  name           = var.app_domain
  type           = "A"
  set_identifier = "us-east-1"
  latency_routing_policy { region = "us-east-1" }
  alias {
    name                   = var.use1_elb_dns
    zone_id                = var.use1_elb_zone_id
    evaluate_target_health = true
  }
  health_check_id = aws_route53_health_check.app.id
}

variable "use1_elb_dns"     { type = string; default = "" }
variable "use1_elb_zone_id" { type = string; default = "" }
variable "hosted_zone_id"   { type = string; default = "" }
variable "app_domain"       { type = string; default = "app.multi-region-platform.internal" }

output "eks_cluster_name"      { value = module.eks.cluster_name }
output "rds_replica_endpoint"  { value = aws_db_instance.postgres_replica.endpoint; sensitive = true }
output "redis_endpoint"        { value = aws_elasticache_replication_group.redis.primary_endpoint_address }
output "replication_lag_alarm" { value = aws_cloudwatch_metric_alarm.replication_lag.alarm_name }
