# Upgrade Guide

## Kubernetes Version Upgrade Procedures

This document covers upgrading Kubernetes components using kubeadm.

## Pre-Upgrade Checklist

- [ ] Review [Kubernetes release notes](https://kubernetes.io/releases/)
- [ ] Verify upgrade path (can only upgrade one minor version at a time)
- [ ] Backup etcd
- [ ] Backup important manifests
- [ ] Test upgrade in staging first
- [ ] Schedule maintenance window
- [ ] Notify stakeholders

## Upgrade Path Rules

| From | To | Supported |
|------|-----|-----------|
| v1.35 | v1.36 | ✅ Yes |
| v1.35 | v1.37 | ❌ No (skip not allowed) |
| v1.34 | v1.35 | ✅ Yes |

**Always upgrade one minor version at a time.**

## Single Node Upgrade (Current Setup)

### Step 1: Backup etcd

```bash
# SSH to node
ssh ubuntu@<VM_IP>

# Create backup
ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-backup-$(date +%F).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Copy backup off the server
scp ubuntu@<VM_IP>:/tmp/etcd-backup-*.db ./backups/
```

### Step 2: Update Package Repository

```bash
# Update repo to new version (e.g., v1.36)
NEW_VERSION="v1.36"

# Update keyring (if needed)
curl -fsSL https://pkgs.k8s.io/core:/stable:/${NEW_VERSION}/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Update repo
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${NEW_VERSION}/deb/ /" \
  | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt update
```

### Step 3: Upgrade kubeadm

```bash
# Check available versions
apt-cache madison kubeadm

# Unhold and upgrade kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.36.0-*  # Adjust version
sudo apt-mark hold kubeadm

# Verify
kubeadm version
```

### Step 4: Plan Upgrade

```bash
# Check upgrade plan
sudo kubeadm upgrade plan
```

Expected output:
```
Components that must be upgraded manually after you have upgraded the control plane with 'kubeadm upgrade apply':
COMPONENT   CURRENT       TARGET
kubelet     v1.35.0       v1.36.0

Upgrade to the latest version in the v1.36 series:

COMPONENT                 CURRENT   TARGET
kube-apiserver            v1.35.0   v1.36.0
kube-controller-manager   v1.35.0   v1.36.0
kube-scheduler            v1.35.0   v1.36.0
kube-proxy                v1.35.0   v1.36.0
CoreDNS                   v1.11.1   v1.11.1
etcd                      3.5.12    3.5.12
```

### Step 5: Apply Upgrade

```bash
# Apply the upgrade (control plane components)
sudo kubeadm upgrade apply v1.36.0

# Confirm when prompted
```

### Step 6: Upgrade kubelet and kubectl

```bash
# Unhold
sudo apt-mark unhold kubelet kubectl

# Upgrade
sudo apt-get update
sudo apt-get install -y kubelet=1.36.0-* kubectl=1.36.0-*

# Hold again
sudo apt-mark hold kubelet kubectl

# Restart kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

### Step 7: Verify Upgrade

```bash
# Check node version
kubectl get nodes

# Expected output
NAME         STATUS   ROLES           AGE   VERSION
k8s-single   Ready    control-plane   30d   v1.36.0

# Check component versions
kubectl get pods -n kube-system -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[*].image
```

## Multi-Node Upgrade (Future HA Setup)

### Order of Operations

1. **Control plane nodes** (one at a time)
   - Upgrade kubeadm
   - `kubeadm upgrade apply` (first CP) or `kubeadm upgrade node` (additional CPs)
   - Upgrade kubelet + kubectl
   - Restart kubelet

2. **Worker nodes** (one at a time)
   - Drain node
   - Upgrade kubeadm
   - `kubeadm upgrade node`
   - Upgrade kubelet + kubectl
   - Restart kubelet
   - Uncordon node

### Worker Node Upgrade Steps

```bash
# From control plane - drain worker
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data

# SSH to worker
ssh ubuntu@worker-1

# Upgrade kubeadm
sudo apt-mark unhold kubeadm
sudo apt-get update && sudo apt-get install -y kubeadm=1.36.0-*
sudo apt-mark hold kubeadm

# Upgrade node configuration
sudo kubeadm upgrade node

# Upgrade kubelet and kubectl
sudo apt-mark unhold kubelet kubectl
sudo apt-get install -y kubelet=1.36.0-* kubectl=1.36.0-*
sudo apt-mark hold kubelet kubectl

# Restart
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# Exit worker, return to control plane
exit

# Uncordon worker
kubectl uncordon worker-1
```

## Upgrade Add-ons

### Calico CNI

```bash
# Check current version
kubectl get deployment -n kube-system calico-kube-controllers -o jsonpath='{.spec.template.spec.containers[0].image}'

# Upgrade (check latest version at projectcalico.docs.tigera.io)
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
```

### MetalLB

```bash
# Check current version
kubectl get deployment -n metallb-system controller -o jsonpath='{.spec.template.spec.containers[0].image}'

# Upgrade
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.15.0/config/manifests/metallb-native.yaml
```

### NGINX Ingress

```bash
# Check current version
kubectl get deployment -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.template.spec.containers[0].image}'

# Upgrade
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
```

## Rollback Procedures

### If Upgrade Fails Mid-Way

```bash
# Check status
kubectl get nodes
kubectl get pods -n kube-system

# If control plane is down, restore etcd from backup
# (See OPERATIONS.md - etcd restore section)
```

### Downgrade (NOT RECOMMENDED)

Downgrades are **not officially supported** by kubeadm. If you must:

1. Restore etcd from pre-upgrade backup
2. Reinstall previous version binaries
3. This is risky and may cause data loss

**Better approach:** Test in staging, and if production upgrade fails, restore from full backup.

## Post-Upgrade Verification

```bash
# 1. Node versions
kubectl get nodes

# 2. All system pods healthy
kubectl get pods -n kube-system

# 3. Application pods
kubectl get pods -A

# 4. Services accessible
kubectl get svc -A

# 5. Ingress working
curl -k https://<ingress-ip>

# 6. Storage (if applicable)
kubectl get pv,pvc -A

# 7. Check deprecation warnings
kubectl get --raw /metrics | grep apiserver_requested_deprecated_apis
```

## Upgrade Schedule Recommendations

| Environment | Upgrade Timing | Notes |
|-------------|----------------|-------|
| Development | Within 1 week of release | Test new features |
| Staging | 2-4 weeks after release | Validate compatibility |
| Production | 4-8 weeks after release | After staging validation |

**Never upgrade production before testing in staging.**

## Version Support Policy

| Version | Status | EOL |
|---------|--------|-----|
| v1.35 | Current | ~Dec 2026 |
| v1.34 | Supported | ~Sep 2026 |
| v1.33 | Maintenance | ~Jun 2026 |
| v1.32 | End of Life | ❌ |

**Kubernetes supports the 3 most recent minor versions.**

## Automation (Future)

Consider automating upgrades with:

- **Ansible playbooks** for consistent upgrades
- **GitOps** (ArgoCD) for add-on upgrades
- **Cluster API** for managed lifecycle

## Resources

- [Official Upgrade Documentation](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/)
- [Kubernetes Release Notes](https://kubernetes.io/releases/)
- [kubeadm Upgrade Reference](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-upgrade/)
