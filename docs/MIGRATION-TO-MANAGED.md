# Migration Guide: kubeadm to Managed Kubernetes

## Overview

This guide covers migrating from self-managed kubeadm Kubernetes to managed services (EKS, GKE, AKS).

**Key Principle**: You don't "convert" kubeadm → managed. You **replace** the cluster and migrate workloads.

## Migration Approaches

| Approach | Downtime | Complexity | Risk |
|----------|----------|------------|------|
| Blue-Green | Zero | Medium | Low |
| In-Place Replace | Minutes-Hours | Low | Medium |
| Gradual Traffic Shift | Zero | High | Low |

**Recommended**: Blue-Green with DNS cutover

---

## Pre-Migration Assessment

### Workload Compatibility Checklist

| Item | kubeadm | Managed K8s | Action Required |
|------|---------|-------------|-----------------|
| hostPath volumes | ✅ Works | ❌ Blocked | Migrate to PVC |
| NodePort services | ✅ Works | ⚠️ Limited | Use LoadBalancer/Ingress |
| hostNetwork pods | ✅ Works | ⚠️ Restricted | Redesign networking |
| Privileged containers | ✅ Works | ⚠️ Restricted | Use SecurityContext |
| Custom CNI | ✅ Any | ⚠️ Limited | Check provider support |
| GPU workloads | Manual | Native support | Simplifies |
| Ingress | Manual | Native ALB/NLB | Simplifies |

### Your Current Setup Compatibility

Based on this setup, you're well-positioned:

| Component | Status | Notes |
|-----------|--------|-------|
| Ingress (NGINX) | ✅ Portable | Same manifests work |
| Calico CNI | ✅ Compatible | EKS/GKE support Calico |
| MetalLB | ⚠️ Replace | Use cloud LB instead |
| PVCs | ✅ Portable | Use cloud storage classes |
| Deployments | ✅ Portable | No changes needed |
| Services | ✅ Portable | Minor type changes |
| ConfigMaps/Secrets | ✅ Portable | Export and apply |

---

## Phase 1: Preparation (Do This Now)

### 1.1 Adopt GitOps

**Why**: Makes migration trivial—just point ArgoCD to new cluster.

```bash
# Install ArgoCD on kubeadm cluster
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Structure your manifests:

```
gitops-repo/
├── apps/
│   ├── app1/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   └── app2/
├── infrastructure/
│   ├── ingress-nginx/
│   ├── cert-manager/
│   └── monitoring/
└── clusters/
    ├── kubeadm-prod/
    │   └── kustomization.yaml
    └── eks-prod/         # Future
        └── kustomization.yaml
```

### 1.2 Externalize State

**Move data outside the cluster:**

| Data Type | Current | Target |
|-----------|---------|--------|
| Databases | In-cluster pods | RDS/CloudSQL/Managed |
| Object storage | Local/hostPath | S3/GCS |
| Secrets | Kubernetes Secrets | Secrets Manager/Vault |
| DNS | Manual | Route53/Cloud DNS |

### 1.3 Document Everything

```bash
# Export all resources
kubectl get all -A -o yaml > cluster-backup.yaml

# Export specific resources
kubectl get deployments -A -o yaml > deployments.yaml
kubectl get services -A -o yaml > services.yaml
kubectl get ingress -A -o yaml > ingresses.yaml
kubectl get configmaps -A -o yaml > configmaps.yaml
kubectl get secrets -A -o yaml > secrets.yaml  # Be careful with this

# Document custom resources
kubectl api-resources --verbs=list -o name | xargs -I {} kubectl get {} -A -o yaml > all-resources.yaml
```

---

## Phase 2: Create Managed Cluster

### AWS EKS Example

```bash
# Install eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# Create cluster
eksctl create cluster \
  --name prod-eks \
  --region us-east-1 \
  --version 1.29 \
  --nodegroup-name workers \
  --node-type t3.medium \
  --nodes 3 \
  --nodes-min 2 \
  --nodes-max 5 \
  --managed

# Get kubeconfig
aws eks update-kubeconfig --name prod-eks --region us-east-1
```

### GKE Example

```bash
gcloud container clusters create prod-gke \
  --zone us-central1-a \
  --num-nodes 3 \
  --machine-type e2-medium \
  --enable-autoscaling \
  --min-nodes 2 \
  --max-nodes 5
```

### AKS Example

```bash
az aks create \
  --resource-group myResourceGroup \
  --name prod-aks \
  --node-count 3 \
  --node-vm-size Standard_DS2_v2 \
  --enable-cluster-autoscaler \
  --min-count 2 \
  --max-count 5
```

---

## Phase 3: Configure Managed Cluster

### 3.1 Install Core Components

```bash
# Context: managed cluster
kubectl config use-context <managed-cluster>

# Ingress Controller (prefer the cloud's native controller or a Gateway API
# implementation: ingress-nginx was retired upstream in March 2026)
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/cloud/deploy.yaml

# cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# ArgoCD
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

### 3.2 Storage Classes

```bash
# List available storage classes
kubectl get storageclasses

# EKS default: gp2, gp3
# GKE default: standard, premium-rwo
# AKS default: managed-premium, managed-csi
```

### 3.3 Update Manifests for Cloud

**Changes typically needed:**

```yaml
# Before (kubeadm)
apiVersion: v1
kind: Service
metadata:
  name: myapp
spec:
  type: LoadBalancer  # Uses MetalLB
  
# After (EKS)
apiVersion: v1
kind: Service
metadata:
  name: myapp
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: nlb  # Use NLB
spec:
  type: LoadBalancer
```

```yaml
# Before (kubeadm)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  storageClassName: ""  # Uses local
  
# After (EKS)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data
spec:
  storageClassName: gp3  # Use EBS gp3
```

---

## Phase 4: Deploy Workloads

### If Using GitOps (Recommended)

```bash
# Point ArgoCD to your repo
argocd app create myapp \
  --repo https://github.com/org/gitops-repo \
  --path apps/myapp \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace production

# Sync
argocd app sync myapp
```

### If Using kubectl

```bash
# Apply manifests
kubectl apply -f apps/
kubectl apply -f infrastructure/
```

### Verify Deployment

```bash
kubectl get pods -A
kubectl get svc -A
kubectl get ingress -A
```

---

## Phase 5: Traffic Cutover

### DNS-Based Cutover (Recommended)

```
Current DNS:
app.example.com -> kubeadm-ingress-ip

After cutover:
app.example.com -> managed-k8s-lb-ip
```

**Steps:**

1. Lower DNS TTL (to 60s) 24 hours before
2. Verify managed cluster is working
3. Update DNS to point to managed cluster
4. Monitor for 1 hour
5. If issues, rollback DNS
6. If stable, restore normal TTL

### Weighted Cutover (Advanced)

Using Route53 weighted routing or similar:

```
app.example.com:
  - 90% -> kubeadm-ingress-ip
  - 10% -> managed-k8s-lb-ip

Gradually shift:
  - 70/30 -> 50/50 -> 30/70 -> 0/100
```

---

## Phase 6: Decommission kubeadm Cluster

### After Successful Migration

1. **Monitor managed cluster for 1-2 weeks**
2. **Keep kubeadm cluster as cold standby**
3. **Final backup**:
   ```bash
   kubectl get all -A -o yaml > final-backup.yaml
   ```
4. **Delete resources**:
   ```bash
   kubectl delete all --all -A
   ```
5. **Destroy VMs**

---

## Rollback Plan

### If Migration Fails

1. **DNS Rollback** (fastest):
   ```bash
   # Point DNS back to kubeadm
   app.example.com -> kubeadm-ingress-ip
   ```

2. **Data Rollback** (if needed):
   - Restore databases from backup
   - Re-sync persistent data

3. **Investigation**:
   - Collect logs from managed cluster
   - Fix issues
   - Retry migration

---

## Cost Comparison

| Item | kubeadm (5 VMs) | EKS | GKE | AKS |
|------|-----------------|-----|-----|-----|
| Control Plane | $0 (self-managed) | $72/month | $72/month | Free |
| Worker Nodes | VM costs | EC2 costs | GCE costs | VM costs |
| Load Balancer | $0 (MetalLB) | ~$20/month | ~$20/month | ~$20/month |
| Ops Overhead | High | Low | Low | Low |
| Upgrades | Manual | Managed | Managed | Managed |

---

## Timeline Estimate

| Phase | Duration | Notes |
|-------|----------|-------|
| Preparation | 1-2 weeks | GitOps, externalize state |
| Create Cluster | 1 day | Automated |
| Configure | 2-3 days | Components, IAM |
| Deploy Workloads | 1-2 days | Testing |
| Traffic Cutover | 1 day | With monitoring |
| Stabilization | 1-2 weeks | Before decommission |
| **Total** | **3-6 weeks** | Conservative |

---

## Security Considerations

### What Changes

| Aspect | kubeadm | Managed |
|--------|---------|---------|
| API Server | You secure | Provider secures |
| etcd | You manage | Provider manages |
| Node OS | You patch | Provider patches (managed nodes) |
| IAM | Your SSH keys | Cloud IAM integration |
| Audit Logs | Manual | Built-in |
| Network | Your SGs | VPC + provider policies |

### What Stays the Same

- RBAC configuration
- NetworkPolicies
- Pod Security Standards
- Workload security

---

## Checklist

### Pre-Migration
- [ ] All workloads in Git
- [ ] ArgoCD configured
- [ ] Databases externalized
- [ ] Secrets in external store
- [ ] DNS TTL lowered
- [ ] Backup completed
- [ ] Rollback plan documented

### Migration Day
- [ ] Managed cluster healthy
- [ ] All workloads deployed
- [ ] Services accessible
- [ ] TLS certificates working
- [ ] Monitoring active
- [ ] Team notified
- [ ] DNS updated
- [ ] Old cluster on standby

### Post-Migration
- [ ] 24h monitoring clean
- [ ] 1 week stable
- [ ] Old cluster backups archived
- [ ] Old cluster decommissioned
- [ ] Documentation updated
- [ ] Cost tracking confirmed
