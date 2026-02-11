#!/bin/bash
set -e

# Deploy VPC-CNI test cluster for migration testing
# This script creates an EKS cluster with VPC-CNI (default AWS CNI)

echo "=========================================="
echo "Deploying VPC-CNI Test Cluster"
echo "=========================================="

# Check prerequisites
command -v terraform >/dev/null 2>&1 || { echo "terraform is required but not installed.  Aborting." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed.  Aborting." >&2; exit 1; }
command -v aws >/dev/null 2>&1 || { echo "aws CLI is required but not installed.  Aborting." >&2; exit 1; }

# Get variables
CLUSTER_NAME=$(grep cluster_name terraform/terraform.tfvars | awk -F'"' '{print $2}')
REGION=$(grep region terraform/terraform.tfvars | awk -F'"' '{print $2}')

echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo ""

# Step 1: Deploy infrastructure
echo "=========================================="
echo "Step 1: Deploying Infrastructure"
echo "=========================================="
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
cd ..

# Step 2: Configure kubectl
echo ""
echo "=========================================="
echo "Step 2: Configuring kubectl"
echo "=========================================="
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# Wait for nodes to be ready
echo ""
echo "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

# Step 3: Verify VPC-CNI is running
echo ""
echo "=========================================="
echo "Step 3: Verifying VPC-CNI"
echo "=========================================="
echo "VPC-CNI DaemonSet:"
kubectl get daemonset -n kube-system aws-node

echo ""
echo "VPC-CNI Pods:"
kubectl get pods -n kube-system -l k8s-app=aws-node

# Step 4: Deploy test applications
echo ""
echo "=========================================="
echo "Step 4: Deploying Test Applications"
echo "=========================================="
kubectl apply -f kubernetes/test-app.yaml

echo ""
echo "Waiting for test applications to be ready..."
kubectl wait --for=condition=Available deployment/test-app --timeout=180s
kubectl wait --for=condition=Available deployment/curl-test --timeout=180s

# Step 5: Verify pod IPs are from VPC
echo ""
echo "=========================================="
echo "Step 5: Verifying Pod IPs (Should be VPC IPs)"
echo "=========================================="
kubectl get pods -o wide

echo ""
echo "Pod IP ranges (should be 10.0.x.x VPC range):"
kubectl get pods -o wide | awk '{print $6}' | grep -E '^[0-9]+\.' | sort -u

# Step 6: Test connectivity
echo ""
echo "=========================================="
echo "Step 6: Testing Connectivity"
echo "=========================================="
CURL_POD=$(kubectl get pod -l app=curl-test -o jsonpath='{.items[0].metadata.name}')
echo "Testing internal service connectivity..."
kubectl exec "$CURL_POD" -- curl -s -o /dev/null -w "%{http_code}" http://test-app-svc

echo ""
echo "Testing external connectivity..."
kubectl exec "$CURL_POD" -- curl -s https://ifconfig.me

# Summary
echo ""
echo "=========================================="
echo "VPC-CNI Test Cluster Deployed Successfully!"
echo "=========================================="
echo ""
echo "Cluster Name: $CLUSTER_NAME"
echo "Region: $REGION"
echo ""
echo "Next Steps:"
echo "1. Review the deployed infrastructure"
echo "2. Check pod IP addresses (should be VPC IPs: 10.0.x.x)"
echo "3. Follow migration guide: ../../docs/MIGRATION.md"
echo "4. Run: ./scripts/migrate-to-cilium.sh"
echo ""
echo "Current Pod IPs:"
kubectl get pods -o wide | grep -E '^NAME|test'
echo ""
