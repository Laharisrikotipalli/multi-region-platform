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