#!/bin/bash
#===============================================================================
# HAProxy Load Balancer Setup for Kubernetes HA
#===============================================================================
# This script installs and configures HAProxy as a load balancer for
# Kubernetes API servers in an HA cluster setup.
#
# Usage:
#   ./setup-haproxy.sh <cp1_ip> <cp2_ip> <cp3_ip>
#
# Example:
#   ./setup-haproxy.sh 10.0.1.10 10.0.1.11 10.0.1.12
#
# Requirements:
#   - Ubuntu 22.04 LTS
#   - Root access (sudo)
#   - Network connectivity to all control plane nodes
#
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
HAPROXY_STATS_PORT=9000
HAPROXY_STATS_USER="admin"
HAPROXY_STATS_PASS="haproxy-stats-$(openssl rand -hex 8)"

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

usage() {
    echo "Usage: $0 <cp1_ip> <cp2_ip> <cp3_ip>"
    echo ""
    echo "Arguments:"
    echo "  cp1_ip    IP address of control plane node 1"
    echo "  cp2_ip    IP address of control plane node 2"
    echo "  cp3_ip    IP address of control plane node 3"
    echo ""
    echo "Example:"
    echo "  $0 10.0.1.10 10.0.1.11 10.0.1.12"
    exit 1
}

validate_ip() {
    local ip=$1
    if [[ ! $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid IP address: $ip"
        exit 1
    fi
}

install_haproxy() {
    log_info "Installing HAProxy..."
    
    apt-get update -qq
    apt-get install -y -qq haproxy > /dev/null
    
    log_success "HAProxy installed"
}

configure_haproxy() {
    local cp1_ip=$1
    local cp2_ip=$2
    local cp3_ip=$3
    
    log_info "Configuring HAProxy..."
    
    # Backup original config
    cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak
    
    cat > /etc/haproxy/haproxy.cfg << EOF
#---------------------------------------------------------------------
# Global settings
#---------------------------------------------------------------------
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon

    # Default SSL material locations
    ca-base /etc/ssl/certs
    crt-base /etc/ssl/private

    # Modern TLS settings
    ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
    ssl-default-bind-ciphersuites TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384
    ssl-default-bind-options ssl-min-ver TLSv1.2

#---------------------------------------------------------------------
# Defaults
#---------------------------------------------------------------------
defaults
    log     global
    mode    tcp
    option  tcplog
    option  dontlognull
    timeout connect 5s
    timeout client  30s
    timeout server  30s
    retries 3

#---------------------------------------------------------------------
# Kubernetes API Server Frontend
#---------------------------------------------------------------------
frontend kubernetes-api
    bind *:6443
    mode tcp
    option tcplog
    default_backend kubernetes-api-backend

#---------------------------------------------------------------------
# Kubernetes API Server Backend
#---------------------------------------------------------------------
backend kubernetes-api-backend
    mode tcp
    option tcp-check
    balance roundrobin
    default-server inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
    
    server cp1 ${cp1_ip}:6443 check
    server cp2 ${cp2_ip}:6443 check
    server cp3 ${cp3_ip}:6443 check

#---------------------------------------------------------------------
# Stats Frontend (optional but useful)
#---------------------------------------------------------------------
frontend stats
    bind *:${HAPROXY_STATS_PORT}
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats admin if LOCALHOST
    stats auth ${HAPROXY_STATS_USER}:${HAPROXY_STATS_PASS}
EOF
    
    log_success "HAProxy configured"
}

validate_config() {
    log_info "Validating HAProxy configuration..."
    
    if haproxy -c -f /etc/haproxy/haproxy.cfg; then
        log_success "Configuration is valid"
    else
        log_error "Configuration validation failed"
        exit 1
    fi
}

start_haproxy() {
    log_info "Starting HAProxy..."
    
    systemctl restart haproxy
    systemctl enable haproxy
    
    # Wait for HAProxy to start
    sleep 2
    
    if systemctl is-active --quiet haproxy; then
        log_success "HAProxy is running"
    else
        log_error "HAProxy failed to start"
        systemctl status haproxy
        exit 1
    fi
}

print_summary() {
    local lb_ip
    lb_ip=$(hostname -I | awk '{print $1}')
    
    echo ""
    echo "=============================================================="
    echo -e "${GREEN}HAProxy Setup Complete!${NC}"
    echo "=============================================================="
    echo ""
    echo "Configuration:"
    echo "  - Load Balancer IP:  ${lb_ip}"
    echo "  - API Server Port:   6443"
    echo "  - Stats URL:         http://${lb_ip}:${HAPROXY_STATS_PORT}/stats"
    echo "  - Stats User:        ${HAPROXY_STATS_USER}"
    echo "  - Stats Password:    ${HAPROXY_STATS_PASS}"
    echo ""
    echo "Backend Servers:"
    echo "  - cp1: $1:6443"
    echo "  - cp2: $2:6443"
    echo "  - cp3: $3:6443"
    echo ""
    echo "Use this as controlPlaneEndpoint: ${lb_ip}:6443"
    echo ""
    echo "Test connectivity:"
    echo "  nc -zv ${lb_ip} 6443"
    echo ""
    echo "=============================================================="
    echo ""
    echo -e "${YELLOW}IMPORTANT: Save these credentials securely!${NC}"
    echo "Stats Password: ${HAPROXY_STATS_PASS}"
    echo ""
}

# Main execution
main() {
    if [[ $# -ne 3 ]]; then
        usage
    fi
    
    local cp1_ip=$1
    local cp2_ip=$2
    local cp3_ip=$3
    
    echo "=============================================================="
    echo "HAProxy Load Balancer Setup for Kubernetes HA"
    echo "=============================================================="
    echo ""
    
    check_root
    
    # Validate IP addresses
    validate_ip "$cp1_ip"
    validate_ip "$cp2_ip"
    validate_ip "$cp3_ip"
    
    install_haproxy
    configure_haproxy "$cp1_ip" "$cp2_ip" "$cp3_ip"
    validate_config
    start_haproxy
    print_summary "$cp1_ip" "$cp2_ip" "$cp3_ip"
}

main "$@"
