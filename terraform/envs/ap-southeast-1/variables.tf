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