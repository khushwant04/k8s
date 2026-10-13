#!/usr/bin/env bash
#===============================================================================
# Kubernetes Single-Node Production Setup Script (ARM64 / aarch64)
#===============================================================================
#
# Description:
#   Deploys a production-shaped Kubernetes cluster on a single ARM64 VM using
#   kubeadm. Includes containerd, Calico CNI, MetalLB, and NGINX Ingress.
#
# Supported Platforms:
#   - AWS Graviton (c6g, c7g, t4g, m6g, r6g)
#   - Ampere Altra
#   - Oracle ARM (A1 instances)
#   - Raspberry Pi 4/5 (Ubuntu Server 22.04+)
#   - Any linux/arm64 VM
#
# Usage:
#   chmod +x install-kubeadm-arm64.sh
#   ./install-kubeadm-arm64.sh
#
# Requirements:
#   - Ubuntu 22.04 LTS (ARM64)
#   - 2+ vCPU, 4+ GB RAM
#   - Root/sudo access
#   - Internet connectivity
#
# Components Installed:
#   - Kubernetes v1.35 (kubeadm, kubelet, kubectl)
#   - containerd runtime (ARM64)
#   - Calico CNI v3.32.2 (multi-arch)
#   - MetalLB v0.15.3 (multi-arch)
#   - ingress-nginx controller v1.15.1 (multi-arch)
#
# ARM-Specific Notes:
#   - All images used are multi-arch (linux/arm64 + linux/amd64)
#   - Same kubeadm/kubelet binaries (ARM-native packages)
#   - No emulation or QEMU required
#
# Author: Platform Team
# Version: 1.0.0
# Last Updated: January 2026
#===============================================================================

set -euo pipefail

### =========================
### CONFIGURATION
### =========================
# Modify these variables as needed for your environment

K8S_VERSION="v1.35"                    # Kubernetes version
HOSTNAME="k8s-arm"                     # Node hostname
POD_CIDR="192.168.0.0/16"              # Pod network CIDR (Calico default)
METALLB_POOL="10.0.0.200-10.0.0.210"   # LoadBalancer IP range

# Add-on versions (pinned for reproducible installs)
CALICO_VERSION="v3.32.2"              # tested by Calico against Kubernetes 1.34-1.36
METALLB_VERSION="v0.15.3"
INGRESS_NGINX_VERSION="v1.15.1"        # final ingress-nginx release (project retired March 2026)
HTTP_ECHO_IMAGE="hashicorp/http-echo:1.0.0"  # multi-arch; 0.2.x tags are amd64-only

### =========================
echo "[1/12] Architecture check"
### =========================
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    echo "============================================================"
    echo "❌ ERROR: This script is for ARM64 (aarch64) only!"
    echo "============================================================"
    echo ""
    echo "   Detected architecture: $ARCH"
    echo ""
    echo "   For x86_64 systems, use: install-kubeadm.sh"
    echo ""
    echo "============================================================"
    exit 1
fi

echo "✅ Architecture verified: ARM64 (aarch64)"
echo ""

### =========================
echo "[2/12] OS preparation"
### =========================
sudo hostnamectl set-hostname "${HOSTNAME}"

sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sudo sysctl --system

### =========================
echo "[3/12] Install containerd (ARM64)"
### =========================
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# CRITICAL: SystemdCgroup must be true for kubelet on ARM
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
    /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

# Verify containerd is running
if ! systemctl is-active --quiet containerd; then
    echo "❌ containerd failed to start"
    exit 1
fi
echo "✅ containerd running (ARM64)"

### =========================
echo "[4/12] Install Kubernetes binaries (ARM64)"
### =========================
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p /etc/apt/keyrings

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" \
    | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubeadm kubelet kubectl
sudo apt-mark hold kubeadm kubelet kubectl
sudo systemctl enable --now kubelet

# Verify Kubernetes binaries
echo "Kubernetes versions installed:"
kubeadm version
kubelet --version
kubectl version --client

### =========================
echo "[5/12] kubeadm init"
### =========================
sudo kubeadm init \
    --pod-network-cidr="${POD_CIDR}" \
    --cri-socket=unix:///run/containerd/containerd.sock

### =========================
echo "[6/12] kubectl access"
### =========================
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

### =========================
echo "[7/12] Install Calico CNI (multi-arch)"
### =========================
# Calico publishes multi-arch images (linux/amd64 + linux/arm64)
kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"

echo "Waiting for Calico to be ready..."
# rollout status waits for the DaemonSet pods to exist; "kubectl wait" fails if they are not created yet
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s

### =========================
echo "[8/12] Allow workloads on control-plane (single-node only)"
### =========================
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

### =========================
echo "[9/12] Install MetalLB (multi-arch)"
### =========================
# MetalLB publishes multi-arch images
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

# The IPAddressPool is validated by the MetalLB webhook, so wait for the controller first
kubectl -n metallb-system rollout status deployment/controller --timeout=180s

apply_metallb_config() {
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_POOL}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: metallb-system
EOF
}

# Retry a few times: the webhook endpoint can lag the controller becoming Ready
for attempt in 1 2 3 4 5 6; do
  if apply_metallb_config; then break; fi
  if [[ "${attempt}" -eq 6 ]]; then echo "MetalLB config failed" >&2; exit 1; fi
  echo "MetalLB webhook not ready yet, retrying in 10s..."
  sleep 10
done

### =========================
echo "[10/12] Install ingress-nginx (multi-arch)"
### =========================
# NGINX Ingress publishes multi-arch images
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${INGRESS_NGINX_VERSION}/deploy/static/provider/cloud/deploy.yaml"

echo "Waiting for ingress controller to be ready..."
kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s

### =========================
echo "[11/12] Harden ingress"
### =========================
# Note: ingress-nginx was retired upstream in March 2026 (no further releases or
# security fixes). For new clusters prefer a Gateway API implementation.
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  server-tokens: "false"
  ssl-protocols: "TLSv1.2 TLSv1.3"
  enable-modsecurity: "true"
  enable-owasp-modsecurity-crs: "true"
EOF

### =========================
echo "[12/12] Deploy ARM-safe test workload"
### =========================
# hashicorp/http-echo >= 1.0.0 publishes linux/arm64 images
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hello
spec:
  replicas: 2
  selector:
    matchLabels:
      app: hello
  template:
    metadata:
      labels:
        app: hello
    spec:
      containers:
      - name: hello
        image: ${HTTP_ECHO_IMAGE}
        args: ["-text=hello from ARM64 kubeadm"]
        ports:
        - containerPort: 5678
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: hello
spec:
  selector:
    app: hello
  ports:
  - port: 80
    targetPort: 5678
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: hello
spec:
  ingressClassName: nginx
  rules:
  - host: hello.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: hello
            port:
              number: 80
EOF

### =========================
### COMPLETION
### =========================
NODE_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "============================================================"
echo "✅ ARM64 Kubernetes single-node cluster ready!"
echo "============================================================"
echo ""
echo "📋 Cluster Summary:"
echo "   • Architecture: ARM64 (aarch64)"
echo "   • Kubernetes: ${K8S_VERSION}"
echo "   • Node: ${HOSTNAME}"
echo "   • Node IP: ${NODE_IP}"
echo "   • Pod CIDR: ${POD_CIDR}"
echo "   • LoadBalancer IPs: ${METALLB_POOL}"
echo ""
echo "📡 Components Installed (all ARM64-native):"
echo "   • containerd (runtime)"
echo "   • Calico (CNI)"
echo "   • MetalLB (LoadBalancer)"
echo "   • NGINX Ingress (L7 routing)"
echo ""
echo "🔍 Verify ARM64:"
echo "   kubectl describe node | grep Architecture"
echo "   # Should show: Architecture: arm64"
echo ""
echo "🔧 Next Steps:"
echo "   1. Copy kubeconfig to local machine:"
echo "      ssh ubuntu@<VM_IP> 'sudo cat /etc/kubernetes/admin.conf' > ~/kubeadm.conf"
echo ""
echo "   2. Edit server address:"
echo "      sed -i 's|server:.*|server: https://127.0.0.1:6443|' ~/kubeadm.conf"
echo ""
echo "   3. Start SSH tunnel (local machine):"
echo "      bash scripts/start-k8s-tunnel.sh"
echo ""
echo "   4. Test kubectl (local machine):"
echo "      kubectl --kubeconfig ~/kubeadm.conf --tls-server-name=${NODE_IP} get nodes"
echo ""
echo "⚠️  ARM64 Image Reminder:"
echo "   Always verify images support linux/arm64 before deploying:"
echo "   docker manifest inspect IMAGE | grep arm64"
echo ""
echo "📚 Documentation: See README.md and docs/"
echo "============================================================"
