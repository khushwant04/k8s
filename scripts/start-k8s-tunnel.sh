#!/usr/bin/env bash
#===============================================================================
# Kubernetes API SSH Tunnel Script
#===============================================================================
#
# Description:
#   Creates an SSH tunnel to access the Kubernetes API server securely.
#   The API server is not exposed publicly; this tunnel provides secure access.
#
# Usage:
#   bash start-k8s-tunnel.sh
#
# How it works:
#   1. Opens SSH connection to the VM
#   2. Forwards local port 6443 to the API server's private IP
#   3. kubectl connects to localhost:6443, traffic goes through tunnel
#
# Prerequisites:
#   - SSH key with access to the VM
#   - VM public IP accessible from your network
#
# After starting:
#   kubectl --kubeconfig=~/kubeadm.conf --tls-server-name=10.0.129.132 get nodes
#
# To stop tunnel:
#   pkill -f "ssh.*6443"
#
# Version: 1.0.0
# Last Updated: January 2026
#===============================================================================

set -e

### =========================
### CONFIGURATION
### =========================
# Update these values for your environment

KEY_PATH="$HOME/ssh-keys/hx.pem"     # Path to SSH private key
REMOTE_USER="ubuntu"                  # SSH user on VM
REMOTE_HOST="13.201.92.125"           # VM public IP (update this!)

# Kubernetes API server details (from kubeadm init output)
K8S_API_PRIVATE_IP="10.0.129.132"     # Private IP of the control plane
K8S_API_PORT="6443"                   # API server port
LOCAL_PORT="6443"                     # Local port to forward

### =========================
### MAIN
### =========================

# Check if tunnel already running
if ss -lntp 2>/dev/null | grep -q ":${LOCAL_PORT}"; then
    echo "⚠️  Port ${LOCAL_PORT} already in use. Tunnel may be running."
    echo "   To kill existing tunnel: pkill -f 'ssh.*${LOCAL_PORT}'"
    exit 1
fi

echo "🔒 Starting Kubernetes API tunnel..."
echo "   Local:  localhost:${LOCAL_PORT}"
echo "   Remote: ${K8S_API_PRIVATE_IP}:${K8S_API_PORT}"
echo ""

ssh -i "${KEY_PATH}" \
    -N \
    -f \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -L ${LOCAL_PORT}:${K8S_API_PRIVATE_IP}:${K8S_API_PORT} \
    ${REMOTE_USER}@${REMOTE_HOST}

echo "✅ Tunnel started successfully!"
echo ""
echo "📋 Next steps:"
echo "   kubectl --kubeconfig=~/kubeadm.conf --tls-server-name=${K8S_API_PRIVATE_IP} get nodes"
echo ""
echo "🛑 To stop tunnel:"
echo "   pkill -f 'ssh.*${LOCAL_PORT}'"
