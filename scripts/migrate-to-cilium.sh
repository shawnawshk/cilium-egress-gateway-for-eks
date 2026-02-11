#!/bin/bash
set -e

# Migrate VPC-CNI test cluster to Cilium
# This script implements the Rolling In-Place Migration strategy

echo "=========================================="
echo "VPC-CNI to Cilium Migration Script"
echo "=========================================="
echo ""
echo "This script will:"
echo "1. Create a new node group with Cilium"
echo "2. Install Cilium CNI in full mode"
echo "3. Drain VPC-CNI nodes"
echo "4. Migrate pods to Cilium nodes"
echo "5. Remove VPC-CNI"
echo ""
read -p "Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Check prerequisites
command -v helm >/dev/null 2>&1 || { echo "helm is required but not installed.  Aborting." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required but not installed.  Aborting." >&2; exit 1; }

CLUSTER_NAME=$(grep cluster_name terraform/terraform.tfvars | awk -F'"' '{print $2}')
REGION=$(grep region terraform/terraform.tfvars | awk -F'"' '{print $2}')

echo ""
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo ""

# Phase 1: Record current state
echo "=========================================="
echo "Phase 1: Recording Current State"
echo "=========================================="
echo "Current VPC-CNI pods:"
kubectl get pods -A -o wide | tee pre-migration-pods.txt

echo ""
echo "Current pod IP ranges:"
kubectl get pods -A -o wide | awk '{print $7}' | grep -E '^[0-9]+\.' | sort -u

# Phase 2: Install Cilium
echo ""
echo "=========================================="
echo "Phase 2: Installing Cilium CNI"
echo "=========================================="
echo "Adding Cilium Helm repository..."
helm repo add cilium https://helm.cilium.io/
helm repo update

echo ""
echo "Installing Cilium in FULL mode (NOT chaining)..."
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set egressGateway.enabled=true \
  --set bpf.masquerade=true \
  --set kubeProxyReplacement=true \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList[0]="10.244.0.0/16" \
  --set eni.enabled=false

echo ""
echo "Waiting for Cilium to be ready..."
kubectl rollout status daemonset/cilium -n kube-system --timeout=300s

# Phase 3: Verify Cilium
echo ""
echo "=========================================="
echo "Phase 3: Verifying Cilium Installation"
echo "=========================================="
echo "Cilium Pods:"
kubectl get pods -n kube-system -l k8s-app=cilium

echo ""
echo "Checking Cilium status..."
CILIUM_POD=$(kubectl get pod -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n kube-system "$CILIUM_POD" -- cilium-dbg status --brief

# Phase 4: Node-by-Node Migration
echo ""
echo "=========================================="
echo "Phase 4: Migrating Nodes"
echo "=========================================="
echo "This will drain VPC-CNI nodes and let pods reschedule to Cilium nodes."
echo ""

OLD_NODES=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name")

for NODE in $OLD_NODES; do
    echo ""
    echo "Migrating node: $NODE"
    echo "---"

    # Cordon node
    echo "1. Cordoning node..."
    kubectl cordon "$NODE"

    # Drain node
    echo "2. Draining node (this may take a few minutes)..."
    kubectl drain "$NODE" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --grace-period=120 \
        --timeout=600s

    # Wait for pods to reschedule
    echo "3. Waiting for pods to reschedule..."
    sleep 30

    # Show new pod IPs
    echo "4. New pod IPs (should be 10.244.x.x):"
    kubectl get pods -o wide | grep -E 'NAME|test'

    echo ""
    echo "Node $NODE migrated. Pods should now have overlay IPs (10.244.x.x)"
    echo ""
    read -p "Continue to next node? (yes/no): " CONTINUE
    if [ "$CONTINUE" != "yes" ]; then
        echo "Migration paused. Resume with: kubectl uncordon <node>"
        exit 0
    fi
done

# Phase 5: Remove VPC-CNI
echo ""
echo "=========================================="
echo "Phase 5: Removing VPC-CNI"
echo "=========================================="
echo "All nodes migrated. Removing VPC-CNI..."
kubectl delete daemonset -n kube-system aws-node || true

# Phase 6: Verify Migration
echo ""
echo "=========================================="
echo "Phase 6: Verifying Migration"
echo "=========================================="
echo "Current pods (should have 10.244.x.x IPs):"
kubectl get pods -A -o wide | tee post-migration-pods.txt

echo ""
echo "Pod IP ranges (should be 10.244.x.x):"
kubectl get pods -A -o wide | awk '{print $7}' | grep -E '^[0-9]+\.' | sort -u

# Phase 7: Test Connectivity
echo ""
echo "=========================================="
echo "Phase 7: Testing Connectivity"
echo "=========================================="
CURL_POD=$(kubectl get pod -l app=curl-test -o jsonpath='{.items[0].metadata.name}')
if [ -n "$CURL_POD" ]; then
    echo "Testing internal service connectivity..."
    kubectl exec "$CURL_POD" -- curl -s -o /dev/null -w "%{http_code}" http://test-app-svc

    echo ""
    echo "Testing external connectivity..."
    kubectl exec "$CURL_POD" -- curl -s https://ifconfig.me
else
    echo "curl-test pod not found. Skipping connectivity tests."
fi

# Summary
echo ""
echo "=========================================="
echo "Migration Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "- VPC-CNI removed"
echo "- Cilium CNI active"
echo "- Pods using overlay IPs (10.244.x.x)"
echo ""
echo "Next Steps:"
echo "1. Deploy egress gateway node (update terraform, set gateway_desired_size = 1)"
echo "2. Apply egress gateway policy"
echo "3. Test egress gateway functionality"
echo ""
echo "See: ../../docs/CONFIGURATION.md for egress gateway setup"
echo ""
