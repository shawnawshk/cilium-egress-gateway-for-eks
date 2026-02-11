# Architecture Overview

High-level architecture of Cilium egress gateway on AWS EKS.

## Table of Contents

- [System Architecture](#system-architecture)
- [Network Design](#network-design)
- [Component Overview](#component-overview)
- [Traffic Flow](#traffic-flow)
- [High Availability](#high-availability)
- [Security Model](#security-model)
- [Scaling](#scaling)

---

## System Architecture

### Before: VPC-CNI

```
┌─────────────────────────────────────────┐
│  EKS Cluster (VPC-CNI)                  │
│                                          │
│  ┌────────────┐      ┌────────────┐    │
│  │ Worker 1   │      │ Worker 2   │    │
│  │            │      │            │    │
│  │ Pod        │      │ Pod        │    │
│  │ 10.1.12.x  │      │ 10.1.16.x  │    │
│  └────┬───────┘      └────┬───────┘    │
│       │                   │             │
│       └────────┬──────────┘             │
│                │                         │
│         ┌──────▼──────┐                 │
│         │ NAT Gateway │                 │
│         │ 52.x.x.x    │                 │
│         └──────┬──────┘                 │
└────────────────┼────────────────────────┘
                 │
                 ▼
            Internet
```

**Characteristics:**
- Pods have VPC IPs (10.1.x.x)
- No encapsulation
- All pods share NAT Gateway IP
- ENI capacity limits

### After: Cilium with Egress Gateway

```
┌───────────────────────────────────────────────┐
│  EKS Cluster (Cilium)                         │
│                                                │
│  Private Subnet                                │
│  ┌────────────┐      ┌────────────┐          │
│  │ Worker 1   │      │ Worker 2   │          │
│  │            │      │            │          │
│  │ Pod        │      │ Pod        │          │
│  │ 10.244.1.x │◄────►│ 10.244.0.x │          │
│  └────┬───────┘ VXLAN└────┬───────┘          │
│       │                   │                   │
│       │  VXLAN Tunnel     │                   │
│       └────────┬──────────┘                   │
│                │                               │
│  Public Subnet │                               │
│  ┌─────────────▼──────────┐                   │
│  │ Gateway Node           │                   │
│  │ EIP: 100.48.235.218    │                   │
│  │                         │                   │
│  │ - eBPF SNAT            │                   │
│  │ - No workload pods     │                   │
│  └─────────────┬───────────┘                   │
└────────────────┼────────────────────────────────┘
                 │
                 ▼
            Internet
```

**Characteristics:**
- Pods have overlay IPs (10.244.x.x)
- VXLAN encapsulation
- Per-application egress IPs
- No ENI limits

---

## Network Design

### IP Address Allocation

```
AWS VPC Network (10.0.0.0/16)
├── Private Subnets (Workers)
│   ├── 10.0.0.0/20   (AZ-a)
│   ├── 10.0.16.0/20  (AZ-b)
│   └── 10.0.32.0/20  (AZ-c)
│
├── Public Subnets (Gateways)
│   ├── 10.0.48.0/24  (AZ-a)
│   ├── 10.0.49.0/24  (AZ-b)
│   └── 10.0.50.0/24  (AZ-c)
│
Cilium Overlay Network (10.244.0.0/16)
├── 10.244.0.0/24  (Worker 1)
├── 10.244.1.0/24  (Worker 2)
└── ...

Kubernetes Service Network (172.20.0.0/16)
├── 172.20.0.1     (kubernetes)
├── 172.20.0.10    (kube-dns)
└── ...
```

**Key Point:** Overlay CIDR must NOT overlap with VPC CIDR.

### Gateway Node Placement

**Why Public Subnet?**

```
Private Subnet (❌ Wrong):
  Pod → Gateway → NAT Gateway → Internet
  Result: Loses static IP

Public Subnet (✅ Correct):
  Pod → Gateway → Internet Gateway → Internet
  Result: Preserves static IP
```

Gateway nodes MUST be in public subnets to avoid NAT Gateway hop.

---

## Component Overview

### 1. Cilium Agent (DaemonSet)

**Runs on:** Every node (workers + gateways)

**Key Functions:**
- eBPF packet processing
- VXLAN tunnel management
- IPAM (IP allocation to pods)
- Service load balancing (replaces kube-proxy)
- Egress gateway SNAT

**Configuration:**
```yaml
egressGateway.enabled: true
bpf.masquerade: true
routingMode: tunnel
ipam.mode: cluster-pool
```

### 2. Cilium Operator (Deployment)

**Runs on:** Control plane (2 replicas for HA)

**Key Functions:**
- Cluster-wide IPAM coordination
- Policy reconciliation
- Node allocation management

### 3. Gateway Nodes

**Purpose:** Dedicated nodes for egress traffic

**Characteristics:**
- Label: `node-role=gateway`
- Taint: Prevents workload pods
- Elastic IP: Static egress IP
- Location: Public subnet

**Configuration:**
```hcl
# terraform
subnet_ids = [public_subnet]
labels = {
  node-role = "gateway"
}
taints = [{
  key    = "egress-gateway"
  effect = "NO_SCHEDULE"
}]
```

### 4. CiliumEgressGatewayPolicy (CRD)

**Purpose:** Define egress routing rules

**Example:**
```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: frontend-egress
spec:
  # Which pods
  selectors:
  - podSelector:
      matchLabels:
        app: frontend
  # Where to route
  destinationCIDRs:
  - "0.0.0.0/0"
  # Which gateway
  egressGateway:
    nodeSelector:
      matchLabels:
        node-role: gateway
```

---

## Traffic Flow

### Internal Pod-to-Pod

```
1. Pod A (10.244.1.4) → Pod B (10.244.0.238)
2. Cilium eBPF: Lookup route (dest on different node)
3. VXLAN encapsulation
4. Send to Node 2 via VXLAN tunnel (UDP 8472)
5. Node 2: VXLAN decapsulation
6. Deliver to Pod B
```

**Performance:** ~1.3ms average latency (+15% vs VPC-CNI)

### External Egress (via Gateway)

```
1. Pod A (10.244.1.4) → api.example.com
2. Cilium eBPF: Match egress policy
   - Pod label: app=frontend ✓
   - Destination: 0.0.0.0/0 ✓
   - Action: Route to gateway
3. VXLAN encapsulation
4. Send to Gateway Node (10.0.48.87)
5. Gateway: VXLAN decapsulation
6. Gateway: SNAT (10.244.1.4 → 100.48.235.218)
7. Exit via Internet Gateway
8. External service sees: 100.48.235.218
```

**Latency:** ~53ms average (negligible +1ms vs NAT Gateway)

### Service Load Balancing

```
Request to Service IP (172.20.50.88)
  ↓
Cilium eBPF (replaces kube-proxy)
  ↓
Select backend pod
  ↓
Direct packet to pod (10.244.x.x)
```

**Performance:** Faster than iptables-based kube-proxy

---

## High Availability

### Multi-AZ Worker Nodes

```
AZ us-east-1a          AZ us-east-1b          AZ us-east-1c
┌──────────┐           ┌──────────┐           ┌──────────┐
│ Worker 1 │           │ Worker 2 │           │ Worker 3 │
│          │           │          │           │          │
│ Pod A    │           │ Pod B    │           │ Pod C    │
│ Pod D    │           │ Pod E    │           │ Pod F    │
└──────────┘           └──────────┘           └──────────┘
```

**Benefits:**
- Node failure: Pods reschedule to other AZs
- AZ failure: 2/3 capacity remains
- Kubernetes handles automatically

### Multi-AZ Gateway Nodes (Production)

```
Application: Frontend
┌──────────────────┬──────────────────┐
│ AZ-a             │ AZ-b             │
│ Gateway 1        │ Gateway 2        │
│ EIP: .218        │ EIP: .219        │
└──────────────────┴──────────────────┘

Application: Backend
┌──────────────────┬──────────────────┐
│ AZ-a             │ AZ-b             │
│ Gateway 3        │ Gateway 4        │
│ EIP: .220        │ EIP: .221        │
└──────────────────┴──────────────────┘
```

**Benefits:**
- Gateway failure: Traffic routes to other gateway
- Both Elastic IPs remain active
- Cilium load balances automatically
- Minimal configuration required

### Cilium HA

```
Component          Replicas    HA Strategy
─────────────────────────────────────────
Cilium Agent      DaemonSet   On every node
Cilium Operator   Deployment  2 replicas (leader election)
CoreDNS           Deployment  2+ replicas
```

---

## Security Model

### Network Segmentation

```
┌────────────────────────────────────────┐
│ Worker Nodes (Private Subnet)         │
│                                         │
│ ┌──────────┐  ┌──────────┐            │
│ │ Frontend │  │ Backend  │            │
│ │ Pods     │  │ Pods     │            │
│ └────┬─────┘  └────┬─────┘            │
│      │             │                   │
│      └─────┬───────┘                   │
│            │                           │
│     Network Policies                   │
│     - Frontend → Backend: Allow        │
│     - Backend → Database: Allow        │
│     - Frontend → Database: Deny        │
└────────────────────────────────────────┘

┌────────────────────────────────────────┐
│ Gateway Nodes (Public Subnet)          │
│                                         │
│ Taint: No workload pods                │
│ Security Group:                         │
│   - Inbound: VXLAN from workers (8472) │
│   - Outbound: All (0.0.0.0/0)          │
└────────────────────────────────────────┘
```

### Defense in Depth

```
Layer 1: Gateway Node Isolation
  ├─ No application pods
  ├─ Dedicated node for egress only
  └─ Minimal attack surface

Layer 2: Network Isolation
  ├─ Workers in private subnet
  ├─ No direct internet access
  └─ Gateway as choke point

Layer 3: VXLAN Tunnel
  ├─ Encrypted communication (optional WireGuard)
  ├─ Overlay network separate from VPC
  └─ Pod IPs not routable from internet

Layer 4: eBPF Policy Enforcement
  ├─ Policy-based routing
  ├─ Network policies
  └─ Kernel-level enforcement
```

### IAM Roles

```
Worker Node Role:
├─ AmazonEKSWorkerNodePolicy
├─ AmazonEC2ContainerRegistryReadOnly
└─ Application-specific permissions (IRSA)

Gateway Node Role:
├─ AmazonEKSWorkerNodePolicy
├─ AmazonEC2ContainerRegistryReadOnly
└─ Optional: EIP association permissions
```

---

## Scaling

### Horizontal Scaling

**Worker Nodes:**
```
Auto Scaling Group:
├─ Min: 3 (one per AZ)
├─ Desired: 5
├─ Max: 20
└─ Metrics: CPU, Memory
```

**Gateway Nodes:**
```
Manual scaling recommended:
├─ 2 per application (HA)
├─ Scale based on network throughput
└─ Each gateway: up to 10 Gbps
```

**Pod Autoscaling:**
```
HPA works normally:
├─ Cilium assigns overlay IPs automatically
├─ Egress policies apply automatically
└─ No additional configuration needed
```

### Vertical Scaling

**Worker Node Sizing:**
```
Small:    t3.small    (2 vCPU, 2 GB)   Testing
Medium:   m5.large    (2 vCPU, 8 GB)   Small prod
Large:    m5.xlarge   (4 vCPU, 16 GB)  Production
X-Large:  m5.2xlarge  (8 vCPU, 32 GB)  High-density
```

**Gateway Node Sizing:**
```
Small:    t3.small    (up to 5 Gbps)   Testing
Medium:   c5.large    (up to 10 Gbps)  Production
Large:    c5.xlarge   (up to 10 Gbps)  High-traffic
X-Large:  c5.2xlarge  (up to 10 Gbps)  Very high
```

### Capacity Planning

**Formula for Gateway Nodes:**
```
Required throughput: 5 Gbps peak
Gateway capacity: 10 Gbps each
HA requirement: 2× minimum

Calculation:
  5 Gbps ÷ 10 Gbps = 0.5 gateways
  × 2 (HA) = 1 gateway
  Recommendation: 2 gateways (per application)
```

**Pod Density:**
```
VPC-CNI: Limited by ENI capacity
  t3.small: ~11 pods
  m5.large: ~29 pods

Cilium: Limited by node resources
  t3.small: ~30-50 pods
  m5.large: ~100-150 pods
```

---

## Observability

### Metrics

**Cilium Metrics:**
```
cilium_egress_gateway_active_connections
cilium_endpoint_state
cilium_drop_count_total
cilium_bpf_map_pressure
```

**Node Metrics:**
```
node_network_transmit_bytes_total
node_cpu_seconds_total
node_memory_MemAvailable_bytes
```

### Logging

```
Cilium Agent Logs:
kubectl logs -n kube-system -l k8s-app=cilium

Flow Logs (Hubble):
hubble observe --from-label app=frontend --to-ip 0.0.0.0/0

CloudWatch:
- EKS control plane logs
- VPC Flow Logs
- Application logs
```

### Monitoring Dashboard

```
Key Metrics to Monitor:
├─ Gateway node CPU/Memory (< 80%)
├─ Network throughput (< 8 Gbps per gateway)
├─ Egress connection count (< 50k per gateway)
├─ Pod egress success rate (> 99.9%)
└─ DNS resolution time (< 100ms)
```

---

## Cost Structure

### Infrastructure Costs (Monthly)

**Test Cluster:**
```
2 × t3.small workers     $30.36
1 × t3.small gateway     $15.18
1 × Elastic IP           $3.60
1 × NAT Gateway          $32.40
─────────────────────────────
Total                    ~$82/month
```

**Production Cluster (5 apps, HA):**
```
5 × m5.large workers     $310
10 × c5.large gateways   $620
5 × Elastic IPs          $18
1 × NAT Gateway          $32
─────────────────────────────
Total                    ~$980/month

vs Multiple Clusters:
5 × separate clusters    ~$1,800/month
Savings: ~46%
```

---

## Summary

Cilium egress gateway provides:
- ✅ Per-application static egress IPs
- ✅ Policy-based routing control
- ✅ High availability across AZs
- ✅ Scalable to 100+ nodes
- ✅ Defense-in-depth security
- ✅ Production-grade performance

**Trade-offs:**
- Overlay network adds ~15% latency
- +150MB memory per node
- Increased operational complexity
- Learning curve for Cilium

**Best for:**
- IP whitelisting requirements
- Compliance and audit needs
- Multi-application IP isolation
- High-security environments

For detailed information:
- [Egress Gateway Guide](EGRESS-GATEWAY.md)
- [Migration Guide](MIGRATION-GUIDE.md)
- [Troubleshooting](TROUBLESHOOTING.md)
