variable "zone_name" {
  type    = string
  default = "multi-region-platform.internal"
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

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_route53_zone" "main" {
  name = var.zone_name
  tags = var.tags
}

resource "aws_route53_health_check" "aps1" {
  count             = var.aps1_elb_dns != "" ? 1 : 0
  fqdn              = var.aps1_elb_dns
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  tags              = var.tags
}

resource "aws_route53_record" "aps1" {
  count          = var.aps1_elb_dns != "" ? 1 : 0
  zone_id        = aws_route53_zone.main.zone_id
  name           = "app.${var.zone_name}"
  type           = "A"
  set_identifier = "ap-southeast-1"
  latency_routing_policy {
    region = "ap-southeast-1"
  }
  alias {
    name                   = var.aps1_elb_dns
    zone_id                = var.aps1_elb_zone_id
    evaluate_target_health = true
  }
  health_check_id = aws_route53_health_check.aps1[0].id
}

resource "aws_route53_health_check" "euw1" {
  count             = var.euw1_elb_dns != "" ? 1 : 0
  fqdn              = var.euw1_elb_dns
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  tags              = var.tags
}

resource "aws_route53_record" "euw1" {
  count          = var.euw1_elb_dns != "" ? 1 : 0
  zone_id        = aws_route53_zone.main.zone_id
  name           = "app.${var.zone_name}"
  type           = "A"
  set_identifier = "eu-west-1"
  latency_routing_policy {
    region = "eu-west-1"
  }
  alias {
    name                   = var.euw1_elb_dns
    zone_id                = var.euw1_elb_zone_id
    evaluate_target_health = true
  }
  health_check_id = aws_route53_health_check.euw1[0].id
}

resource "aws_route53_health_check" "use1" {
  count             = var.use1_elb_dns != "" ? 1 : 0
  fqdn              = var.use1_elb_dns
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
  tags              = var.tags
}

resource "aws_route53_record" "use1" {
  count          = var.use1_elb_dns != "" ? 1 : 0
  zone_id        = aws_route53_zone.main.zone_id
  name           = "app.${var.zone_name}"
  type           = "A"
  set_identifier = "us-east-1"
  latency_routing_policy {
    region = "us-east-1"
  }
  alias {
    name                   = var.use1_elb_dns
    zone_id                = var.use1_elb_zone_id
    evaluate_target_health = true
  }
  health_check_id = aws_route53_health_check.use1[0].id
}

output "hosted_zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "app_fqdn" {
  value = "app.${var.zone_name}"
}
