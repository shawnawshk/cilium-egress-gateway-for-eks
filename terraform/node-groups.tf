# Worker node group - regular workload nodes
module "eks_managed_node_group_workers" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 20.0"

  name            = "${var.cluster_name}-workers"
  cluster_name    = module.eks.cluster_name
  cluster_version = var.kubernetes_version

  subnet_ids = module.vpc.private_subnets

  cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
  vpc_security_group_ids            = [module.eks.node_security_group_id]
  cluster_service_cidr              = "172.20.0.0/16"

  min_size     = 1
  max_size     = 5
  desired_size = var.worker_desired_size

  instance_types = [var.worker_instance_type]
  capacity_type  = "ON_DEMAND"

  # AL2023 is the default for EKS 1.30+, explicit for older versions
  ami_type = "AL2023_x86_64_STANDARD"

  labels = {
    role = "worker"
  }

  tags = {
    Name = "${var.cluster_name}-worker"
  }
}

# Gateway node group - dedicated egress gateway nodes
# Deployed in PUBLIC subnet for direct internet access via EIP
module "eks_managed_node_group_gateway" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 20.0"

  name            = "${var.cluster_name}-gateway"
  cluster_name    = module.eks.cluster_name
  cluster_version = var.kubernetes_version

  # Gateway nodes in PUBLIC subnet for direct IGW access
  # EIP attached to node provides static egress IP
  subnet_ids = [module.vpc.public_subnets[0]]

  cluster_primary_security_group_id = module.eks.cluster_primary_security_group_id
  vpc_security_group_ids = [
    module.eks.node_security_group_id,
    aws_security_group.egress_gateway_eni.id
  ]
  cluster_service_cidr              = "172.20.0.0/16"

  min_size     = 1
  max_size     = 3
  desired_size = var.gateway_desired_size

  instance_types = [var.gateway_instance_type]
  capacity_type  = "ON_DEMAND"

  ami_type = "AL2023_x86_64_STANDARD"

  labels = {
    role             = "egress-gateway"
    "egress-gateway" = "true"
  }

  taints = [
    {
      key    = "egress-gateway"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  ]

  tags = {
    Name                = "${var.cluster_name}-gateway"
    "egress-gateway"    = "true"
  }
}
