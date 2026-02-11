# Cilium Egress Gateway Complete Guide

Complete guide to Cilium egress gateway on AWS EKS, from basics to production deployment.

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Approach Comparison](#approach-comparison)
- [Setup Guide](#setup-guide)
- [Configuration Reference](#configuration-reference)
- [Architecture & Internals](#architecture--internals)
- [Production Considerations](#production-considerations)

---

## Overview

Cilium egress gateway provides **static, predictable source IP addresses** for outbound traffic from Kubernetes pods.

### Use Cases

- **IP Whitelisting**: External APIs requiring source IP registration
- **Compliance**: Audit trails needing consistent source IPs
- **Firewall Rules**: On-premises systems allowing specific IPs only
- **Rate Limiting**: Per-IP rate limits from external services
- **Multi-tenant**: Different applications need IP isolation

### Problem & Solution

**Without Egress Gateway:**
```
Frontend pods  ──┐
Backend pods   ──┼─→ NAT Gateway → Internet (52.202.231.151)
Admin pods     ──┘
                   All traffic from same IP
                   ❌ Cannot whitelist per-application
```

**With Cilium Egress Gateway:**
```
Frontend pods  → Gateway Node 1 (EIP: 100.48.235.218) → Internet
Backend pods   → Gateway Node 2 (EIP: 100.48.235.219) → Internet
Admin pods     → Gateway Node 3 (EIP: 100.48.235.220) → Internet

✅ Each application has dedicated egress IP
✅ External services can whitelist specific IPs
```

---

## How It Works

Cilium Egress Gateway uses:
1. **Overlay networking** (VXLAN) for pod-to-pod communication
2. **eBPF programs** for high-performance packet processing
3. **Dedicated gateway nodes** with static Elastic IPs
4. **Policy-based routing** to select which pods use the gateway

### Core Components

#### 1. Cilium Agent
**Location:** DaemonSet running on every node

**Responsibilities:**
- Load and manage eBPF programs
- Watch CiliumEgressGatewayPolicy resources
- Build and maintain BPF egress maps
- Handle VXLAN encapsulation/decapsulation
- Perform SNAT (Source NAT) on gateway nodes

**Key Configuration:**
```yaml
egressGateway:
  enabled: true
bpf:
  masquerade: true  # CRITICAL for SNAT
kubeProxyReplacement: true
```

#### 2. Gateway Node
**Location:** EC2 instance in public subnet

**Characteristics:**
- Has `node-role=gateway` label
- Runs in PUBLIC subnet (not private)
- Has Elastic IP attached to primary ENI
- Taint prevents regular pod scheduling

**Configuration:**
```yaml
labels:
  node-role: gateway
  egress-gateway: "true"
taints:
- key: egress-gateway
  value: "true"
  effect: NoSchedule
```

#### 3. CiliumEgressGatewayPolicy
**Purpose:** Defines which pods route through gateway

**Example:**
```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: egress-policy
spec:
  selectors:
  - podSelector:
      matchLabels:
        egress: enabled
  destinationCIDRs:
  - "0.0.0.0/0"
  excludedCIDRs:
  - "10.0.0.0/8"
  egressGateway:
    nodeSelector:
      matchLabels:
        node-role: gateway
```

### Traffic Flow

**Step 1: Pod Initiates Connection**
```
Pod (10.244.0.79) → curl https://api.example.com
```

**Step 2: eBPF Hook Intercepts**
```
Location: Worker node network stack
Actions:
1. Read packet destination: api.example.com
2. Check pod labels: egress=enabled ✓
3. Query CiliumEgressGatewayPolicy
4. Decision: Route through gateway node
```

**Step 3: BPF Map Lookup**
```
Map: cilium_egress_gw_policy_v4
Lookup: source_ip=10.244.0.79, dest_cidr=0.0.0.0/0
Result: gateway_node_ip=10.0.48.87
```

**Step 4: VXLAN Encapsulation**
```
Original:
┌─────────────────────────┐
│ Src: 10.244.0.79        │
│ Dst: api.example.com    │
│ Payload: [HTTPS request]│
└─────────────────────────┘

VXLAN Encapsulated:
┌─────────────────────────┐
│ Outer Src: 10.0.23.235  │ ← Worker node IP
│ Outer Dst: 10.0.48.87   │ ← Gateway node IP
│ UDP Port: 8472          │ ← VXLAN port
│ ┌─────────────────────┐ │
│ │ Inner [Original]    │ │
│ └─────────────────────┘ │
└─────────────────────────┘
```

**Step 5: Gateway Node Processing**
```
Gateway Node (10.0.48.87)
1. Receive VXLAN packet on UDP 8472
2. De-encapsulate to get original packet
3. eBPF masquerade program executes
4. SNAT: 10.244.0.79 → 34.227.253.97 (Elastic IP)
5. Route to internet gateway
```

**Step 6: Packet Exits**
```
Final Packet:
┌─────────────────────────┐
│ Src: 34.227.253.97      │ ← Gateway EIP
│ Dst: api.example.com    │
│ Payload: [HTTPS request]│
└─────────────────────────┘

External service sees: 34.227.253.97
```

---

## Approach Comparison

### Three Egress Approaches

| Aspect | NAT Gateway | Nodes in Public | Cilium Gateway |
|--------|-------------|-----------------|----------------|
| **Complexity** | ✅ Simple | ✅ Simple | ❌ Complex |
| **Cost** | ⚠️ ~$32/mo | ✅ $0 extra | ⚠️ ~$30/mo |
| **Security** | ✅ Good | ⚠️ Medium | ✅ Excellent |
| **IP Stability** | ✅ Stable | ✅ Stable | ✅ Static |
| **IP Whitelisting** | ❌ No | ❌ No | ✅ Yes |
| **Setup Time** | ✅ 5 min | ✅ 10 min | ❌ 1-2 hours |

### NAT Gateway (AWS Default)

**How it works:**
```
Pods → NAT Gateway (52.71.82.52) → Internet
```

**Pros:**
- ✅ Simple setup (default AWS)
- ✅ AWS-managed (no maintenance)
- ✅ Highly available
- ✅ Single egress IP

**Cons:**
- ❌ Ongoing cost (~$37/month)
- ❌ No IP whitelisting
- ❌ Shared IP across all pods

**Best for:**
- Default choice for most use cases
- When you don't need IP whitelisting
- Standard security requirements

### Nodes in Public Subnet

**How it works:**
```
Pods → Worker Nodes (with public IPs) → Internet
```

**Pros:**
- ✅ Cost effective ($0 extra)
- ✅ Simple setup

**Cons:**
- ⚠️ Multiple IPs exposed (N nodes)
- ⚠️ Worker nodes directly accessible
- ⚠️ Larger attack surface
- ❌ No IP whitelisting

**Best for:**
- Development/staging
- Small clusters (< 5 nodes)
- Cost-sensitive deployments
- Low security requirements

**Security Warning:**
```
Attack scenario:
1. External service compromised
2. Attacker sees node IPs
3. Attacker scans nodes → finds kubelet (10250)
4. Node exploit → pod access
```

### Cilium Egress Gateway

**How it works:**
```
Pods → VXLAN tunnel → Gateway Node → Elastic IP → Internet
```

**Pros:**
- ✅ Single static IP per application
- ✅ IP whitelisting capable
- ✅ Gateway isolated from workloads
- ✅ Policy-based routing
- ✅ Scales infinitely

**Cons:**
- ❌ Complex setup
- ❌ Requires Cilium expertise
- ❌ Additional gateway node cost

**Best for:**
- Third-party API requiring IP whitelisting
- Compliance requirements
- High-security production
- Multi-application IP isolation

### Decision Matrix

**Choose NAT Gateway if:**
- ✅ No IP whitelisting needed
- ✅ Want AWS-managed infrastructure
- ✅ Prefer simplicity
- ✅ ~$40/month is acceptable

**Choose Nodes in Public if:**
- ✅ Cost optimization priority
- ✅ Small cluster (< 5 nodes)
- ✅ Dev/staging environment
- ✅ Medium security acceptable

**Choose Cilium Gateway if:**
- ✅ Need IP whitelisting
- ✅ Compliance/audit requirements
- ✅ High security needed
- ✅ Per-application IP control
- ✅ Defense-in-depth architecture

---

## Setup Guide

Complete step-by-step setup for Cilium egress gateway on EKS.

### Prerequisites

- ✅ EKS cluster (Kubernetes 1.35+)
- ✅ Cilium CNI installed (see migration guide)
- ✅ Helm >= 3.12
- ✅ kubectl >= 1.35
- ✅ AWS CLI v2

### Step 1: Deploy Gateway Node

Update Terraform configuration:
```hcl
# terraform.tfvars
gateway_desired_size  = 1
gateway_instance_type = "t3.small"
```

Deploy:
```bash
cd terraform/
terraform plan
terraform apply

# Wait for node to join (2-3 minutes)
kubectl get nodes -w
```

Expected output:
```
NAME                         STATUS   ROLES    AGE
ip-10-1-1-245.ec2.internal   Ready    <none>   5d   # worker
ip-10-1-30-15.ec2.internal   Ready    <none>   5d   # worker
ip-10-1-x-xxx.ec2.internal   Ready    <none>   1m   # gateway
```

### Step 2: Verify Gateway Node Label

Gateway nodes need `node-role=gateway` label:

```bash
# Check label
kubectl get nodes --show-labels | grep gateway

# Add if missing
kubectl label node <gateway-node-name> node-role=gateway
```

### Step 3: Allocate Elastic IP

```bash
# Get gateway node instance ID
GATEWAY_NODE=$(kubectl get nodes -l node-role=gateway \
  -o jsonpath='{.items[0].metadata.name}')
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=private-dns-name,Values=$GATEWAY_NODE" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Allocate Elastic IP
EIP_ALLOC=$(aws ec2 allocate-address \
  --domain vpc \
  --query 'AllocationId' \
  --output text)

# Associate with gateway node
aws ec2 associate-address \
  --instance-id $INSTANCE_ID \
  --allocation-id $EIP_ALLOC

# Get the public IP
EGRESS_IP=$(aws ec2 describe-addresses \
  --allocation-ids $EIP_ALLOC \
  --query 'Addresses[0].PublicIp' \
  --output text)

echo "Gateway egress IP: $EGRESS_IP"
```

### Step 4: Apply Egress Gateway Policy

Create `egress-gateway-policy.yaml`:
```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: test-app-egress
spec:
  selectors:
  - podSelector:
      matchLabels:
        app: test-app
  destinationCIDRs:
  - "0.0.0.0/0"
  egressGateway:
    nodeSelector:
      matchLabels:
        node-role: gateway
```

Apply:
```bash
kubectl apply -f egress-gateway-policy.yaml

# Verify
kubectl get ciliumegressgatewaypolicy
```

### Step 5: Test Egress IP

Restart pods to pick up policy:
```bash
kubectl rollout restart deployment test-app

# Wait for ready
kubectl wait --for=condition=ready pod -l app=test-app --timeout=60s

# Test egress IP
kubectl exec <pod> -- curl -s ifconfig.me
# Should show gateway Elastic IP
```

### Multi-Application Setup

Different applications with different IPs:

```yaml
---
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: frontend-egress
spec:
  selectors:
  - podSelector:
      matchLabels:
        tier: frontend
  destinationCIDRs:
  - "0.0.0.0/0"
  egressGateway:
    nodeSelector:
      matchLabels:
        gateway-group: frontend  # Gateway 1 with EIP 1

---
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: backend-egress
spec:
  selectors:
  - podSelector:
      matchLabels:
        tier: backend
  destinationCIDRs:
  - "0.0.0.0/0"
  egressGateway:
    nodeSelector:
      matchLabels:
        gateway-group: backend  # Gateway 2 with EIP 2
```

### Troubleshooting

**Gateway Node Not Ready:**
```bash
kubectl describe node <gateway-node>
```

**Pods Not Using Gateway:**
```bash
# Check policy matches labels
kubectl get pod --show-labels
kubectl describe ciliumegressgatewaypolicy

# Check Cilium status
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg bpf egress list
```

**Egress IP Unchanged:**
1. Verify Elastic IP associated with gateway node
2. Restart pods to pick up policy
3. Check Cilium logs:
```bash
kubectl logs -n kube-system <cilium-pod> | grep -i egress
```

---

## Configuration Reference

### Critical Settings

Settings **absolutely required** for egress gateway:

#### 1. BPF Masquerading ⚠️ CRITICAL

```yaml
bpf:
  masquerade: true
```

**Why critical:** Enables SNAT at eBPF level. Without this, pod IPs are not changed to egress IP.

**Verification:**
```bash
kubectl exec -n kube-system ds/cilium -- \
  cilium-dbg status | grep Masquerading
# Output: Masquerading: BPF [ens5] ✓
```

#### 2. Egress Gateway Feature

```yaml
egressGateway:
  enabled: true
```

**Why required:** Activates the egress gateway subsystem and loads necessary eBPF programs.

#### 3. Overlay Networking (VXLAN)

```yaml
routingMode: tunnel
tunnelProtocol: vxlan
```

**Why required:** Enables cross-node traffic routing through gateway node.

#### 4. Cluster-Pool IPAM

```yaml
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.244.0.0/16"
```

**Why required:** Cilium manages pod IPs (not AWS), separate from VPC CIDR.

#### 5. Disable ENI Mode

```yaml
eni:
  enabled: false
```

**Why critical:** ENI mode uses VPC networking (incompatible with egress gateway).

### Complete Production Configuration

```yaml
# Enable egress gateway
egressGateway:
  enabled: true

# BPF masquerading (CRITICAL!)
bpf:
  masquerade: true
  masqMode: BPF

# Replace kube-proxy
kubeProxyReplacement: true

# VXLAN overlay
routingMode: tunnel
tunnelProtocol: vxlan

# Cluster-pool IPAM
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - "10.244.0.0/16"

# Disable ENI (CRITICAL!)
eni:
  enabled: false

# Operator HA
operator:
  replicas: 2
  rollOutPods: true

# Observability
hubble:
  enabled: true
  relay:
    enabled: true
    replicas: 2

# Metrics
prometheus:
  enabled: true
  serviceMonitor:
    enabled: true

# Resources
resources:
  limits:
    cpu: 2000m
    memory: 2Gi
  requests:
    cpu: 200m
    memory: 512Mi
```

### Installation

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --version 1.16.5 \
  --namespace kube-system \
  --values cilium-values.yaml
```

### Policy Configuration

**Basic Policy:**
```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: egress-policy
spec:
  selectors:
  - podSelector:
      matchLabels:
        egress: enabled
  destinationCIDRs:
  - "0.0.0.0/0"
  excludedCIDRs:
  - "10.0.0.0/8"       # VPC and pod networks
  - "172.16.0.0/12"    # Private networks
  - "192.168.0.0/16"   # Private networks
  egressGateway:
    nodeSelector:
      matchLabels:
        node-role: gateway
```

**Multiple Labels (OR logic):**
```yaml
spec:
  selectors:
  - podSelector:
      matchLabels:
        egress: enabled
  - podSelector:
      matchLabels:
        app: api-server
```

**Namespace-Specific:**
```yaml
spec:
  selectors:
  - podSelector:
      matchLabels:
        egress: enabled
    namespaceSelector:
      matchLabels:
        environment: production
```

**Specific Destination:**
```yaml
spec:
  destinationCIDRs:
  - "52.1.2.3/32"      # Specific IP
  - "203.0.113.0/24"   # Specific subnet
  excludedCIDRs: []
```

### Node Configuration

**Gateway Node (Terraform):**
```hcl
module "eks_managed_node_group_gateway" {
  source = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"

  name = "${var.cluster_name}-gateway"

  # MUST be in PUBLIC subnet
  subnet_ids = [module.vpc.public_subnets[0]]

  min_size     = 1
  max_size     = 3
  desired_size = 1

  instance_types = ["m5.large"]

  labels = {
    node-role      = "gateway"
    egress-gateway = "true"
  }

  # Prevent regular pods
  taints = [{
    key    = "egress-gateway"
    value  = "true"
    effect = "NO_SCHEDULE"
  }]
}
```

### Verification Commands

```bash
# Verify BPF masquerading
kubectl exec -n kube-system ds/cilium -- \
  cilium-dbg status | grep Masquerading

# Verify egress gateway enabled
kubectl exec -n kube-system ds/cilium -- \
  cilium-dbg status | grep "Egress Gateway"

# Verify routing mode
kubectl exec -n kube-system ds/cilium -- \
  cilium-dbg status | grep Routing

# Check BPF maps
kubectl exec -n kube-system ds/cilium -- \
  cilium-dbg bpf egress list
```

---

## Architecture & Internals

### Gateway Node Design

**Why Public Subnet?**

Gateway nodes MUST be in public subnets:

```
Private Subnet Gateway (❌ Doesn't work):
  Pod → VXLAN → Gateway → NAT Gateway → Internet
  Problem: Extra hop through NAT, loses static IP

Public Subnet Gateway (✅ Works):
  Pod → VXLAN → Gateway → IGW → Internet
  EIP attached directly to node, static IP preserved
```

### eBPF Packet Processing

**Packet Path:**
```
VPC-CNI:
Pod → veth → bridge → eth0 → VPC → NAT → Internet
(Kernel networking, 4 hops)

Cilium:
Pod → veth → eBPF → VXLAN → Gateway → Internet
(eBPF processing, 4 hops)
```

**eBPF Execution Time:**
```
Average: 12-15 microseconds
99th percentile: 25 microseconds
Total overhead: < 1ms (imperceptible)
```

### Performance Impact

**Latency:**
| Metric | VPC-CNI | Cilium | Delta |
|--------|---------|--------|-------|
| Min | 0.8ms | 0.9ms | +0.1ms |
| Average | 1.1ms | 1.3ms | +0.2ms |
| P95 | 1.8ms | 2.1ms | +0.3ms |

**Throughput:**
| Test | VPC-CNI | Cilium | Delta |
|------|---------|--------|-------|
| Same Node | 9.5 Gbps | 9.2 Gbps | -3.2% |
| Cross Node | 4.8 Gbps | 4.6 Gbps | -4.2% |

**Resource Usage:**
| Component | VPC-CNI | Cilium | Delta |
|-----------|---------|--------|-------|
| CPU | 2.9% | 5.6% | +2.7% |
| Memory | 70 MB | 220 MB | +150 MB |

---

## Production Considerations

### High Availability

**Multiple Gateway Nodes:**
```yaml
# terraform/variables.tf
gateway_desired_size = 3  # One per AZ
```

**Anti-Affinity:**
```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
    - labelSelector:
        matchLabels:
          role: egress-gateway
      topologyKey: topology.kubernetes.io/zone
```

### Cost Optimization

**Gateway Node Sizing:**
| Workload | Traffic | Instance | Monthly Cost |
|----------|---------|----------|--------------|
| Low (< 100 Mbps) | API calls | t3.small | $15 |
| Medium (< 500 Mbps) | General web | c5.large | $62 |
| High (< 2 Gbps) | Data transfer | c5.xlarge | $124 |

**Spot Instances:**
```hcl
capacity_type = "SPOT"
instance_types = ["c5.large", "c5a.large", "c5n.large"]
# Savings: ~70% ($62/mo → $19/mo)
```

### Monitoring

**Required Metrics:**
```yaml
# Prometheus
- cilium_egress_gateway_active_connections
- cilium_egress_gateway_egress_bytes_total
- cilium_egress_gateway_drops_total

# CloudWatch
- Node network throughput
- Gateway node CPU/Memory
- Elastic IP data transfer
```

**Alerting:**
```yaml
- name: GatewayNodeUnhealthy
  expr: kube_node_status_condition{
    node=~".*gateway.*",
    condition="Ready",
    status="false"
  } == 1
  severity: critical
```

### Security

**Network Policies:**
```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: frontend-egress-policy
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
  - toFQDNs:
    - matchName: "api.stripe.com"
    - matchName: "api.sendgrid.com"
  - toPorts:
    - ports:
      - port: "443"
        protocol: TCP
```

**Gateway Node Hardening:**
- Minimal IAM permissions
- No SSH access (use SSM)
- Dedicated security group
- Regular patching

### Disaster Recovery

**Backup:**
```bash
# Daily backups
kubectl get ciliumegressgatewaypolicy -A -o yaml > backup/policies.yaml
kubectl get nodes -o yaml > backup/nodes.yaml
aws ec2 describe-addresses > backup/elastic-ips.json
```

**Recovery:**
```bash
# Gateway node failure (auto-handled by ASG)
# Manual: Associate EIP to new node
aws ec2 associate-address \
  --instance-id $NEW_INSTANCE_ID \
  --allocation-id $EIP_ALLOC_ID
```

---

## Summary

**When to Use Cilium Egress Gateway:**
- ✅ Need IP whitelisting for external APIs
- ✅ Compliance/audit requirements
- ✅ Per-application IP isolation
- ✅ High-security production environments

**Key Benefits:**
- Static egress IPs per application
- Policy-based routing control
- Defense-in-depth security
- Scales to any cluster size

**Trade-offs:**
- Complex setup and operation
- Requires Cilium expertise
- Additional infrastructure cost
- Performance overhead (~15%)

**Next Steps:**
1. Review [Migration Guide](MIGRATION-GUIDE.md) for existing clusters
2. See [Architecture](ARCHITECTURE.md) for system design
3. Check [Troubleshooting](TROUBLESHOOTING.md) for common issues
