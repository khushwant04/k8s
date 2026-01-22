#!/bin/bash
#===============================================================================
# Kubernetes Cluster Verification Script
#===============================================================================
# This script verifies the health and status of a Kubernetes cluster,
# especially useful after expansion or upgrades.
#
# Usage:
#   ./verify-cluster.sh
#
# Requirements:
#   - kubectl configured and working
#   - Access to the cluster
#
#===============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Counters
CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_WARNED=0

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((CHECKS_PASSED++))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((CHECKS_WARNED++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    ((CHECKS_FAILED++))
}

check_header() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

check_connectivity() {
    check_header "Cluster Connectivity"
    
    if kubectl cluster-info &>/dev/null; then
        log_success "Cluster is reachable"
        echo "        $(kubectl cluster-info | head -1)"
    else
        log_fail "Cannot reach cluster"
        return 1
    fi
}

check_nodes() {
    check_header "Node Status"
    
    local nodes
    nodes=$(kubectl get nodes --no-headers 2>/dev/null)
    
    if [[ -z "$nodes" ]]; then
        log_fail "No nodes found"
        return 1
    fi
    
    echo "$nodes" | while read -r line; do
        local name status roles version
        name=$(echo "$line" | awk '{print $1}')
        status=$(echo "$line" | awk '{print $2}')
        roles=$(echo "$line" | awk '{print $3}')
        version=$(echo "$line" | awk '{print $5}')
        
        if [[ "$status" == "Ready" ]]; then
            echo -e "${GREEN}[PASS]${NC} Node $name ($roles) - $status - $version"
        elif [[ "$status" == "NotReady" ]]; then
            echo -e "${RED}[FAIL]${NC} Node $name ($roles) - $status - $version"
        else
            echo -e "${YELLOW}[WARN]${NC} Node $name ($roles) - $status - $version"
        fi
    done
    
    local total ready
    total=$(kubectl get nodes --no-headers | wc -l)
    ready=$(kubectl get nodes --no-headers | grep -c " Ready " || true)
    
    if [[ "$total" -eq "$ready" ]]; then
        log_success "All $total nodes are Ready"
    else
        log_fail "$ready/$total nodes are Ready"
    fi
}

check_control_plane_pods() {
    check_header "Control Plane Components"
    
    local components=("kube-apiserver" "kube-controller-manager" "kube-scheduler" "etcd")
    
    for component in "${components[@]}"; do
        local pods
        pods=$(kubectl get pods -n kube-system -l component="$component" --no-headers 2>/dev/null | wc -l)
        local running
        running=$(kubectl get pods -n kube-system -l component="$component" --no-headers 2>/dev/null | grep -c "Running" || true)
        
        if [[ "$pods" -gt 0 && "$pods" -eq "$running" ]]; then
            log_success "$component: $running/$pods pods running"
        elif [[ "$pods" -eq 0 ]]; then
            log_warn "$component: No pods found (may be static pods)"
        else
            log_fail "$component: $running/$pods pods running"
        fi
    done
}

check_core_dns() {
    check_header "CoreDNS"
    
    local desired running
    desired=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    running=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    
    if [[ "$desired" -eq "$running" && "$running" -gt 0 ]]; then
        log_success "CoreDNS: $running/$desired replicas ready"
    else
        log_fail "CoreDNS: $running/$desired replicas ready"
    fi
    
    # DNS resolution test
    log_info "Testing DNS resolution..."
    if kubectl run dns-test --image=busybox:1.36 --rm -it --restart=Never --command -- nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
        log_success "DNS resolution working"
    else
        log_warn "DNS resolution test inconclusive"
    fi
}

check_cni() {
    check_header "CNI (Calico)"
    
    local calico_pods running
    calico_pods=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | wc -l)
    running=$(kubectl get pods -n kube-system -l k8s-app=calico-node --no-headers 2>/dev/null | grep -c "Running" || true)
    
    if [[ "$calico_pods" -gt 0 && "$calico_pods" -eq "$running" ]]; then
        log_success "Calico: $running/$calico_pods pods running"
    elif [[ "$calico_pods" -eq 0 ]]; then
        log_warn "Calico pods not found (may use different CNI)"
    else
        log_fail "Calico: $running/$calico_pods pods running"
    fi
}

check_kube_proxy() {
    check_header "Kube-Proxy"
    
    local desired running
    desired=$(kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    running=$(kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null || echo "0")
    
    if [[ "$desired" -eq "$running" && "$running" -gt 0 ]]; then
        log_success "kube-proxy: $running/$desired pods running"
    else
        log_fail "kube-proxy: $running/$desired pods running"
    fi
}

check_system_pods() {
    check_header "All System Pods"
    
    local total running pending failed
    total=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | wc -l)
    running=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "Running" || true)
    pending=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -c "Pending" || true)
    failed=$(kubectl get pods -n kube-system --no-headers 2>/dev/null | grep -cE "Error|CrashLoopBackOff|ImagePullBackOff" || true)
    
    if [[ "$failed" -gt 0 ]]; then
        log_fail "$failed pods in failed state"
        kubectl get pods -n kube-system --no-headers | grep -E "Error|CrashLoopBackOff|ImagePullBackOff" | awk '{print "        " $1 ": " $3}'
    fi
    
    if [[ "$pending" -gt 0 ]]; then
        log_warn "$pending pods pending"
    fi
    
    if [[ "$running" -eq "$total" ]]; then
        log_success "All $total system pods running"
    else
        log_info "$running/$total system pods running"
    fi
}

check_etcd() {
    check_header "etcd Cluster"
    
    # Check etcd pods
    local etcd_pods
    etcd_pods=$(kubectl get pods -n kube-system -l component=etcd --no-headers 2>/dev/null | wc -l)
    
    if [[ "$etcd_pods" -eq 0 ]]; then
        log_warn "No etcd pods found (may be external etcd)"
        return
    fi
    
    if [[ "$etcd_pods" -eq 1 ]]; then
        log_warn "Single etcd member (no HA)"
    elif [[ "$etcd_pods" -eq 3 ]]; then
        log_success "3 etcd members (HA configuration)"
    elif [[ "$etcd_pods" -eq 5 ]]; then
        log_success "5 etcd members (enhanced HA)"
    else
        log_warn "$etcd_pods etcd members (unusual count)"
    fi
    
    # Try to check etcd health via API
    local first_cp
    first_cp=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | head -1 | awk '{print $1}')
    
    if [[ -n "$first_cp" ]]; then
        log_info "etcd leader check requires direct node access"
    fi
}

check_certificates() {
    check_header "Certificate Expiration"
    
    # This check can only be done from a control plane node
    if [[ -f /etc/kubernetes/pki/apiserver.crt ]]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in /etc/kubernetes/pki/apiserver.crt 2>/dev/null | cut -d= -f2)
        local expiry_epoch
        expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo "0")
        local now_epoch
        now_epoch=$(date +%s)
        local days_left
        days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
        
        if [[ "$days_left" -lt 30 ]]; then
            log_fail "API server cert expires in $days_left days"
        elif [[ "$days_left" -lt 90 ]]; then
            log_warn "API server cert expires in $days_left days"
        else
            log_success "API server cert valid for $days_left days"
        fi
    else
        log_info "Certificate check requires control plane node access"
    fi
}

check_api_server() {
    check_header "API Server Health"
    
    local health
    health=$(kubectl get --raw='/healthz' 2>/dev/null || echo "unhealthy")
    
    if [[ "$health" == "ok" ]]; then
        log_success "API server health: ok"
    else
        log_fail "API server health: $health"
    fi
    
    # Component statuses
    local cs
    cs=$(kubectl get componentstatuses 2>/dev/null || echo "")
    if [[ -n "$cs" ]]; then
        log_info "Component statuses:"
        kubectl get componentstatuses 2>/dev/null | tail -n +2 | while read -r line; do
            local name status
            name=$(echo "$line" | awk '{print $1}')
            status=$(echo "$line" | awk '{print $2}')
            if [[ "$status" == "Healthy" ]]; then
                echo -e "        ${GREEN}✓${NC} $name"
            else
                echo -e "        ${RED}✗${NC} $name: $status"
            fi
        done
    fi
}

print_summary() {
    echo ""
    echo "=============================================================="
    echo "VERIFICATION SUMMARY"
    echo "=============================================================="
    echo ""
    echo -e "  ${GREEN}Passed:${NC}  $CHECKS_PASSED"
    echo -e "  ${YELLOW}Warnings:${NC} $CHECKS_WARNED"
    echo -e "  ${RED}Failed:${NC}  $CHECKS_FAILED"
    echo ""
    
    if [[ "$CHECKS_FAILED" -eq 0 ]]; then
        echo -e "${GREEN}✓ Cluster verification passed!${NC}"
    else
        echo -e "${RED}✗ Cluster has issues that need attention${NC}"
    fi
    echo ""
}

# Main execution
main() {
    echo "=============================================================="
    echo "Kubernetes Cluster Verification"
    echo "=============================================================="
    echo "Time: $(date)"
    
    check_connectivity || exit 1
    check_nodes
    check_control_plane_pods
    check_core_dns
    check_cni
    check_kube_proxy
    check_system_pods
    check_etcd
    check_api_server
    check_certificates
    
    print_summary
    
    # Exit with error if any checks failed
    [[ "$CHECKS_FAILED" -eq 0 ]]
}

main "$@"
