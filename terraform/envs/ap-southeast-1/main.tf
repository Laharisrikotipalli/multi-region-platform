terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.30"
    }
  }

  backend "s3" {
    bucket = "mr-tfstate-aps1-515422922112"
    key    = "ap-southeast-1/terraform.tfstate"
    region = "ap-southeast-1"
  }
}

provider "aws" {
  region = "ap-southeast-1"
}

locals {
  common_tags = {
    project     = "multi-region-platform"
    environment = "prod"
    region      = "ap-southeast-1"
    managed_by  = "terraform"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  name = "mr-vpc-aps1"
  cidr = "10.0.0.0/16"

  azs = [
    "ap-southeast-1a",
    "ap-southeast-1b"
  ]

  public_subnets = [
    "10.0.1.0/24",
    "10.0.2.0/24"
  ]

  private_subnets = [
    "10.0.3.0/24",
    "10.0.4.0/24"
  ]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.common_tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.4"

  cluster_name                             = "mr-eks-aps1"
  cluster_version                          = "1.30"
  enable_cluster_creator_admin_permissions = true
  cluster_endpoint_public_access           = true

  subnet_ids = module.vpc.private_subnets
  vpc_id     = module.vpc.vpc_id

  eks_managed_node_groups = {
    default = {
      desired_size = 2
      min_size     = 1
      max_size     = 3

      instance_types = [
        "t3.small"
      ]

      ami_type = "AL2_x86_64"

      tags = local.common_tags
    }
  }

  tags = local.common_tags
}

resource "aws_db_subnet_group" "rds" {
  name       = "mr-rds-subnet-aps1"
  subnet_ids = module.vpc.private_subnets

  tags = local.common_tags
}

resource "aws_security_group" "rds" {
  name   = "mr-rds-sg-aps1"
  vpc_id = module.vpc.vpc_id

  tags = local.common_tags

  ingress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/16"
    ]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }
}

resource "aws_db_instance" "postgres" {
  identifier = "mr-postgres-primary"

  engine         = "postgres"
  engine_version = "15"

  instance_class = "db.t3.micro"

  allocated_storage = 20

  username = "postgres"
  password = var.db_password

  db_name = "appdb"

  db_subnet_group_name = aws_db_subnet_group.rds.name

  vpc_security_group_ids = [
    aws_security_group.rds.id
  ]

  backup_retention_period = 1

  skip_final_snapshot = true

  publicly_accessible = false
  storage_encrypted   = true

  tags = local.common_tags
}

resource "aws_elasticache_subnet_group" "redis" {
  name = "mr-redis-subnet-aps1"

  subnet_ids = module.vpc.private_subnets

  tags = local.common_tags
}

resource "aws_security_group" "redis" {
  name   = "mr-redis-sg-aps1"
  vpc_id = module.vpc.vpc_id

  tags = local.common_tags

  ingress {
    from_port = 6379
    to_port   = 6379
    protocol  = "tcp"

    cidr_blocks = [
      "10.0.0.0/16"
    ]
  }

  egress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"

    cidr_blocks = [
      "0.0.0.0/0"
    ]
  }
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "mr-redis-aps1"

  description = "Redis primary ap-southeast-1"

  engine = "redis"

  node_type = "cache.t3.micro"

  num_cache_clusters = 1

  automatic_failover_enabled = false

  subnet_group_name = aws_elasticache_subnet_group.redis.name

  security_group_ids = [
    aws_security_group.redis.id
  ]

  tags = local.common_tags
}

module "lambda_failover" {
  source = "../../modules/lambda"

  primary_region = "ap-southeast-1"

  replica_region = "eu-west-1"

  replica_db_identifier = "mr-postgres-replica-euw1"

  alert_email = var.alert_email

  tags = local.common_tags
}

variable "alert_email" {
  type    = string
  default = ""
}

variable "db_password" {
  description = "Master password for RDS PostgreSQL primary"

  type = string

  sensitive = true
}

variable "zone_name" {
  description = "Route53 hosted zone"

  type = string

  default = "multi-region-platform.internal"
}

module "route53" {
  source = "../../modules/route53"

  zone_name = var.zone_name

  aps1_elb_dns = var.aps1_elb_dns

  aps1_elb_zone_id = var.aps1_elb_zone_id

  euw1_elb_dns = var.euw1_elb_dns

  euw1_elb_zone_id = var.euw1_elb_zone_id

  use1_elb_dns = var.use1_elb_dns

  use1_elb_zone_id = var.use1_elb_zone_id

  tags = local.common_tags
}

variable "aps1_elb_dns" {
  type    = string
  default = ""
}

variable "aps1_elb_zone_id" {
  type    = string
  default = ""
}

variable "euw1_elb_dns" {
  type    = string
  default = ""
}

variable "euw1_elb_zone_id" {
  type    = string
  default = ""
}

variable "use1_elb_dns" {
  type    = string
  default = ""
}

variable "use1_elb_zone_id" {
  type    = string
  default = ""
}





output "primary_db_arn" {
  value = aws_db_instance.postgres.arn
}

output "global_replication_group_id" {
  value = aws_elasticache_replication_group.redis.id
}

output "hosted_zone_id" {
  value = module.route53.hosted_zone_id
}

output "app_fqdn" {
  value = module.route53.app_fqdn
}
