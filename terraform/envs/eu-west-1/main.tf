terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
  }
  backend "s3" {
    bucket = "mr-tfstate-euw1-515422922112"
    key    = "eu-west-1/terraform.tfstate"
    region = "eu-west-1"
  }
}

provider "aws" { region = "eu-west-1" }

data "terraform_remote_state" "primary" {
  backend = "s3"
  config = {
    bucket = "mr-tfstate-aps1-515422922112"
    key    = "ap-southeast-1/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

locals {
  common_tags = {
    project     = "multi-region-platform"
    environment = "prod"
    region      = "eu-west-1"
    managed_by  = "terraform"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"
  name            = "mr-vpc-euw1"
  cidr            = "10.1.0.0/16"
  azs             = ["eu-west-1a", "eu-west-1b"]
  public_subnets  = ["10.1.1.0/24", "10.1.2.0/24"]
  private_subnets = ["10.1.3.0/24", "10.1.4.0/24"]
  enable_nat_gateway = true
  single_nat_gateway = true
  tags = local.common_tags
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"
  cluster_name                             = "mr-eks-euw1"
  cluster_version                          = "1.30"
  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true
  subnet_ids = module.vpc.private_subnets
  vpc_id     = module.vpc.vpc_id
  eks_managed_node_groups = {
    default = {
      desired_size   = 2
      min_size       = 1
      max_size       = 3
      instance_types = ["t3.small"]
      ami_type       = "AL2_x86_64"
      tags           = local.common_tags
    }
  }
  tags = local.common_tags
}

resource "aws_kms_key" "rds" {
  description             = "RDS replica encryption key eu-west-1"
  deletion_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_db_subnet_group" "rds" {
  name       = "mr-rds-subnet-euw1"
  subnet_ids = module.vpc.private_subnets
  tags       = local.common_tags
}

resource "aws_security_group" "rds" {
  name   = "mr-rds-sg-euw1"
  vpc_id = module.vpc.vpc_id
  tags   = local.common_tags
  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "postgres_replica" {
  identifier             = "mr-postgres-replica-euw1"
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
  alarm_name          = "mr-rds-replica-lag-euw1"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 30
  alarm_description   = "RDS replication lag > 30s"
  treat_missing_data  = "breaching"
  tags                = local.common_tags
  dimensions = {
    DBInstanceIdentifier = "mr-postgres-replica-euw1"
  }
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "mr-redis-subnet-euw1"
  subnet_ids = module.vpc.private_subnets
  tags       = local.common_tags
}

resource "aws_security_group" "redis" {
  name   = "mr-redis-sg-euw1"
  vpc_id = module.vpc.vpc_id
  tags   = local.common_tags
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["10.1.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id       = "mr-redis-euw1"
  description                = "Redis for eu-west-1"
  engine                     = "redis"
  node_type                  = "cache.t3.micro"
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  subnet_group_name          = aws_elasticache_subnet_group.redis.name
  security_group_ids         = [aws_security_group.redis.id]
  tags                       = local.common_tags
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "rds_replica_endpoint" {
  value     = aws_db_instance.postgres_replica.endpoint
  sensitive = true
}

output "redis_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}
