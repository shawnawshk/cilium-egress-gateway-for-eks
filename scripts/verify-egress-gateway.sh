#!/bin/bash
set -e

# Egress Gateway Verification Script
# Tests if Cilium egress gateway is working correctly

echo "=========================================="
echo "Cilium Egress Gateway Verification"
echo "=========================================="
echo ""

# Color output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
    echo -e "${GREEN}✓${NC} $1"
}

fail() {
    echo -e "${RED}✗${NC} $1"
}

warn() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Check prerequisites
echo "Checking prerequisites..."
command -v kubectl >/dev/null 2>&1 || { fail "kubectl is required but not installed."; exit 1; }
command -v aws >/dev/null 2>&1 || { fail "AWS CLI is required but not installed."; exit 1; }
pass "Prerequisites installed"
echo ""

# 1. Check Gateway Nodes
echo "=========================================="
echo "1. Gateway Node Status"
echo "=========================================="

GATEWAY_NODES=$(kubectl get nodes -l node-role=gateway --no-headers 2>/dev/null | wc -l)
if [ "$GATEWAY_NODES" -eq 0 ]; then
    fail "No gateway nodes found"
    echo "   Expected: Nodes with label 'node-role=gateway'"
    echo "   Fix: Deploy gateway nodes with terraform"
    exit 1
else
    pass "Found $GATEWAY_NODES gateway node(s)"
    kubectl get nodes -l node-role=gateway
fi
echo ""

# 2. Check Gateway Node Configuration
echo "=========================================="
echo "2. Gateway Node Configuration"
echo "=========================================="

GATEWAY_NODE=$(kubectl get nodes -l node-role=gateway -o jsonpath='{.items[0].metadata.name}')
if [ -n "$GATEWAY_NODE" ]; then
    pass "Gateway node: $GATEWAY_NODE"

    # Check required labels
    NODE_ROLE=$(kubectl get node "$GATEWAY_NODE" -o jsonpath='{.metadata.labels.node-role}')
    if [ "$NODE_ROLE" = "gateway" ]; then
        pass "Label 'node-role=gateway' present"
    else
        fail "Label 'node-role=gateway' missing"
    fi

    # Check taints (should prevent workload pods)
    TAINTS=$(kubectl get node "$GATEWAY_NODE" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null)
    if echo "$TAINTS" | grep -q "egress-gateway"; then
        pass "Gateway node is tainted (prevents workload pods)"
    else
        warn "Gateway node has no taint - workload pods may schedule here"
        echo "   Recommended: Add taint to prevent non-gateway workloads"
        echo "   kubectl taint node $GATEWAY_NODE egress-gateway=true:NoSchedule"
    fi
fi
echo ""

# 3. Check Elastic IP Association
echo "=========================================="
echo "3. Elastic IP Configuration"
echo "=========================================="

INSTANCE_ID=$(kubectl get node "$GATEWAY_NODE" -o jsonpath='{.spec.providerID}' 2>/dev/null | cut -d'/' -f5)
if [ -n "$INSTANCE_ID" ]; then
    pass "Gateway instance ID: $INSTANCE_ID"

    # Check for EIP
    EIP=$(aws ec2 describe-addresses --filters "Name=instance-id,Values=$INSTANCE_ID" \
        --query 'Addresses[0].PublicIp' --output text 2>/dev/null)

    if [ "$EIP" != "None" ] && [ -n "$EIP" ]; then
        pass "Elastic IP associated: $EIP"
        echo "   This is your egress IP for gateway traffic"
    else
        warn "No Elastic IP associated with gateway node"
        echo "   Gateway will use NAT Gateway instead"
        echo "   To allocate EIP: aws ec2 allocate-address --domain vpc"
        echo "   To associate: aws ec2 associate-address --instance-id $INSTANCE_ID --allocation-id <alloc-id>"
    fi
fi
echo ""

# 4. Check Cilium Status
echo "=========================================="
echo "4. Cilium Agent Status"
echo "=========================================="

CILIUM_PODS=$(kubectl get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | wc -l)
if [ "$CILIUM_PODS" -eq 0 ]; then
    fail "No Cilium pods found"
    exit 1
else
    pass "Found $CILIUM_PODS Cilium agent(s)"
fi

CILIUM_POD=$(kubectl get pod -n kube-system -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}')
if kubectl exec -n kube-system "$CILIUM_POD" -- cilium-dbg status --brief >/dev/null 2>&1; then
    pass "Cilium agent healthy"

    # Check egress gateway feature (via BPF map test)
    # Note: Status output varies, so we test actual functionality below
else
    fail "Cilium agent not healthy"
fi
echo ""

# 5. Check Egress Gateway Policies
echo "=========================================="
echo "5. Egress Gateway Policies"
echo "=========================================="

POLICIES=$(kubectl get ciliumegressgatewaypolicy --no-headers 2>/dev/null | wc -l)
if [ "$POLICIES" -eq 0 ]; then
    warn "No egress gateway policies found"
    echo "   Pods won't use gateway without policies"
    echo "   Create policy: kubectl apply -f kubernetes/egress-gateway-policy.yaml"
else
    pass "Found $POLICIES egress gateway policy/policies"
    kubectl get ciliumegressgatewaypolicy
fi
echo ""

# 6. Check BPF Egress Map
echo "=========================================="
echo "6. BPF Egress Routing Table"
echo "=========================================="

if [ "$POLICIES" -gt 0 ]; then
    echo "BPF egress map entries:"
    kubectl exec -n kube-system "$CILIUM_POD" -- cilium-dbg bpf egress list 2>/dev/null || warn "Could not retrieve BPF egress map"
else
    warn "No policies configured, BPF map will be empty"
fi
echo ""

# 7. Test Pod Placement
echo "=========================================="
echo "7. Test Pod Placement (should be on workers)"
echo "=========================================="

# Find a test pod
TEST_POD=$(kubectl get pod -l app=curl-test -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$TEST_POD" ]; then
    TEST_POD=$(kubectl get pod -l app=test-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi

if [ -n "$TEST_POD" ]; then
    echo "Using test pod: $TEST_POD"

    # Check which node the pod is on
    POD_NODE=$(kubectl get pod "$TEST_POD" -o jsonpath='{.spec.nodeName}')
    NODE_ROLE=$(kubectl get node "$POD_NODE" -o jsonpath='{.metadata.labels.node-role}' 2>/dev/null)

    echo "Pod running on node: $POD_NODE"
    if [ "$NODE_ROLE" = "gateway" ]; then
        fail "Test pod is on GATEWAY node (should be on worker node)"
        echo "   Gateway nodes should be tainted to prevent workload pods"
        echo "   Check: kubectl describe node $POD_NODE | grep Taints"
    else
        pass "Test pod is on WORKER node (correct)"
        echo "   Gateway node should only handle egress traffic routing"
    fi

    # Check pod labels
    POD_LABELS=$(kubectl get pod "$TEST_POD" -o jsonpath='{.metadata.labels}')
    echo "Pod labels: $POD_LABELS"
echo ""

# 8. Egress IP Verification
echo "=========================================="
echo "8. Egress IP Test (Actual Traffic)"
echo "=========================================="

    # Test egress IP
    echo ""
    echo "Testing egress IP (this may take a few seconds)..."
    EGRESS_IP_DETECTED=$(kubectl exec "$TEST_POD" -- curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "timeout")

    if [ "$EGRESS_IP_DETECTED" = "timeout" ]; then
        fail "Could not detect egress IP (timeout)"
    elif [ -n "$EIP" ] && [ "$EGRESS_IP_DETECTED" = "$EIP" ]; then
        pass "Pod is using gateway egress IP: $EGRESS_IP_DETECTED"
        echo "   ✓ Egress gateway is working!"
    else
        if [ -n "$EIP" ]; then
            warn "Pod egress IP: $EGRESS_IP_DETECTED (expected: $EIP)"
            echo ""
            echo "Troubleshooting:"
            echo "1. Check if pod labels match policy selector"
            echo "2. Restart pod to apply policy: kubectl rollout restart deployment"
            echo "3. Check Cilium logs: kubectl logs -n kube-system $CILIUM_POD | grep egress"
        else
            warn "Pod egress IP: $EGRESS_IP_DETECTED"
            echo "   No EIP associated with gateway, using NAT Gateway"
        fi
    fi
else
    warn "No test pods found"
    echo "   Deploy test app: kubectl apply -f kubernetes/test-app.yaml"
fi
echo ""

# 9. Summary
echo "=========================================="
echo "Summary"
echo "=========================================="
echo ""
echo "Gateway Nodes:    $GATEWAY_NODES"
echo "Gateway EIP:      ${EIP:-Not configured}"
echo "Cilium Agents:    $CILIUM_PODS"
echo "Egress Policies:  $POLICIES"
echo ""

if [ "$POLICIES" -gt 0 ] && [ -n "$EIP" ] && [ "$EGRESS_IP_DETECTED" = "$EIP" ]; then
    echo -e "${GREEN}✓ Egress Gateway is WORKING correctly!${NC}"
    echo ""
    echo "Your pods are using static egress IP: $EIP"
    echo "External services will see this IP for whitelisting."
elif [ "$POLICIES" -eq 0 ]; then
    echo -e "${YELLOW}⚠ Egress Gateway is configured but NO POLICIES applied${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Apply egress policy: kubectl apply -f kubernetes/egress-gateway-policy.yaml"
    echo "2. Restart pods: kubectl rollout restart deployment <app>"
    echo "3. Re-run this script to verify"
elif [ -z "$EIP" ]; then
    echo -e "${YELLOW}⚠ Egress Gateway configured but NO ELASTIC IP associated${NC}"
    echo ""
    echo "Next steps:"
    echo "1. Allocate EIP: aws ec2 allocate-address --domain vpc"
    echo "2. Associate with gateway: aws ec2 associate-address --instance-id $INSTANCE_ID --allocation-id <alloc-id>"
    echo "3. Re-run this script to verify"
else
    echo -e "${YELLOW}⚠ Egress Gateway configuration incomplete${NC}"
    echo ""
    echo "Check the issues above and refer to docs/EGRESS-GATEWAY.md"
fi
echo ""
