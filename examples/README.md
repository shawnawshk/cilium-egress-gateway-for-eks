# Configuration Examples

This directory contains example configurations for common deployment scenarios.

## Files

### Cilium Configuration

- **cilium-values.yaml** - Complete Cilium Helm values with:
  - Egress gateway enabled
  - VXLAN overlay networking
  - Kube-proxy replacement
  - Hubble observability
  - Production-ready settings

### Terraform Configuration

- **production-terraform.tfvars** - Production cluster configuration example
- **staging-terraform.tfvars** - Staging cluster configuration example

### Kubernetes Manifests

- **multi-app-egress.yaml** - Multi-application egress gateway setup
- **network-policies.yaml** - Example Cilium network policies

## Usage

### Install Cilium

```bash
helm install cilium cilium/cilium \
  --namespace kube-system \
  --values examples/cilium-values.yaml
```

### Deploy Infrastructure

```bash
cd terraform/
cp ../examples/production-terraform.tfvars terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform apply
```

### Apply Egress Policies

```bash
kubectl apply -f examples/multi-app-egress.yaml
```

### Apply Network Policies

```bash
kubectl apply -f examples/network-policies.yaml
```

## Scenarios

### Scenario 1: Single Application with HA

Use `cilium-values.yaml` with:
- 2+ gateway nodes in different AZs
- Single CiliumEgressGatewayPolicy

### Scenario 2: Multi-Application Isolation

Use `multi-app-egress.yaml` with:
- Dedicated gateway nodes per application
- Separate policies with different node selectors

### Scenario 3: Production with Network Policies

Combine:
- `cilium-values.yaml` for CNI
- `multi-app-egress.yaml` for egress control
- `network-policies.yaml` for micro-segmentation

## Customization

### Modify for Your Environment

1. **Cluster Name**: Change in terraform examples
2. **VPC CIDR**: Adjust to match your network
3. **Node Sizes**: Scale based on workload
4. **Elastic IPs**: Pre-allocate in AWS
5. **Pod Selectors**: Match your application labels
