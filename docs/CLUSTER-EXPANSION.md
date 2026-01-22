# Cluster Expansion Guide

## Converting Single-Node to 3-Node HA Control Plane

This guide covers expanding your existing single-node kubeadm cluster to a production-grade HA setup with 3 control planes and 2 workers.

## Architecture Overview

### Current State (Single Node)
```
┌─────────────────────────────────────┐
│          k8s-single                 │
│  • kube-apiserver (:6443)           │
│  • etcd (single instance)           │
│  • controller-manager               │
│  • scheduler                        │
│  • workloads                        │
└─────────────────────────────────────┘
```

### Target State (5 Nodes)
```
                ┌──────────────────────┐
                │   Load Balancer      │
                │   k8s-api:6443       │
                └──────────┬───────────┘
                           │
       ┌───────────────────┼───────────────────┐
       │                   │                   │
       ▼                   ▼                   ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│    cp-1     │    │    cp-2     │    │    cp-3     │
│ (existing)  │◄──►│   (new)     │◄──►│   (new)     │
│   etcd      │    │   etcd      │    │   etcd      │
│ api-server  │    │ api-server  │    │ api-server  │
└─────────────┘    └─────────────┘    └─────────────┘
                           │
       ┌───────────────────┴───────────────────┐
       │                                       │
       ▼                                       ▼
┌─────────────┐                        ┌─────────────┐
│  worker-1   │                        │  worker-2   │
│  workloads  │                        │  workloads  │
└─────────────┘                        └─────────────┘
```

## Prerequisites

### Infrastructure Requirements

| Node | Role | Minimum Specs |
|------|------|---------------|
| cp-1 | Control Plane (existing) | 2 vCPU, 4GB RAM |
| cp-2 | Control Plane (new) | 2 vCPU, 4GB RAM |
| cp-3 | Control Plane (new) | 2 vCPU, 4GB RAM |
| worker-1 | Worker (new) | 2 vCPU, 4GB RAM |
| worker-2 | Worker (new) | 2 vCPU, 4GB RAM |
| lb-1 | Load Balancer | 1 vCPU, 1GB RAM |

### Network Requirements

All nodes must allow:

| Port | Protocol | Purpose | Source |
|------|----------|---------|--------|
| 6443 | TCP | Kubernetes API | All nodes, LB |
| 2379-2380 | TCP | etcd | Control planes only |
| 10250 | TCP | Kubelet API | Control planes |
| 10259 | TCP | kube-scheduler | localhost |
| 10257 | TCP | kube-controller-manager | localhost |
| 179 | TCP | Calico BGP | All nodes |
| 4789 | UDP | Calico VXLAN | All nodes |

### Example IP Allocation

```
Load Balancer:  10.0.0.100    (VIP / DNS: k8s-api.example.com)
cp-1:           10.0.0.10     (existing)
cp-2:           10.0.0.11     (new)
cp-3:           10.0.0.12     (new)
worker-1:       10.0.0.20     (new)
worker-2:       10.0.0.21     (new)
```

---

## Phase 1: Set Up Load Balancer

### Why This Is Required

kubeadm HA requires a **stable control-plane endpoint** that:
- Stays the same when nodes are added/removed
- Routes to healthy API servers
- Never changes (DNS name or VIP)

### Option A: HAProxy (Recommended for VMs)

#### Install HAProxy

```bash
# On dedicated LB VM or any external host
sudo apt update
sudo apt install -y haproxy
```

#### Configure HAProxy

```bash
sudo nano /etc/haproxy/haproxy.cfg
```

Add this configuration:

```haproxy
#---------------------------------------------------------------------
# Kubernetes API Server Load Balancer
#---------------------------------------------------------------------

frontend kubernetes-api
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-api-backend

backend kubernetes-api-backend
    mode tcp
    option tcp-check
    balance roundrobin
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
    
    # Control plane nodes (update IPs as you add nodes)
    server cp-1 10.0.0.10:6443 check
    server cp-2 10.0.0.11:6443 check
    server cp-3 10.0.0.12:6443 check
```

#### Start HAProxy

```bash
sudo systemctl restart haproxy
sudo systemctl enable haproxy

# Verify
sudo systemctl status haproxy
nc -zv 10.0.0.100 6443
```

### Option B: AWS Network Load Balancer

```bash
# Create NLB via AWS CLI or Console
# Target Group: TCP 6443
# Targets: cp-1, cp-2, cp-3 (port 6443)
# Health Check: TCP 6443
```

### Set Up DNS (Recommended)

```bash
# Add DNS record
k8s-api.example.com -> 10.0.0.100 (LB IP)
```

Or add to `/etc/hosts` on all nodes:
```
10.0.0.100 k8s-api.example.com
```

---

## Phase 2: Update Existing Cluster

### Step 2.1: Update kubeadm-config

On **cp-1** (existing node):

```bash
# Edit kubeadm-config ConfigMap
kubectl -n kube-system edit cm kubeadm-config
```

Find `ClusterConfiguration` and add/update:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
controlPlaneEndpoint: "k8s-api.example.com:6443"  # ADD THIS LINE
# ... rest of config
```

Save and exit.

### Step 2.2: Update API Server Certificates (If Needed)

If the LB IP/DNS is new, regenerate API server certs:

```bash
# Backup existing certs
sudo cp -r /etc/kubernetes/pki /etc/kubernetes/pki.backup

# Check current SANs
openssl x509 -in /etc/kubernetes/pki/apiserver.crt -text -noout | grep -A1 "Alternative Name"

# If LB DNS not in SANs, regenerate:
sudo rm /etc/kubernetes/pki/apiserver.crt
sudo rm /etc/kubernetes/pki/apiserver.key

sudo kubeadm init phase certs apiserver \
  --apiserver-cert-extra-sans=k8s-api.example.com,10.0.0.100

# Restart API server
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sleep 10
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

### Step 2.3: Upload Certificates for New Control Planes

```bash
# Upload certs and get certificate key
sudo kubeadm init phase upload-certs --upload-certs

# OUTPUT (save this!):
# [upload-certs] Using certificate key: abc123...
```

**⚠️ Save the certificate key! It expires in 2 hours.**

### Step 2.4: Generate Join Token

```bash
# Create new join command for control planes
kubeadm token create --print-join-command

# OUTPUT (save this!):
# kubeadm join k8s-api.example.com:6443 --token xxxx --discovery-token-ca-cert-hash sha256:yyyy
```

---

## Phase 3: Prepare New Nodes

Run these steps on **cp-2, cp-3, worker-1, worker-2**:

### Step 3.1: OS Preparation

```bash
# Set hostname (adjust per node)
sudo hostnamectl set-hostname cp-2  # or cp-3, worker-1, worker-2

# Disable swap
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Kernel modules
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sudo sysctl --system
```

### Step 3.2: Install containerd

```bash
sudo apt update
sudo apt install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd
```

### Step 3.3: Install Kubernetes Binaries

```bash
K8S_VERSION="v1.35"

sudo apt install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
sudo apt install -y kubeadm kubelet kubectl
sudo apt-mark hold kubeadm kubelet kubectl
sudo systemctl enable --now kubelet
```

### Step 3.4: Add /etc/hosts Entry

```bash
# Add on ALL new nodes
echo "10.0.0.100 k8s-api.example.com" | sudo tee -a /etc/hosts
```

---

## Phase 4: Join Control Plane Nodes

### On cp-2 and cp-3:

```bash
sudo kubeadm join k8s-api.example.com:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <certificate-key>
```

### Set Up kubectl on New Control Planes

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

### Verify etcd Cluster

```bash
# Check etcd members
sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Should show 3 members
```

---

## Phase 5: Join Worker Nodes

### On worker-1 and worker-2:

```bash
sudo kubeadm join k8s-api.example.com:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

Note: Workers do NOT use `--control-plane` or `--certificate-key`.

---

## Phase 6: Verify Cluster

```bash
# Check all nodes
kubectl get nodes -o wide

# Expected output:
# NAME       STATUS   ROLES           AGE   VERSION
# cp-1       Ready    control-plane   1d    v1.35.0
# cp-2       Ready    control-plane   10m   v1.35.0
# cp-3       Ready    control-plane   5m    v1.35.0
# worker-1   Ready    <none>          2m    v1.35.0
# worker-2   Ready    <none>          1m    v1.35.0

# Label workers (optional but recommended)
kubectl label node worker-1 node-role.kubernetes.io/worker=worker
kubectl label node worker-2 node-role.kubernetes.io/worker=worker

# Verify all pods running
kubectl get pods -A

# Test HA: kill API server on cp-1
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
kubectl get nodes  # Should still work (via cp-2 or cp-3)
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

---

## Phase 7: Update Local kubectl Access

### Update SSH Tunnel Script

```bash
# Update start-k8s-tunnel.sh
REMOTE_HOST="<LB_PUBLIC_IP>"  # Now point to LB
K8S_API_PRIVATE_IP="10.0.0.100"  # LB internal IP
```

### Update kubeconfig

```bash
# Get new kubeconfig
ssh ubuntu@<LB_IP_OR_CP1> "sudo cat /etc/kubernetes/admin.conf" > ~/kubeadm-ha.conf

# Update server address
sed -i 's|server:.*|server: https://127.0.0.1:6443|' ~/kubeadm-ha.conf

# Use with TLS server name
kubectl --kubeconfig=~/kubeadm-ha.conf --tls-server-name=k8s-api.example.com get nodes
```

---

## Troubleshooting

### Token Expired

```bash
# On cp-1, create new token
kubeadm token create --print-join-command
```

### Certificate Key Expired

```bash
# On cp-1, re-upload certs
sudo kubeadm init phase upload-certs --upload-certs
```

### etcd Not Forming Quorum

```bash
# Check etcd logs
sudo journalctl -u etcd -f

# Or static pod logs
kubectl logs -n kube-system etcd-cp-1
```

### Node Stuck Joining

```bash
# On stuck node
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
# Re-run join command
```

---

## Post-Expansion Checklist

- [ ] All 5 nodes showing Ready
- [ ] etcd has 3 members
- [ ] Can kubectl via any control plane
- [ ] LoadBalancer health checks passing
- [ ] Calico pods running on all nodes
- [ ] Ingress working
- [ ] Test workload deploys correctly
- [ ] Verify HA by stopping one control plane
