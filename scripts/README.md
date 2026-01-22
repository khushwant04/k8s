# Scripts Documentation

## Overview

This directory contains automation scripts for deploying and managing the Kubernetes cluster.

## Scripts

### install-kubeadm.sh

**Purpose:** Full cluster installation on a single VM

**Usage:**
```bash
# On the VM
chmod +x install-kubeadm.sh
./install-kubeadm.sh
```

**What it does:**
1. Configures OS (hostname, swap, kernel modules, sysctl)
2. Installs containerd with systemd cgroups
3. Installs kubeadm, kubelet, kubectl
4. Initializes the cluster with `kubeadm init`
5. Configures kubectl access
6. Installs Calico CNI
7. Removes control-plane taint (single-node only)
8. Installs MetalLB for LoadBalancer support
9. Installs and hardens NGINX Ingress
10. Deploys a test application

**Configuration Variables:**
```bash
K8S_VERSION="v1.35"           # Kubernetes version
HOSTNAME="k8s-single"          # Node hostname
POD_CIDR="192.168.0.0/16"      # Pod network CIDR
METALLB_POOL="10.0.0.200-10.0.0.210"  # LoadBalancer IPs
```

**Duration:** ~5-10 minutes

---

### start-k8s-tunnel.sh

**Purpose:** Create SSH tunnel for secure kubectl access

**Usage:**
```bash
# On your local machine
bash start-k8s-tunnel.sh
```

**What it does:**
1. Opens SSH connection to the VM
2. Forwards local port 6443 to API server
3. Runs in background

**Configuration Variables:**
```bash
KEY_PATH="$HOME/ssh-keys/hx.pem"     # SSH private key
REMOTE_USER="ubuntu"                  # VM user
REMOTE_HOST="13.201.92.125"           # VM public IP
K8S_API_PRIVATE_IP="10.0.129.132"     # API server private IP
```

**After running:**
```bash
kubectl --kubeconfig=~/kubeadm.conf --tls-server-name=10.0.129.132 get nodes
```

**Stop tunnel:**
```bash
pkill -f "ssh.*6443"
```

---

## Quick Reference

### First-time Setup Flow

```bash
# 1. On VM - Install cluster
ssh ubuntu@<VM_PUBLIC_IP>
./scripts/install-kubeadm.sh

# 2. On local machine - Get kubeconfig
ssh ubuntu@<VM_PUBLIC_IP> "sudo cat /etc/kubernetes/admin.conf" > ~/kubeadm.conf

# 3. Edit kubeconfig server address
sed -i 's|server:.*|server: https://127.0.0.1:6443|' ~/kubeadm.conf

# 4. Start tunnel
bash scripts/start-k8s-tunnel.sh

# 5. Test
kubectl --kubeconfig=~/kubeadm.conf --tls-server-name=10.0.129.132 get nodes
```

### Daily Usage

```bash
# Start tunnel (if not running)
bash scripts/start-k8s-tunnel.sh

# Use kubectl
kubectl get pods -A

# Stop tunnel when done
pkill -f "ssh.*6443"
```

### Troubleshooting

| Issue | Solution |
|-------|----------|
| Tunnel won't start | Kill existing: `pkill -f "ssh.*6443"` |
| kubectl hangs | Check tunnel: `ss -lntp \| grep 6443` |
| TLS error | Add `--tls-server-name=10.0.129.132` |
| Permission denied | Check SSH key path in script |
