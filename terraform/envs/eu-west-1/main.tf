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

  name = "mr-vpc-euw1"
  cidr = "10.1.0.0/16"

  azs = [
    "eu-west-1a",
    "eu-west-1b"
  ]

  public_subnets = [
    "10.1.1.0/24",
    "10.1.2.0/24"
  ]

  private_subnets = [
    "10.1.3.0/24",
    "10.1.4.0/24"
  ]

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = local.common_tags
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