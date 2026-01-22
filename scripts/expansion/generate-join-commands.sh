#!/bin/bash
#===============================================================================
# Generate Kubernetes Cluster Join Commands
#===============================================================================
# This script generates join commands for adding new nodes to an existing
# kubeadm cluster. Run this on an existing control plane node.
#
# Usage:
#   ./generate-join-commands.sh [--control-plane]
#
# Options:
#   --control-plane    Generate join command for control plane nodes
#                      (includes certificate key)
#
# Requirements:
#   - Run on existing control plane node
#   - Root access (sudo)
#   - Cluster must be healthy
#
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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

check_cluster() {
    log_info "Checking cluster health..."
    
    if ! kubectl get nodes &>/dev/null; then
        log_error "Cannot connect to cluster. Ensure KUBECONFIG is set."
        exit 1
    fi
    
    log_success "Cluster is accessible"
}

generate_worker_join() {
    log_info "Generating worker node join command..."
    echo ""
    
    local join_cmd
    join_cmd=$(kubeadm token create --print-join-command)
    
    echo "=============================================================="
    echo -e "${GREEN}WORKER NODE JOIN COMMAND${NC}"
    echo "=============================================================="
    echo ""
    echo "Run this command on worker nodes as root:"
    echo ""
    echo -e "${YELLOW}sudo ${join_cmd}${NC}"
    echo ""
    echo "=============================================================="
}

generate_controlplane_join() {
    log_info "Generating control plane node join command..."
    echo ""
    
    # Get the join command
    local join_cmd
    join_cmd=$(kubeadm token create --print-join-command)
    
    # Upload certificates and get certificate key
    log_info "Uploading certificates..."
    local cert_output
    cert_output=$(kubeadm init phase upload-certs --upload-certs 2>&1)
    local cert_key
    cert_key=$(echo "$cert_output" | grep -A1 "Using certificate key:" | tail -1 | tr -d ' ')
    
    if [[ -z "$cert_key" ]]; then
        # Alternative extraction method
        cert_key=$(echo "$cert_output" | tail -1 | tr -d ' ')
    fi
    
    echo "=============================================================="
    echo -e "${GREEN}CONTROL PLANE NODE JOIN COMMAND${NC}"
    echo "=============================================================="
    echo ""
    echo "Run this command on control plane nodes as root:"
    echo ""
    echo -e "${YELLOW}sudo ${join_cmd} \\
    --control-plane \\
    --certificate-key ${cert_key}${NC}"
    echo ""
    echo "=============================================================="
    echo ""
    echo -e "${RED}IMPORTANT:${NC} Certificate key expires in 2 hours!"
    echo "If expired, regenerate with:"
    echo "  sudo kubeadm init phase upload-certs --upload-certs"
    echo ""
}

print_post_join_steps() {
    echo ""
    echo "=============================================================="
    echo "POST-JOIN STEPS"
    echo "=============================================================="
    echo ""
    echo "After joining nodes, verify from existing control plane:"
    echo ""
    echo "1. Check node status:"
    echo "   kubectl get nodes"
    echo ""
    echo "2. Wait for node to be Ready:"
    echo "   kubectl wait --for=condition=Ready node/<node-name> --timeout=120s"
    echo ""
    echo "3. For control plane nodes, verify etcd membership:"
    echo "   kubectl get pods -n kube-system -l component=etcd"
    echo ""
    echo "4. Verify all system pods are running:"
    echo "   kubectl get pods -n kube-system"
    echo ""
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --control-plane    Generate join command for control plane nodes"
    echo "  --worker           Generate join command for worker nodes (default)"
    echo "  --both             Generate both join commands"
    echo "  -h, --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                     # Generate worker join command"
    echo "  $0 --control-plane     # Generate control plane join command"
    echo "  $0 --both              # Generate both commands"
}

# Main execution
main() {
    local mode="worker"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --control-plane)
                mode="controlplane"
                shift
                ;;
            --worker)
                mode="worker"
                shift
                ;;
            --both)
                mode="both"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
    
    echo "=============================================================="
    echo "Kubernetes Join Command Generator"
    echo "=============================================================="
    echo ""
    
    check_root
    
    # Set KUBECONFIG if not set
    if [[ -z "${KUBECONFIG:-}" ]]; then
        export KUBECONFIG=/etc/kubernetes/admin.conf
    fi
    
    check_cluster
    
    case $mode in
        worker)
            generate_worker_join
            ;;
        controlplane)
            generate_controlplane_join
            ;;
        both)
            generate_worker_join
            echo ""
            generate_controlplane_join
            ;;
    esac
    
    print_post_join_steps
}

main "$@"
