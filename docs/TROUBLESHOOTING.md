# Troubleshooting Guide

Common issues and solutions for VPC-CNI to Cilium migration and egress gateway configuration.

## Table of Contents

1. [Migration Issues](#migration-issues)
2. [Cilium Issues](#cilium-issues)
3. [Egress Gateway Issues](#egress-gateway-issues)
4. [Network Connectivity Issues](#network-connectivity-issues)
5. [Performance Issues](#performance-issues)
6. [Diagnostic Commands](#diagnostic-commands)

---

## Migration Issues

### Issue: CoreDNS Pod Disruption Budget Blocks Drain

**Symptoms:**
```
error when evicting pods/"coredns-xxx" -n "kube-system" (will retry after 5s):
Cannot evict pod as it would violate the pod's disruption budget.
```

**Root Cause:**
- All nodes are cordoned simultaneously
- Last CoreDNS pod cannot be evicted (PDB protection)
- New CoreDNS pod cannot schedule (no available nodes)

**Solution 1: Temporary PDB Removal**
```bash
# Delete PDB temporarily
kubectl delete pdb coredns -n kube-system

# Drain will now complete
kubectl drain <node> --ignore-daemonsets

# Uncordon nodes
kubectl uncordon <node>

# PDB will be recreated automatically by EKS
```

**Solution 2: Sequential Migration**
```bash
# Migrate one node at a time, never cordon all nodes
for NODE in $NODES; do
  kubectl cordon $NODE
  kubectl drain $NODE --ignore-daemonsets
  kubectl wait --for=condition=ready pod --all --timeout=300s
  kubectl uncordon $NODE
  sleep 30  # Stabilization period
done
```

**Solution 3: Scale CoreDNS**
```bash
# Increase CoreDNS replicas before migration
kubectl scale deployment coredns -n kube-system --replicas=4

# Migrate nodes

# Scale back down
kubectl scale deployment coredns -n kube-system --replicas=2
```

**Prevention:**
- Never cordon all nodes simultaneously
- Always leave at least one node schedulable
- Consider scaling up critical deployments before migration

---

### Issue: Nodes Remain Cordoned After Migration

**Symptoms:**
```bash
kubectl get nodes
# NAME          STATUS                     ROLES    AGE
# node-1        Ready,SchedulingDisabled   <none>   5d
# node-2        Ready,SchedulingDisabled   <none>   5d

kubectl get pods
# All pods in Pending state
```

**Root Cause:**
Migration script cordons nodes but doesn't uncordon them

**Solution:**
```bash
# Uncordon all nodes
kubectl uncordon --all

# Or specific nodes
kubectl uncordon node-1 node-2

# Verify
kubectl get nodes
# All should show "Ready" without "SchedulingDisabled"
```

**Prevention:**
Update migration script to include automatic uncordoning:
```bash
# In migration script
kubectl drain $NODE
# ... wait for migration ...
kubectl uncordon $NODE  # Add this
```

---

### Issue: Pods Not Getting Overlay IPs

**Symptoms:**
```bash
kubectl get pods -o wide
# NAME       IP          NODE
# pod-1      10.1.x.x    node-1  # Still VPC IP, not overlay IP
```

**Root Cause:**
Pods created before Cilium installation still use VPC-CNI

**Solution:**
```bash
# Restart all deployments
kubectl rollout restart deployment --all

# Or specific deployment
kubectl rollout restart deployment <deployment-name>

# Wait for pods to be Ready
kubectl wait --for=condition=ready pod --all --timeout=300s

# Verify new IPs
kubectl get pods -o wide
# Should show 10.244.x.x IPs
```

**Verification:**
```bash
# Check IP ranges
kubectl get pods -o json | jq -r '.items[].status.podIP' | sort -u

# Should see:
# 10.244.0.x
# 10.244.1.x
# etc.
```

---

## Cilium Issues

### Issue: Cilium Pods CrashLooping

**Symptoms:**
```bash
kubectl get pods -n kube-system -l k8s-app=cilium
# NAME           READY   STATUS             RESTARTS
# cilium-xxx     0/1     CrashLoopBackOff   5
```

**Diagnosis:**
```bash
# Check logs
kubectl logs -n kube-system cilium-xxx

# Common errors:
# - "failed to list *v1.Node: Unauthorized"
# - "unable to load eBPF programs"
# - "failed to open BPF filesystem"
```

**Solution 1: RBAC Issues**
```bash
# Verify Cilium service account has correct permissions
kubectl get clusterrolebinding | grep cilium

# Reinstall Cilium with correct RBAC
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set serviceAccounts.cilium.create=true
```

**Solution 2: Kernel Compatibility**
```bash
# Check kernel version (needs 4.9.17+)
kubectl debug node/<node-name> -it --image=ubuntu -- uname -r

# Check BPF filesystem
kubectl debug node/<node-name> -it --image=ubuntu -- mount | grep bpf

# Should see: bpffs on /sys/fs/bpf
```

**Solution 3: Resource Limits**
```bash
# Increase Cilium resource limits
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set resources.limits.memory=2Gi \
  --set resources.limits.cpu=2
```

---

### Issue: Cilium Status Not OK

**Symptoms:**
```bash
kubectl exec -n kube-system cilium-xxx -- cilium-dbg status
# KVStore: Error
# Kubernetes: Error
# Cilium: Warning
```

**Diagnosis:**
```bash
# Detailed status
kubectl exec -n kube-system cilium-xxx -- cilium-dbg status --verbose

# Check connectivity
kubectl exec -n kube-system cilium-xxx -- cilium-dbg connectivity test
```

**Solution:**
```bash
# Restart Cilium pods
kubectl delete pod -n kube-system -l k8s-app=cilium

# Wait for restart
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium

# Verify status
kubectl exec -n kube-system cilium-xxx -- cilium-dbg status --brief
# Should show: OK
```

---

## Egress Gateway Issues

### Issue: Egress IP Not Changing

**Symptoms:**
```bash
kubectl exec curl-pod -- curl -s ifconfig.me
# Output: 52.202.231.151  # Still NAT Gateway IP, not Gateway node IP
```

**Diagnosis Checklist:**

**1. Verify Policy Exists:**
```bash
kubectl get ciliumegressgatewaypolicy
# Should list policies

kubectl describe ciliumegressgatewaypolicy <policy-name>
# Check pod selector, destination CIDR, node selector
```

**2. Verify Pod Labels Match:**
```bash
kubectl get pod <pod-name> --show-labels
# Labels must match policy's podSelector

# Example fix:
kubectl label pod <pod-name> app=frontend
```

**3. Verify Gateway Node Exists:**
```bash
kubectl get nodes -l node-role=gateway
# Should show at least one node

# If no nodes:
kubectl label node <node-name> node-role=gateway
```

**4. Verify Elastic IP Associated:**
```bash
# Get gateway node instance ID
GATEWAY_NODE=<gateway-node-name>
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=private-dns-name,Values=$GATEWAY_NODE" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text)

# Check Elastic IP
aws ec2 describe-addresses \
  --filters "Name=instance-id,Values=$INSTANCE_ID"

# Should show associated Elastic IP
```

**5. Verify Cilium BPF Routing:**
```bash
kubectl exec -n kube-system cilium-xxx -- cilium-dbg bpf egress list

# Should show:
# Source IP      Dest CIDR   Gateway IP
# 10.244.x.x     0.0.0.0/0   10.1.48.211
```

**Solution:**
```bash
# 1. Ensure policy applied
kubectl apply -f kubernetes/egress-gateway-policy.yaml

# 2. Restart pods to pick up policy
kubectl rollout restart deployment <deployment-name>

# 3. Wait for pods ready
kubectl wait --for=condition=ready pod -l app=<app-label>

# 4. Test again
kubectl exec <pod-name> -- curl -s ifconfig.me
# Should show gateway Elastic IP
```

---

### Issue: Gateway Node Not Ready

**Symptoms:**
```bash
kubectl get nodes -l node-role=gateway
# NAME               STATUS      ROLES
# gateway-node       NotReady    <none>
```

**Diagnosis:**
```bash
# Describe node
kubectl describe node <gateway-node-name>

# Common issues:
# - "NetworkNotReady"
# - "KubeletNotReady"
# - "DiskPressure"
```

**Solution 1: Network Issues**
```bash
# Check security groups allow VXLAN (port 8472)
aws ec2 describe-security-groups \
  --group-ids <security-group-id>

# Should allow:
# - Ingress TCP 8472 from worker nodes
# - Egress all

# Check Cilium status on node
kubectl exec -n kube-system cilium-xxx -- cilium-dbg status
```

**Solution 2: Kubelet Issues**
```bash
# Check kubelet logs
kubectl debug node/<node-name> -it --image=ubuntu -- \
  journalctl -u kubelet -n 100

# Restart kubelet (via node replacement)
# Gateway nodes should be part of ASG - terminate and replace
```

---

### Issue: Multiple Gateways Not Load Balancing

**Symptoms:**
All traffic goes through one gateway, others unused

**Diagnosis:**
```bash
# Check all gateway nodes
kubectl get nodes -l node-role=gateway

# Check egress routing distribution
kubectl exec -n kube-system cilium-xxx -- cilium-dbg bpf egress list

# All entries should not point to same gateway IP
```

**Solution:**
```bash
# Verify policy allows multiple gateways
kubectl describe ciliumegressgatewaypolicy <policy-name>

# Should see:
# egressGateway:
#   nodeSelector:
#     matchLabels:
#       node-role: gateway  # Matches ALL gateway nodes

# If restricted to single node, broaden selector
```

---

## Network Connectivity Issues

### Issue: Pod-to-Pod Communication Broken

**Symptoms:**
```bash
kubectl exec pod-a -- curl pod-b
# Connection timeout or refused
```

**Diagnosis:**
```bash
# Check both pods are Running
kubectl get pods

# Check pod IPs
kubectl get pods -o wide

# Test connectivity
kubectl exec pod-a -- ping <pod-b-ip>
```

**Solution 1: Cilium Network Policy**
```bash
# Check if network policy blocking traffic
kubectl get ciliumnetworkpolicy

# Temporarily disable to test
kubectl delete ciliumnetworkpolicy <policy-name>

# If connectivity restored, adjust policy
```

**Solution 2: VXLAN Issues**
```bash
# Check VXLAN connectivity
kubectl exec -n kube-system cilium-xxx -- cilium-dbg connectivity test

# Check security group allows VXLAN (port 8472)
# Between all nodes in cluster
```

---

### Issue: Service Connectivity Broken

**Symptoms:**
```bash
kubectl exec pod -- curl service-name
# Connection refused or timeout
```

**Diagnosis:**
```bash
# Verify service exists
kubectl get svc

# Check endpoints
kubectl get endpoints service-name

# Should show pod IPs
```

**Solution 1: kube-proxy Replacement**
```bash
# Check if kube-proxy replacement enabled
kubectl exec -n kube-system cilium-xxx -- cilium-dbg status | grep KubeProxyReplacement

# If issues, temporarily disable
helm upgrade cilium cilium/cilium \
  --set kubeProxyReplacement=false

# Or keep kube-proxy running alongside
```

**Solution 2: DNS Issues**
```bash
# Test DNS resolution
kubectl exec pod -- nslookup service-name

# Check CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Restart CoreDNS if needed
kubectl rollout restart deployment coredns -n kube-system
```

---

### Issue: External Connectivity Broken

**Symptoms:**
```bash
kubectl exec pod -- curl google.com
# Connection timeout
```

**Diagnosis:**
```bash
# Check if pod has IP
kubectl get pod <pod-name> -o wide

# Check if gateway node reachable
kubectl exec pod -- ping <gateway-node-ip>

# Check DNS
kubectl exec pod -- nslookup google.com
```

**Solution 1: NAT/Masquerade**
```bash
# Verify bpf.masquerade enabled
kubectl exec -n kube-system cilium-xxx -- cilium-dbg status | grep Masquerading

# Should show: BPF (ip-masq-agent)

# If not, enable:
helm upgrade cilium cilium/cilium \
  --set bpf.masquerade=true
```

**Solution 2: Security Group**
```bash
# Verify security group allows egress
aws ec2 describe-security-groups --group-ids <sg-id>

# Should allow:
# Egress: 0.0.0.0/0 on all ports
```

---

## Performance Issues

### Issue: High Latency After Migration

**Symptoms:**
Pod-to-pod latency increased significantly

**Diagnosis:**
```bash
# Measure latency
kubectl exec pod-a -- ping -c 100 <pod-b-ip>

# Compare to VPC-CNI baseline
# Acceptable increase: < 20%
```

**Solution 1: MTU Configuration**
```bash
# VXLAN adds ~50 bytes overhead
# Default MTU: 1500, VXLAN MTU should be: 1450

helm upgrade cilium cilium/cilium \
  --set mtu=1450
```

**Solution 2: Disable Encryption**
```bash
# WireGuard encryption adds overhead
# Disable if not required

helm upgrade cilium cilium/cilium \
  --set encryption.enabled=false
```

---

### Issue: Low Throughput

**Symptoms:**
Network throughput lower than expected

**Diagnosis:**
```bash
# Run iperf3 test
kubectl run iperf-server --image=networkstatic/iperf3 -- -s
kubectl run iperf-client --image=networkstatic/iperf3 -- -c <server-ip> -t 30

kubectl logs iperf-client
```

**Solution:**
```bash
# Enable BBR congestion control
helm upgrade cilium cilium/cilium \
  --set bpf.tcpSyn=true

# Use larger instance types for gateway nodes
# c5.xlarge or c5.2xlarge for high-throughput scenarios
```

---

## Diagnostic Commands

### Cluster-Level Diagnostics

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods --all-namespaces -o wide

# Cilium status
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg status
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg connectivity test
```

### Node-Level Diagnostics

```bash
# Node debugging
kubectl debug node/<node-name> -it --image=ubuntu

# Inside debug container:
uname -r                    # Kernel version
mount | grep bpf            # BPF filesystem
ip link show                # Network interfaces
ip route show               # Routing table
iptables -L -n -v           # iptables rules (if not using eBPF)
```

### Pod-Level Diagnostics

```bash
# Pod debugging
kubectl run debug --rm -it --image=nicolaka/netshoot -- bash

# Inside debug pod:
curl <service-name>         # Service connectivity
ping <pod-ip>               # Pod connectivity
nslookup <service-name>     # DNS resolution
traceroute <external-ip>    # Route tracing
curl ifconfig.me            # Egress IP check
```

### Cilium-Specific Diagnostics

```bash
# Cilium connectivity test
cilium connectivity test

# BPF maps
cilium-dbg bpf lb list
cilium-dbg bpf endpoint list
cilium-dbg bpf egress list
cilium-dbg bpf nat list

# Policy debugging
cilium-dbg policy get
cilium-dbg endpoint list

# Flow logs (if Hubble enabled)
hubble observe
hubble observe --from-pod <pod-name>
hubble observe --to-ip 0.0.0.0/0
```

### Gateway-Specific Diagnostics

```bash
# Gateway node status
kubectl get nodes -l node-role=gateway
kubectl describe node <gateway-node>

# Elastic IP check
aws ec2 describe-addresses \
  --filters "Name=instance-id,Values=<instance-id>"

# Egress policy status
kubectl get ciliumegressgatewaypolicy
kubectl describe ciliumegressgatewaypolicy <policy-name>

# Egress routing table
kubectl exec -n kube-system <cilium-pod> -- cilium-dbg bpf egress list
```

---

## Getting Help

### Log Collection

```bash
# Collect logs for support
kubectl logs -n kube-system -l k8s-app=cilium --tail=1000 > cilium-logs.txt
kubectl logs -n kube-system -l k8s-app=cilium --previous > cilium-logs-previous.txt
kubectl get events --all-namespaces > events.txt
kubectl get pods --all-namespaces -o wide > pods.txt
```

### Support Channels

- **GitHub Issues**: [Cilium Issues](https://github.com/cilium/cilium/issues)
- **Slack**: [Cilium Slack](https://slack.cilium.io/)
- **Discussions**: [GitHub Discussions](https://github.com/cilium/cilium/discussions)

### Useful Links

- [Cilium Troubleshooting Guide](https://docs.cilium.io/en/stable/operations/troubleshooting/)
- [Cilium FAQ](https://docs.cilium.io/en/stable/operations/faq/)
- [AWS EKS Troubleshooting](https://docs.aws.amazon.com/eks/latest/userguide/troubleshooting.html)
