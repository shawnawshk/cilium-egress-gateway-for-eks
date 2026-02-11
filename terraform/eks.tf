module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Only install essential addons - Cilium will replace VPC-CNI
  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        tolerations = [
          {
            key      = "node.cilium.io/agent-not-ready"
            operator = "Exists"
            effect   = "NoSchedule"
          }
        ]
      })
    }
    kube-proxy = {
      most_recent = true
    }
    # VPC-CNI needed for initial node bootstrap
    # Will be deleted after Cilium is installed
    vpc-cni = {
      most_recent    = true
      before_compute = true
    }
  }

  # Enable IRSA
  enable_irsa = true

  # Cluster security group additional rules
  cluster_security_group_additional_rules = {
    ingress_nodes_ephemeral_ports_tcp = {
      description                = "Nodes on ephemeral ports"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  # Node security group additional rules for Cilium
  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Cilium health checks
    ingress_cilium_health = {
      description = "Cilium health checks"
      protocol    = "tcp"
      from_port   = 4240
      to_port     = 4240
      type        = "ingress"
      self        = true
    }
    # Cilium VXLAN overlay
    ingress_cilium_vxlan = {
      description = "Cilium VXLAN"
      protocol    = "udp"
      from_port   = 8472
      to_port     = 8472
      type        = "ingress"
      self        = true
    }
    # Hubble relay
    ingress_hubble_relay = {
      description = "Hubble relay"
      protocol    = "tcp"
      from_port   = 4245
      to_port     = 4245
      type        = "ingress"
      self        = true
    }
  }

  tags = {
    Name = var.cluster_name
  }
}
