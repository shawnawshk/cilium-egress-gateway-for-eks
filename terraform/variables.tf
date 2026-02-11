variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "cil-mig"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.1.0.0/16"  # Different from production (10.0.0.0/16)
}

variable "kubernetes_version" {
  description = "Kubernetes version for EKS"
  type        = string
  default     = "1.35"
}

variable "worker_instance_type" {
  description = "EC2 instance type for worker nodes"
  type        = string
  default     = "m5.large"
}

variable "gateway_instance_type" {
  description = "EC2 instance type for gateway nodes"
  type        = string
  default     = "m5.large"
}

variable "worker_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "worker_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "worker_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 3
}

variable "gateway_desired_size" {
  description = "Desired number of gateway nodes"
  type        = number
  default     = 0
}

variable "gateway_min_size" {
  description = "Minimum number of gateway nodes"
  type        = number
  default     = 0
}

variable "gateway_max_size" {
  description = "Maximum number of gateway nodes"
  type        = number
  default     = 0
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default = {
    Project     = "cilium-migration"
    Environment = "testing"
    Purpose     = "migration-validation"
    ManagedBy   = "terraform"
  }
}
