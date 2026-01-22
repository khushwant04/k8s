#!/usr/bin/env bash
#===============================================================================
# Kubernetes Single-Node Production Setup Script
#===============================================================================
#
# Description:
#   Deploys a production-shaped Kubernetes cluster on a single VM using kubeadm.
#   Includes containerd, Calico CNI, MetalLB, and NGINX Ingress.
#
# Usage:
#   chmod +x install-kubeadm.sh
#   ./install-kubeadm.sh
#
# Requirements:
#   - Ubuntu 22.04 LTS
#   - 2+ vCPU, 4+ GB RAM
#   - Root/sudo access
#   - Internet connectivity
#
# Components Installed:
#   - Kubernetes v1.35 (kubeadm, kubelet, kubectl)
#   - containerd runtime
#   - Calico CNI v3.27.0
#   - MetalLB v0.14.5
#   - NGINX Ingress Controller
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

K8S_VERSION="v1.35"           # Kubernetes version
HOSTNAME="k8s-single"          # Node hostname
POD_CIDR="192.168.0.0/16"      # Pod network CIDR (Calico default)
METALLB_POOL="10.0.0.200-10.0.0.210"  # LoadBalancer IP range

### =========================
echo "[1/11] OS preparation"
### =========================
sudo hostnamectl set-hostname "${HOSTNAME}"

sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF

sudo sysctl --system

### =========================
echo "[2/11] Install containerd"
### =========================
sudo apt update
sudo apt install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

### =========================
echo "[3/11] Install Kubernetes binaries"
### =========================
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

### =========================
echo "[4/11] kubeadm init"
### =========================
sudo kubeadm init \
  --pod-network-cidr="${POD_CIDR}" \
  --cri-socket=unix:///run/containerd/containerd.sock

### =========================
echo "[5/11] kubectl access"
### =========================
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

### =========================
echo "[6/11] Install Calico CNI"
### =========================
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=180s

### =========================
echo "[7/11] Allow scheduling on control plane (single-node only)"
### =========================
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

### =========================
echo "[8/11] Install MetalLB"
### =========================
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml
sleep 40

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

### =========================
echo "[9/11] Install ingress-nginx"
### =========================
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
kubectl wait -n ingress-nginx --for=condition=Ready pod \
  -l app.kubernetes.io/component=controller --timeout=180s

### =========================
echo "[10/11] Harden ingress"
### =========================
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
echo "[11/11] Deploy test app"
### =========================
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
        image: hashicorp/http-echo
        args: ["-text=hello from kubeadm"]
        ports:
        - containerPort: 5678
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

echo ""
echo "============================================================"
echo "✅ Kubernetes single-node production-shaped cluster ready!"
echo "============================================================"
echo ""
echo "📋 Cluster Summary:"
echo "   • Kubernetes: ${K8S_VERSION}"
echo "   • Node: ${HOSTNAME}"
echo "   • Pod CIDR: ${POD_CIDR}"
echo "   • LoadBalancer IPs: ${METALLB_POOL}"
echo ""
echo "📡 Components Installed:"
echo "   • containerd (runtime)"
echo "   • Calico (CNI)"
echo "   • MetalLB (LoadBalancer)"
echo "   • NGINX Ingress (L7 routing)"
echo ""
echo "🔧 Next Steps:"
echo "   1. Copy kubeconfig to local machine:"
echo "      ssh ubuntu@<VM_IP> 'sudo cat /etc/kubernetes/admin.conf' > ~/kubeadm.conf"
echo ""
echo "   2. Edit server address:"
echo "      sed -i 's|server:.*|server: https://127.0.0.1:6443|' ~/kubeadm.conf"
echo ""
echo "   3. Start SSH tunnel (local machine):"
echo "      bash start-k8s-tunnel.sh"
echo ""
echo "   4. Test kubectl (local machine):"
echo "      kubectl --kubeconfig=~/kubeadm.conf --tls-server-name=$(hostname -I | awk '{print $1}') get nodes"
echo ""
echo "📚 Documentation: See docs/README.md"
echo "============================================================"
