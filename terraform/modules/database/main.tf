variable "region" {}
variable "name_prefix" {}
variable "vpc_id" {}

variable "subnet_ids" {
  type = list(string)
}

variable "is_primary" {
  type    = bool
  default = false
}

variable "primary_db_arn" {
  default = ""
}

variable "global_replication_group_id" {
  default = ""
}

variable "tags" {
  type = map(string)
}

provider "aws" {
  region = var.region
}

resource "aws_db_subnet_group" "rds" {
  name       = "${var.name_prefix}-rds-subnet"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "rds" {
  name   = "${var.name_prefix}-rds-sg"
  vpc_id = var.vpc_id
  tags   = var.tags

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "primary" {
  count                   = var.is_primary ? 1 : 0
  identifier              = "${var.name_prefix}-postgres-primary"
  engine                  = "postgres"
  engine_version          = "15"
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  username                = "postgres"
  password                = "Password123!"
  db_name                 = "appdb"
  db_subnet_group_name    = aws_db_subnet_group.rds.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  backup_retention_period = 7
  skip_final_snapshot     = true
  publicly_accessible     = false
  tags                    = var.tags
}

resource "aws_db_instance" "replica" {
  count                  = var.is_primary ? 0 : 1
  identifier             = "${var.name_prefix}-postgres-replica"
  replicate_source_db    = var.primary_db_arn
  instance_class         = "db.t3.micro"
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
  publicly_accessible    = false
  tags                   = var.tags
}

resource "aws_elasticache_subnet_group" "redis" {
  name       = "${var.name_prefix}-redis-subnet"
  subnet_ids = var.subnet_ids
  tags       = var.tags
}

resource "aws_security_group" "redis" {
  name   = "${var.name_prefix}-redis-sg"
  vpc_id = var.vpc_id
  tags   = var.tags

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id        = "${var.name_prefix}-redis"
  description                 = "Redis for ${var.name_prefix}"
  engine                      = "redis"
  node_type                   = "cache.t3.micro"
  num_cache_clusters          = 1
  automatic_failover_enabled  = false
  subnet_group_name           = aws_elasticache_subnet_group.redis.name
  security_group_ids          = [aws_security_group.redis.id]
  global_replication_group_id = var.is_primary ? null : var.global_replication_group_id
  tags                        = var.tags
}

resource "aws_elasticache_global_replication_group" "global" {
  count = var.is_primary ? 1 : 0

  global_replication_group_id_suffix = "mr-redis"
  primary_replication_group_id       = aws_elasticache_replication_group.redis.id
}

output "primary_db_arn" {
  value = var.is_primary ? aws_db_instance.primary[0].arn : ""
}

output "redis_endpoint" {
  value = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "global_replication_group_id" {
  value = var.is_primary ? aws_elasticache_global_replication_group.global[0].global_replication_group_id : ""
}
