# Kubernetes Single-Node Production Setup

A production-shaped Kubernetes cluster using **kubeadm** on a single VM, with all the components you'd use in a real multi-node deployment.

## 📋 Overview

This repository contains scripts and documentation for deploying a **real kubeadm-based Kubernetes cluster** (not k3s/minikube) with:

- **Kubernetes v1.35** via kubeadm
- **containerd** runtime
- **Calico** CNI (with NetworkPolicy support)
- **MetalLB** LoadBalancer
- **NGINX Ingress Controller** (hardened)
- **Secure remote access** via SSH tunnel

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     k8s-single (VM)                         │
├─────────────────────────────────────────────────────────────┤
│  Control Plane                                              │
│  ├── kube-apiserver (private: 10.0.129.132:6443)           │
│  ├── kube-controller-manager                                │
│  ├── kube-scheduler                                         │
│  └── etcd (embedded)                                        │
├─────────────────────────────────────────────────────────────┤
│  Networking                                                 │
│  ├── Calico CNI (pod network: 192.168.0.0/16)              │
│  ├── MetalLB (LoadBalancer IPs: 10.0.0.200-210)            │
│  └── ingress-nginx (L7 routing)                            │
├─────────────────────────────────────────────────────────────┤
│  Runtime                                                    │
│  ├── containerd (systemd cgroups)                          │
│  └── kubelet                                                │
└─────────────────────────────────────────────────────────────┘
           │
           │ SSH Tunnel (port 6443)
           ▼
┌─────────────────────────────────────────────────────────────┐
│              Local Machine (kubectl)                        │
│  └── kubectl → localhost:6443 → SSH → 10.0.129.132:6443    │
└─────────────────────────────────────────────────────────────┘
```

## 📁 Repository Structure

```
k8s/
├── README.md                    # This file
├── scripts/
│   ├── install-kubeadm.sh       # Full cluster installation
│   └── start-k8s-tunnel.sh      # SSH tunnel for kubectl access
└── docs/
    ├── ARCHITECTURE.md          # Detailed architecture
    ├── SECURITY.md              # Security model
    ├── OPERATIONS.md            # Day-2 operations guide
    ├── TROUBLESHOOTING.md       # Common issues & fixes
    └── UPGRADE.md               # Upgrade procedures
```

## 🚀 Quick Start

### Prerequisites

| Requirement | Specification |
|-------------|---------------|
| OS | Ubuntu 22.04 LTS |
| CPU | 2+ vCPU |
| RAM | 4+ GB |
| Network | Static IP |
| Access | SSH key-based |

### 1. Deploy Cluster (on VM)

```bash
# SSH into your VM
ssh ubuntu@<VM_PUBLIC_IP>

# Clone or copy the scripts
git clone <repo> && cd k8s

# Run the installation
chmod +x scripts/install-kubeadm.sh
./scripts/install-kubeadm.sh
```

### 2. Configure Local Access (on your machine)

```bash
# Copy kubeconfig
ssh ubuntu@<VM_PUBLIC_IP> "sudo cat /etc/kubernetes/admin.conf" > ~/kubeadm.conf

# Edit server address to localhost
sed -i 's|server:.*|server: https://127.0.0.1:6443|' ~/kubeadm.conf

# Start SSH tunnel
bash scripts/start-k8s-tunnel.sh

# Test connection (with TLS server name for cert validation)
kubectl --kubeconfig=~/kubeadm.conf --tls-server-name=10.0.129.132 get nodes
```

### 3. Make it Permanent

```bash
# Copy to default location
mkdir -p ~/.kube
cp ~/kubeadm.conf ~/.kube/config

# Set TLS server name permanently
kubectl config set-cluster kubernetes \
  --server=https://127.0.0.1:6443 \
  --tls-server-name=10.0.129.132

# Now just use kubectl normally
kubectl get nodes
```

## ✅ Verification

```bash
# Cluster nodes
kubectl get nodes
# Expected: k8s-single Ready

# All pods running
kubectl get pods -A
# Expected: All pods in Running state

# Ingress working
curl http://hello.local  # (after adding /etc/hosts entry)
# Expected: "hello from kubeadm"
```

## 🔒 Security Highlights

- **Private API Server**: Not exposed publicly (6443 not in security group)
- **SSH Tunnel Access**: Secure, auditable, revocable
- **TLS Verification**: Proper certificate validation (no `--insecure-skip-tls-verify`)
- **Hardened Ingress**: ModSecurity + OWASP CRS enabled
- **NetworkPolicies**: Calico CNI supports policy enforcement

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Detailed component architecture |
| [SECURITY.md](docs/SECURITY.md) | Security model & hardening |
| [OPERATIONS.md](docs/OPERATIONS.md) | Day-2 operations guide |
| [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Common issues & solutions |
| [UPGRADE.md](docs/UPGRADE.md) | Version upgrade procedures |

## 🔄 Upgrade Path

This single-node setup is designed to evolve:

1. **Current**: Single VM (testing/staging)
2. **Next**: 3-node HA (production minimum)
3. **Future**: N workers + external LB + GitOps

All manifests and configurations will carry forward without rewriting.

## ⚠️ Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| Single control plane | No HA | Expand to 3 nodes for production |
| MetalLB L2 mode | AWS incompatible | Replace with NLB for AWS |
| Self-signed TLS | Browser warnings | Add cert-manager + Let's Encrypt |

## 📞 Support

For issues with this setup:
1. Check [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
2. Review cluster logs: `kubectl logs -n kube-system <pod>`
3. Verify tunnel: `ss -lntp | grep 6443`

---

**Version**: 1.0.0  
**Kubernetes**: v1.35  
**Last Updated**: January 2026
