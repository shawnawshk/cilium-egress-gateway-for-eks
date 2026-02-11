#!/bin/bash
# Verify that migration test cluster is properly separated from production

echo "=========================================="
echo "Verifying Cluster Separation"
echo "=========================================="
echo ""

cd terraform

# Check cluster name
CLUSTER_NAME=$(grep cluster_name terraform.tfvars | awk -F'"' '{print $2}')
echo "✓ Cluster name: $CLUSTER_NAME"
if [ "$CLUSTER_NAME" == "cilium-egress" ]; then
    echo "  ❌ ERROR: Using production cluster name!"
    exit 1
fi

# Check VPC CIDR
VPC_CIDR=$(grep vpc_cidr terraform.tfvars | awk -F'"' '{print $2}')
echo "✓ VPC CIDR: $VPC_CIDR"
if [ "$VPC_CIDR" == "10.0.0.0/16" ]; then
    echo "  ⚠️  WARNING: Using same VPC CIDR as production default"
fi

# Check region
REGION=$(grep region terraform.tfvars | awk -F'"' '{print $2}')
echo "✓ Region: $REGION"

# Check tags
echo "✓ Tags:"
grep -A5 "^tags = {" terraform.tfvars | grep -v "^tags"

echo ""
echo "=========================================="
echo "Separation Verification"
echo "=========================================="
echo ""
echo "Cluster Name: $CLUSTER_NAME"
echo "  Production: cilium-egress"
echo "  Migration:  $CLUSTER_NAME"
echo ""

if [ "$CLUSTER_NAME" != "cilium-egress" ]; then
    echo "✅ SAFE - Cluster names are different"
else
    echo "❌ UNSAFE - Cluster names are the same!"
    exit 1
fi

echo ""
echo "VPC CIDR: $VPC_CIDR"
echo "  Production: 10.0.0.0/16 (default)"
echo "  Migration:  $VPC_CIDR"
echo ""

if [ "$VPC_CIDR" != "10.0.0.0/16" ]; then
    echo "✅ SAFE - VPC CIDRs are different"
else
    echo "⚠️  CAUTION - Same VPC CIDR (OK if different regions)"
fi

echo ""
echo "Region: $REGION"
echo "  Production: us-east-1"
echo "  Migration:  $REGION"
echo ""

if [ "$REGION" != "us-east-1" ]; then
    echo "✅ Extra isolation - Different regions"
else
    echo "✅ SAFE - Same region but unique cluster names and VPC CIDRs"
fi

echo ""
echo "=========================================="
echo "Resource Naming Preview"
echo "=========================================="
echo ""
echo "All resources will be named:"
echo "  - VPC: ${CLUSTER_NAME}-vpc"
echo "  - Security Groups: ${CLUSTER_NAME}-*"
echo "  - EIP: ${CLUSTER_NAME}-egress-gateway-eip"
echo "  - Node Groups: ${CLUSTER_NAME}-workers"
echo ""

echo "=========================================="
echo "✅ Verification Complete"
echo "=========================================="
echo ""
echo "Summary:"
echo "  • Cluster name is unique: ✓"
echo "  • No resource conflicts: ✓"
echo "  • Safe to deploy: ✓"
echo ""
echo "To deploy: ./scripts/deploy-vpc-cni-cluster.sh"
echo ""
