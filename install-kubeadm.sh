#!/usr/bin/env bash
set -e

echo "=== Kubernetes single-node (prod-shaped) setup ==="

### VARIABLES (EDIT IF NEEDED)
K8S_VERSION="v1.35"
POD_CIDR="192.168.0.0/16"
METALLB_POOL="10.0.0.200-10.0.0.210"
HOSTNAME="k8s-single"

########################################
# 1. OS PREP
########################################
echo "[1/10] OS preparation"

sudo hostnamectl set-hostname ${HOSTNAME}

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

########################################
# 2. CONTAINERD
########################################
echo "[2/10] Installing containerd"

sudo apt update
sudo apt install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

########################################
# 3. KUBERNETES PACKAGES
########################################
echo "[3/10] Installing kubeadm/kubelet/kubectl"

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

########################################
# 4. KUBEADM INIT
########################################
echo "[4/10] Initializing cluster"

sudo kubeadm init \
  --pod-network-cidr=${POD_CIDR} \
  --cri-socket=unix:///run/containerd/containerd.sock

########################################
# 5. KUBECONFIG
########################################
echo "[5/10] Configuring kubectl"

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

########################################
# 6. CALICO
########################################
echo "[6/10] Installing Calico CNI"

kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

echo "Waiting for Calico to be ready..."
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node -n kube-system --timeout=180s

########################################
# 7. SINGLE NODE SCHEDULING
########################################
echo "[7/10] Allow workloads on control-plane (single-node only)"

kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true

########################################
# 8. METALLB
########################################
echo "[8/10] Installing MetalLB"

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.5/config/manifests/metallb-native.yaml

echo "Waiting for MetalLB webhook..."
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

########################################
# 9. INGRESS NGINX (HARDENED)
########################################
echo "[9/10] Installing NGINX Ingress"

kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml

kubectl wait --namespace ingress-nginx \
  --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

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

########################################
# 10. TEST APP
########################################
echo "[10/10] Deploying test app + ingress"

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
        args:
        - "-text=hello from kubeadm"
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

echo "======================================"
echo "✅ Kubernetes single-node setup DONE"
echo "➡ Add to /etc/hosts:"
echo "   <INGRESS-IP> hello.local"
echo "➡ Test with: curl http://hello.local"
echo "======================================"
