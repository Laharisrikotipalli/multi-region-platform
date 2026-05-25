variable "zone_name" {
  type = string
}

variable "aps1_elb_dns" {
  type = string
}

variable "euw1_elb_dns" {
  type = string
}

variable "use1_elb_dns" {
  type = string
}

variable "aps1_elb_zone_id" {
  type = string
}

variable "euw1_elb_zone_id" {
  type = string
}

variable "use1_elb_zone_id" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

provider "aws" {
  alias  = "global"
  region = "us-east-1"
}

resource "aws_route53_zone" "main" {
  provider = aws.global
  name     = var.zone_name
  tags     = var.tags
}

resource "aws_route53_health_check" "aps1" {
  provider          = aws.global
  fqdn              = var.aps1_elb_dns
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  request_interval  = 30
  failure_threshold = 3
  tags              = merge(var.tags, { Name = "hc-aps1" })
}

resource "aws_route53_health_check" "euw1" {
  provider          = aws.global
  fqdn              = var.euw1_elb_dns
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  request_interval  = 30
  failure_threshold = 3
  tags              = merge(var.tags, { Name = "hc-euw1" })
}

resource "aws_route53_health_check" "use1" {
  provider          = aws.global
  fqdn              = var.use1_elb_dns
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  request_interval  = 30
  failure_threshold = 3
  tags              = merge(var.tags, { Name = "hc-use1" })
}

resource "aws_route53_record" "aps1" {
  provider       = aws.global
  zone_id        = aws_route53_zone.main.zone_id
  name           = "app.${var.zone_name}"
  type           = "A"
  set_identifier = "aps1"

  health_check_id = aws_route53_health_check.aps1.id

  latency_routing_policy {
    region = "ap-southeast-1"
  }

  alias {
    name                   = var.aps1_elb_dns
    zone_id                = var.aps1_elb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "euw1" {
  provider       = aws.global
  zone_id        = aws_route53_zone.main.zone_id
  name           = "app.${var.zone_name}"
  type           = "A"
  set_identifier = "euw1"

  health_check_id = aws_route53_health_check.euw1.id

  latency_routing_policy {
    region = "eu-west-1"
  }

  alias {
    name                   = var.euw1_elb_dns
    zone_id                = var.euw1_elb_zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "use1" {
  provider       = aws.global
  zone_id        = aws_route53_zone.main.zone_id
  name           = "app.${var.zone_name}"
  type           = "A"
  set_identifier = "use1"

  health_check_id = aws_route53_health_check.use1.id

  latency_routing_policy {
    region = "us-east-1"
  }

  alias {
    name                   = var.use1_elb_dns
    zone_id                = var.use1_elb_zone_id
    evaluate_target_health = true
  }
}

output "hosted_zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "nameservers" {
  value = aws_route53_zone.main.name_servers
}

output "app_fqdn" {
  value = "app.${var.zone_name}"
}