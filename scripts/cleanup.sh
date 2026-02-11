#!/bin/bash
set -e

# Cleanup VPC-CNI migration test cluster

echo "=========================================="
echo "Cleanup VPC-CNI Migration Test Cluster"
echo "=========================================="
echo ""
echo "This will destroy the test cluster and all resources."
echo ""

CLUSTER_NAME=$(grep cluster_name terraform/terraform.tfvars | awk -F'"' '{print $2}')
REGION=$(grep region terraform/terraform.tfvars | awk -F'"' '{print $2}')

echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo ""

read -p "Are you sure you want to destroy this cluster? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Remove test files
echo ""
echo "Removing test output files..."
rm -f pre-migration-pods.txt post-migration-pods.txt

# Destroy infrastructure
echo ""
echo "Destroying infrastructure with Terraform..."
cd terraform
terraform destroy -auto-approve

echo ""
echo "=========================================="
echo "Cleanup Complete!"
echo "=========================================="
echo ""
echo "Test cluster has been destroyed."
echo "All AWS resources have been removed."
echo ""
