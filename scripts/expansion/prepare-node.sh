#!/bin/bash
#===============================================================================
# Kubernetes Node Preparation Script
#===============================================================================
# This script prepares a new node (control-plane or worker) for joining
# an existing kubeadm cluster. Run this on EACH new node before joining.
#
# Usage:
#   ./prepare-node.sh
#
# Requirements:
#   - Ubuntu 22.04 LTS
#   - Root access (sudo)
#   - Network connectivity to existing cluster
#   - x86_64 or ARM64 architecture
#
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
K8S_VERSION="1.35"

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

detect_architecture() {
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH_DEB="amd64"
            log_info "Detected architecture: x86_64 (amd64)"
            ;;
        aarch64)
            ARCH_DEB="arm64"
            log_info "Detected architecture: ARM64 (aarch64)"
            ;;
        *)
            log_error "Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check OS
    if ! grep -q "Ubuntu 22.04" /etc/os-release 2>/dev/null; then
        log_warn "This script is tested on Ubuntu 22.04. Your OS may differ."
    fi
    
    # Check resources
    CPU_CORES=$(nproc)
    RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    
    if [[ $CPU_CORES -lt 2 ]]; then
        log_warn "Recommended: 2+ CPU cores (found: $CPU_CORES)"
    fi
    
    if [[ $RAM_MB -lt 1800 ]]; then
        log_error "Minimum 2GB RAM required (found: ${RAM_MB}MB)"
        exit 1
    fi
    
    log_success "Prerequisites check passed"
}

configure_system() {
    log_info "Configuring system settings..."
    
    # Disable swap
    swapoff -a
    sed -i '/swap/d' /etc/fstab
    log_success "Swap disabled"
    
    # Load required kernel modules
    cat > /etc/modules-load.d/k8s.conf << EOF
overlay
br_netfilter
EOF
    
    modprobe overlay
    modprobe br_netfilter
    log_success "Kernel modules loaded"
    
    # Configure sysctl
    cat > /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    
    sysctl --system > /dev/null 2>&1
    log_success "Sysctl configured"
}

install_containerd() {
    log_info "Installing containerd..."
    
    # Install dependencies
    apt-get update -qq
    apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release > /dev/null
    
    # Add Docker repository for containerd
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    
    echo "deb [arch=${ARCH_DEB} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    apt-get update -qq
    apt-get install -y -qq containerd.io > /dev/null
    
    # Configure containerd
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    
    # Enable systemd cgroup driver
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
    
    # Restart containerd
    systemctl restart containerd
    systemctl enable containerd
    
    log_success "containerd installed and configured"
}

install_kubernetes() {
    log_info "Installing Kubernetes components (v${K8S_VERSION})..."
    
    # Add Kubernetes repository
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
    
    apt-get update -qq
    apt-get install -y -qq kubelet kubeadm kubectl > /dev/null
    apt-mark hold kubelet kubeadm kubectl
    
    # Enable kubelet
    systemctl enable kubelet
    
    log_success "Kubernetes components installed"
}

configure_crictl() {
    log_info "Configuring crictl..."
    
    cat > /etc/crictl.yaml << EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
    
    log_success "crictl configured"
}

print_next_steps() {
    echo ""
    echo "=============================================================="
    echo -e "${GREEN}Node preparation complete!${NC}"
    echo "=============================================================="
    echo ""
    echo "Next steps:"
    echo ""
    echo "1. Get join command from existing control-plane node:"
    echo "   sudo kubeadm token create --print-join-command"
    echo ""
    echo "2. For CONTROL PLANE nodes, also get certificate key:"
    echo "   sudo kubeadm init phase upload-certs --upload-certs"
    echo ""
    echo "3. Join this node to the cluster:"
    echo ""
    echo "   For WORKER nodes:"
    echo "   sudo kubeadm join <lb-ip>:6443 --token <token> \\"
    echo "       --discovery-token-ca-cert-hash sha256:<hash>"
    echo ""
    echo "   For CONTROL PLANE nodes:"
    echo "   sudo kubeadm join <lb-ip>:6443 --token <token> \\"
    echo "       --discovery-token-ca-cert-hash sha256:<hash> \\"
    echo "       --control-plane --certificate-key <cert-key>"
    echo ""
    echo "=============================================================="
}

# Main execution
main() {
    echo "=============================================================="
    echo "Kubernetes Node Preparation Script"
    echo "=============================================================="
    echo ""
    
    check_root
    detect_architecture
    check_prerequisites
    configure_system
    install_containerd
    install_kubernetes
    configure_crictl
    print_next_steps
}

main "$@"
