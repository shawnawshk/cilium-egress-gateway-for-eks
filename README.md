# Cilium Egress Gateway for Amazon EKS

Production-ready setup for Cilium egress gateway on Amazon EKS, enabling per-application egress IP control.

[![Terraform](https://img.shields.io/badge/Terraform-1.5+-844FBA?logo=terraform)](https://www.terraform.io/)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-1.35+-326CE5?logo=kubernetes)](https://kubernetes.io/)
[![Cilium](https://img.shields.io/badge/Cilium-1.19+-F8C517?logo=cilium)](https://cilium.io/)
[![AWS](https://img.shields.io/badge/AWS-EKS-FF9900?logo=amazon-aws)](https://aws.amazon.com/eks/)

## What is This?

Cilium egress gateway provides **predictable, static egress IPs** for Kubernetes pods. Each application can have its own dedicated Elastic IP for external traffic.

### Use Cases

- **API Whitelisting**: External services require specific source IPs
- **Compliance**: Audit trails need consistent egress IPs
- **Multi-tenant**: Different applications need IP isolation
- **Cost Savings**: Single cluster vs multiple clusters for IP separation

### Problem & Solution

**Without Egress Gateway:**
```
Frontend pods  ──┐
Backend pods   ──┼─→ NAT Gateway → Internet
Admin pods     ──┘         ↓
                   All traffic from same IP: 52.202.231.151
                   ❌ Cannot whitelist per-application
                   ❌ Cannot identify which app made request
```

**With Cilium Egress Gateway:**
```
Frontend pods  → Gateway Node 1 (Elastic IP: 100.48.235.218) → Internet
Backend pods   → Gateway Node 2 (Elastic IP: 100.48.235.219) → Internet
Admin pods     → Gateway Node 3 (Elastic IP: 100.48.235.220) → Internet

✅ Each application has dedicated egress IP
✅ External services can whitelist specific IPs
✅ Complete audit trail per application
```

## Egress Approaches Comparison

| Approach | Egress IP Control | Cost | Complexity | Use When |
|----------|-------------------|------|------------|----------|
| **NAT Gateway** | ❌ Shared IP | $$ | Low | No IP control needed |
| **Nodes in Public Subnet** | ⚠️ N node IPs | $ | Low | Cost-sensitive, low security |
| **Cilium Egress Gateway** | ✅ Static per-app | $$ | Medium | IP whitelisting required |

### Cost Example (Test Cluster)

| Solution | Infrastructure | Monthly Cost |
|----------|----------------|--------------|
| NAT Gateway | 2 workers + NAT | ~$63 |
| Nodes in Public | 2 workers (no NAT) | ~$30 |
| **Cilium Egress Gateway** | 2 workers + 1 gateway | **~$82** |

**Trade-off**: +$19/month for per-application IP control and security benefits.

## Quick Start

```bash
# 1. Deploy infrastructure
cd terraform/
cp terraform.tfvars.example terraform.tfvars
terraform apply

# 2. Deploy test applications
kubectl apply -f kubernetes/test-app.yaml

# 3. For VPC-CNI clusters: Migrate to Cilium
./scripts/migrate-to-cilium.sh

# 4. Configure egress gateway
kubectl apply -f kubernetes/egress-gateway-policy.yaml

# 5. Verify
kubectl exec <pod> -- curl ifconfig.me
```

See [QUICKSTART.md](docs/QUICKSTART.md) for detailed instructions.

## Documentation

| Document | Description | Pages |
|----------|-------------|-------|
| [QUICKSTART.md](docs/QUICKSTART.md) | Get started in 30 minutes | 9 |
| [EGRESS-GATEWAY.md](docs/EGRESS-GATEWAY.md) | Complete egress gateway guide | ~68 |
| [MIGRATION-GUIDE.md](docs/MIGRATION-GUIDE.md) | VPC-CNI to Cilium migration | ~86 |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System design overview | ~20 |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common issues & solutions | 15 |

## Repository Structure

```
vpc-cni-migration/
├── docs/               # Documentation (5 files)
├── terraform/          # Infrastructure as Code
├── kubernetes/         # Kubernetes manifests
├── scripts/            # Automation scripts
└── examples/           # Configuration examples
```

## Features

- ✅ Per-application egress IPs using Elastic IPs
- ✅ Production-tested on EKS cluster (cil-mig)
- ✅ Complete VPC-CNI to Cilium migration procedures
- ✅ Zero data loss, minimal downtime migration
- ✅ Terraform infrastructure as code
- ✅ Example configurations for multiple scenarios

## Prerequisites

- AWS Account with EKS permissions
- Terraform >= 1.5
- kubectl >= 1.35
- Helm >= 3.12
- AWS CLI v2

## Architecture

Cilium egress gateway uses:
- **Overlay networking** (VXLAN) for pod communication
- **eBPF** for high-performance packet processing
- **Gateway nodes** with Elastic IPs for egress traffic
- **Policy-based routing** to control which pods use which IPs

See [ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

## Migration from VPC-CNI

If you have an existing EKS cluster with VPC-CNI, this repository includes complete migration procedures:

1. Deploy Cilium alongside VPC-CNI
2. Migrate nodes one-by-one
3. Remove VPC-CNI
4. Configure egress gateway

Validated on test cluster with zero data loss. See [MIGRATION-GUIDE.md](docs/MIGRATION-GUIDE.md).

## Cost

**Test cluster** (2 workers + 1 gateway): ~$82/month
**Production** (5 workers + 6 gateways): ~$1,120/month

Compare to 3 separate clusters: ~$1,800/month
**Savings**: ~38%

## License

MIT License - See [LICENSE](LICENSE)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md)

## Support

- **Issues**: [GitHub Issues](https://github.com/your-org/vpc-cni-migration/issues)
- **Slack**: [Cilium Slack](https://slack.cilium.io/)

---

**Status**: ✅ Production Ready | **Last Updated**: February 2026 | **Version**: 1.0
