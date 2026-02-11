# VPC-CNI to Cilium Migration Testing

This directory contains resources for testing the migration process from AWS VPC-CNI to Cilium CNI on Amazon EKS.

## ⚠️ Completely Separate from Production

This migration test cluster is **completely isolated** from the production `cilium-egress` cluster:

- **Different cluster name**: `vpc-cni-migration-test` (vs `cilium-egress`)
- **Different region**: `us-east-1` (vs `us-west-2`)
- **Different VPC CIDR**: `10.1.0.0/16` (vs `10.0.0.0/16`)
- **Different resource names**: All prefixed with `vpc-cni-migration-test-*`
- **Separate Terraform state**: No shared state files

**See [SEPARATION.md](SEPARATION.md) for complete details on resource isolation.**

## Purpose

- **Test migration procedures** before applying to production
- **Validate documentation** in [../docs/MIGRATION.md](../docs/MIGRATION.md)
- **Identify issues** and edge cases
- **Build confidence** in the migration process
- **No risk** to production cluster

## What This Creates

A small test EKS cluster with:
- **2× t3.small worker nodes** (cost-optimized)
- **VPC-CNI** (AWS default CNI) initially
- **Test applications** to verify migration
- **No egress gateway** initially (added after migration)

**Estimated Cost:** ~$0.25/hour (~$6/day if left running)

## Prerequisites

- AWS Account with appropriate permissions
- AWS CLI configured
- Terraform >= 1.0
- kubectl
- Helm 3
- 2-4 hours for full migration testing

## Directory Structure

```
vpc-cni-migration/
├── terraform/              # Test cluster infrastructure
│   ├── terraform.tfvars    # Small cluster configuration
│   └── *.tf                # Infrastructure code
├── kubernetes/             # Test applications
│   └── test-app.yaml       # Sample workloads
├── scripts/                # Migration scripts
│   ├── deploy-vpc-cni-cluster.sh  # Deploy test cluster
│   └── migrate-to-cilium.sh       # Perform migration
└── README.md               # This file
```

## Quick Start

### Step 1: Deploy VPC-CNI Test Cluster

```bash
# From vpc-cni-migration/ directory
./scripts/deploy-vpc-cni-cluster.sh
```

This will:
1. Deploy EKS cluster with VPC-CNI
2. Deploy test applications
3. Verify pods have VPC IPs (10.0.x.x)

**Expected output:**
```
Pod IPs: 10.0.23.100, 10.0.23.101, 10.0.23.102
CNI: aws-node (VPC-CNI)
```

### Step 2: Migrate to Cilium

```bash
# Follow the automated migration script
./scripts/migrate-to-cilium.sh
```

Or **manually follow** the migration guide at [../docs/MIGRATION.md](../docs/MIGRATION.md) for hands-on learning.

**Expected outcome:**
```
Pod IPs: 10.244.0.10, 10.244.0.11, 10.244.0.12
CNI: Cilium (overlay networking)
```

### Step 3: Verify Migration

```bash
# Check Cilium status
kubectl -n kube-system exec ds/cilium -- cilium-dbg status

# Verify pod IPs changed to overlay range
kubectl get pods -o wide

# Test connectivity
CURL_POD=$(kubectl get pod -l app=curl-test -o jsonpath='{.items[0].metadata.name}')
kubectl exec $CURL_POD -- curl -s http://test-app-svc
kubectl exec $CURL_POD -- curl -s https://ifconfig.me
```

### Step 4: Cleanup

```bash
# Destroy test cluster when done
cd terraform
terraform destroy
```

## Migration Testing Scenarios

### Scenario 1: Automated Migration (Recommended for First Test)

Follow the automated script to understand the full process:

```bash
./scripts/migrate-to-cilium.sh
```

### Scenario 2: Manual Migration (For Deep Learning)

Follow the migration guide step-by-step:

```bash
# 1. Install Cilium
helm install cilium cilium/cilium --namespace kube-system \
  --set egressGateway.enabled=true \
  --set bpf.masquerade=true \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set ipam.mode=cluster-pool \
  --set eni.enabled=false

# 2. Cordon and drain each node
kubectl cordon <node-name>
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 3. Verify pods rescheduled with new IPs
kubectl get pods -o wide

# 4. Remove VPC-CNI
kubectl delete daemonset -n kube-system aws-node
```

See [../docs/MIGRATION.md](../docs/MIGRATION.md) for full details.

### Scenario 3: Test Rollback Procedure

Simulate issues and practice rollback:

```bash
# During migration, simulate issue
kubectl cordon <cilium-node>

# Rollback to VPC-CNI
kubectl apply -f https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/master/config/master/aws-k8s-cni.yaml
kubectl delete pod -n kube-system -l k8s-app=cilium
```

## What to Test

### Pre-Migration Checklist
- [ ] Record current pod IPs
- [ ] Test internal service connectivity
- [ ] Test external connectivity
- [ ] Check DNS resolution
- [ ] Verify application functionality

### During Migration
- [ ] Monitor pod rescheduling
- [ ] Verify IP changes (10.0.x.x → 10.244.x.x)
- [ ] Check for failed pods
- [ ] Monitor Cilium agent logs
- [ ] Test connectivity during migration

### Post-Migration Validation
- [ ] All pods running with overlay IPs
- [ ] Cilium agent healthy on all nodes
- [ ] Internal service connectivity works
- [ ] External connectivity works
- [ ] DNS resolution works
- [ ] No increase in error rates
- [ ] Application functionality intact

### Edge Cases to Test
- [ ] Pod restart during migration
- [ ] Node failure during migration
- [ ] StatefulSet migration
- [ ] Persistent volume connectivity
- [ ] Network policy translation
- [ ] Service endpoint updates

## Common Issues and Solutions

### Issue 1: Pods Stuck in Pending

**Symptom:** Pods not scheduling after drain
**Solution:**
```bash
# Check node status
kubectl get nodes

# Uncordon nodes if needed
kubectl uncordon <node-name>
```

### Issue 2: Old IP Ranges Persist

**Symptom:** Pods still have 10.0.x.x IPs
**Solution:**
```bash
# Delete and recreate pods
kubectl delete pod -l app=test-app
```

### Issue 3: Connectivity Issues

**Symptom:** Pods can't reach services
**Solution:**
```bash
# Check Cilium status
kubectl -n kube-system exec ds/cilium -- cilium-dbg status

# Restart Cilium pods
kubectl rollout restart ds/cilium -n kube-system
```

### Issue 4: VPC-CNI Not Removed

**Symptom:** Both CNIs running
**Solution:**
```bash
# Force delete VPC-CNI
kubectl delete daemonset -n kube-system aws-node --force --grace-period=0
```

## Validation Commands

```bash
# Check which CNI is active
kubectl get ds -n kube-system

# Show pod IP distribution
kubectl get pods -A -o wide | awk '{print $7}' | grep -E '^[0-9]+\.' | sort -u

# Test Cilium connectivity
kubectl -n kube-system exec ds/cilium -- cilium-dbg connectivity test

# Check for issues
kubectl get events -A --sort-by='.lastTimestamp' | grep -i error
```

## Cost Management

**Running Costs:**
```
2× t3.small: $0.042/hour = ~$30/month
EKS Control: $0.10/hour  = ~$73/month
NAT Gateway: $0.045/hour = ~$33/month
Total: ~$0.19/hour or ~$136/month if left running
```

**Recommendations:**
- ✅ Run tests during working hours
- ✅ Destroy cluster after testing
- ✅ Set AWS Budget alerts
- ✅ Use `terraform destroy` when done

**Automated cleanup:**
```bash
# Add to your crontab for auto-cleanup after 6 hours
(cd /home/coder/cilium-egress/vpc-cni-migration/terraform && terraform destroy -auto-approve)
```

## Testing Timeline

**Full migration test:** 2-4 hours

- **Preparation:** 30 min (deploy cluster, verify)
- **Migration:** 1-2 hours (manual testing, validation)
- **Documentation:** 30 min (record issues, update docs)
- **Cleanup:** 15 min (destroy resources)

## Next Steps After Testing

Once you've validated the migration process:

1. **Document findings** - Note any issues encountered
2. **Update migration guide** - Improve documentation based on testing
3. **Plan production migration** - Choose migration strategy
4. **Schedule maintenance window** - For production migration
5. **Prepare rollback plan** - Based on testing experience

## Additional Resources

- **[Migration Guide](../docs/MIGRATION.md)** - Full migration procedures
- **[Architecture Guide](../docs/ARCHITECTURE.md)** - How Cilium works
- **[Configuration Reference](../docs/CONFIGURATION.md)** - Configuration options
- **[Cilium Docs](https://docs.cilium.io)** - Official documentation

## Troubleshooting

If you encounter issues:

1. Check the logs:
   ```bash
   kubectl logs -n kube-system ds/cilium
   ```

2. Review migration guide:
   ```bash
   cat ../docs/MIGRATION.md
   ```

3. Ask for help:
   - [Cilium Slack](https://slack.cilium.io)
   - [GitHub Issues](https://github.com/cilium/cilium/issues)

## Warning

⚠️ **This is a TEST cluster** - Do not use for production workloads!

- No backup/disaster recovery
- Single NAT Gateway (no HA)
- Small instance types
- Limited monitoring

For production deployment, see [../cilium-egress/README.md](../cilium-egress/README.md).
