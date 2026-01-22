# Security Documentation

## Security Model Overview

This document describes the security architecture and hardening measures implemented in the kubeadm cluster.

## Defense in Depth

```
┌─────────────────────────────────────────────────────────────────────┐
│                         LAYER 1: Network                            │
│  • Private API server (no public 6443)                              │
│  • SSH tunnel for remote access                                     │
│  • Security groups restrict ingress                                 │
├─────────────────────────────────────────────────────────────────────┤
│                         LAYER 2: Transport                          │
│  • TLS 1.2+ everywhere                                              │
│  • Mutual TLS for etcd                                              │
│  • Certificate-based authentication                                 │
├─────────────────────────────────────────────────────────────────────┤
│                         LAYER 3: Authentication                     │
│  • X.509 client certificates                                        │
│  • Service account tokens                                           │
│  • No anonymous authentication                                      │
├─────────────────────────────────────────────────────────────────────┤
│                         LAYER 4: Authorization                      │
│  • RBAC enabled                                                     │
│  • Principle of least privilege                                     │
│  • Namespace isolation                                              │
├─────────────────────────────────────────────────────────────────────┤
│                         LAYER 5: Workload                           │
│  • Pod Security Standards                                           │
│  • NetworkPolicies                                                  │
│  • Resource limits                                                  │
└─────────────────────────────────────────────────────────────────────┘
```

## API Server Security

### Access Control

| Method | Status | Notes |
|--------|--------|-------|
| Anonymous auth | ❌ Disabled | `--anonymous-auth=false` (recommended) |
| X.509 certs | ✅ Enabled | Primary authentication method |
| Service accounts | ✅ Enabled | For in-cluster workloads |
| OIDC | ⚪ Not configured | Can be added for SSO |

### Authorization

```yaml
# Current authorization mode
--authorization-mode=Node,RBAC
```

- **Node**: Kubelet authorization
- **RBAC**: Role-based access control for users/services

### Admission Controllers

Enabled by default in kubeadm:
- `NamespaceLifecycle`
- `LimitRanger`
- `ServiceAccount`
- `PodSecurity`
- `Priority`
- `RuntimeClass`
- `ValidatingAdmissionWebhook`
- `MutatingAdmissionWebhook`

## Network Security

### API Server Exposure

```
❌ NOT EXPOSED
┌─────────────────────────────────────┐
│  Internet                           │
│  └── ✗ Cannot reach :6443           │
└─────────────────────────────────────┘

✅ SECURE ACCESS PATH
┌─────────────────────────────────────┐
│  Local Machine                      │
│  └── SSH tunnel (:22)               │
│      └── localhost:6443             │
│          └── 10.0.129.132:6443      │
└─────────────────────────────────────┘
```

### Security Group Rules (AWS EC2)

| Direction | Port | Protocol | Source | Purpose |
|-----------|------|----------|--------|---------|
| Inbound | 22 | TCP | Your IP | SSH access |
| Inbound | 80 | TCP | 0.0.0.0/0 | HTTP (redirect) |
| Inbound | 443 | TCP | 0.0.0.0/0 | HTTPS (Ingress) |
| Inbound | 6443 | TCP | ❌ BLOCKED | API server (use SSH tunnel) |

### NetworkPolicy Enforcement

```yaml
# Default deny (recommended)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
```

### Recommended NetworkPolicies

```yaml
# 1. Allow DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: default
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53

---
# 2. Allow ingress from ingress-nginx
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-ingress
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: hello
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
```

## Ingress Security

### NGINX Ingress Hardening

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
data:
  # Hide server version
  server-tokens: "false"
  
  # TLS settings
  ssl-protocols: "TLSv1.2 TLSv1.3"
  ssl-ciphers: "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256"
  
  # WAF
  enable-modsecurity: "true"
  enable-owasp-modsecurity-crs: "true"
  
  # Headers
  use-forwarded-headers: "true"
```

### Per-Ingress Annotations

```yaml
metadata:
  annotations:
    # Force HTTPS
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    
    # Rate limiting
    nginx.ingress.kubernetes.io/limit-rps: "20"
    nginx.ingress.kubernetes.io/limit-burst-multiplier: "5"
    
    # Security headers
    nginx.ingress.kubernetes.io/configuration-snippet: |
      add_header X-Frame-Options "SAMEORIGIN" always;
      add_header X-Content-Type-Options "nosniff" always;
      add_header X-XSS-Protection "1; mode=block" always;
```

## Pod Security

### Pod Security Standards

```bash
# Apply baseline enforcement
kubectl label namespace default \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/audit=baseline \
  pod-security.kubernetes.io/warn=baseline
```

### Levels

| Level | Restrictions |
|-------|--------------|
| **privileged** | Unrestricted |
| **baseline** | Minimal restrictions, prevents known privilege escalations |
| **restricted** | Heavily restricted, follows best practices |

### Baseline Requirements (applied)

- ❌ No privileged containers
- ❌ No hostNetwork
- ❌ No hostPID
- ❌ No hostIPC
- ❌ No hostPath (some exceptions)
- ✅ Must drop ALL capabilities (add back specific ones)
- ✅ Must run as non-root (restricted only)

## Secret Management

### Current State

⚠️ **Secrets stored in etcd without encryption at rest**

### Recommended: Enable Encryption at Rest

```yaml
# /etc/kubernetes/encryption.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:
      keys:
      - name: key1
        secret: <base64-encoded-32-byte-key>
  - identity: {}
```

Add to API server:
```
--encryption-provider-config=/etc/kubernetes/encryption.yaml
```

### External Secret Management (Recommended)

For production:
- **HashiCorp Vault** + External Secrets Operator
- **AWS Secrets Manager** + External Secrets
- **Azure Key Vault** + CSI driver

## kubeconfig Security

### Admin kubeconfig Location

| Location | Purpose | Security |
|----------|---------|----------|
| `/etc/kubernetes/admin.conf` | Cluster admin | Root-only on control plane |
| `~/.kube/config` (local) | Developer access | User-owned, chmod 600 |

### Best Practices

1. **Never commit kubeconfig to git**
2. **Use RBAC-limited service accounts** for CI/CD
3. **Rotate certificates annually**
4. **Use short-lived tokens** where possible

### Creating Limited kubeconfig

```bash
# Create namespace-scoped service account
kubectl create serviceaccount deploy-sa -n app-prod
kubectl create rolebinding deploy-sa-binding \
  --clusterrole=edit \
  --serviceaccount=app-prod:deploy-sa \
  -n app-prod

# Generate kubeconfig for this SA
# (Use token-based or cert-based approach)
```

## Audit Logging

### Enable Audit Logging (Recommended)

```yaml
# /etc/kubernetes/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  resources:
  - group: ""
    resources: ["secrets", "configmaps"]
- level: RequestResponse
  resources:
  - group: ""
    resources: ["pods", "services"]
  - group: "apps"
    resources: ["deployments"]
```

API server flags:
```
--audit-log-path=/var/log/kubernetes/audit.log
--audit-log-maxage=30
--audit-log-maxbackup=10
--audit-log-maxsize=100
--audit-policy-file=/etc/kubernetes/audit-policy.yaml
```

## CIS Kubernetes Benchmark Summary

### Control Plane (Partial Checklist)

| ID | Description | Status |
|----|-------------|--------|
| 1.1.1 | API server pod spec permissions | ✅ |
| 1.2.1 | Anonymous authentication disabled | ⚠️ Configure |
| 1.2.6 | RBAC authorization enabled | ✅ |
| 1.2.16 | Audit logging enabled | ⚠️ Configure |
| 1.2.22 | TLS certificates configured | ✅ |

### Worker Nodes

| ID | Description | Status |
|----|-------------|--------|
| 4.1.1 | Kubelet config file permissions | ✅ |
| 4.2.1 | Anonymous auth disabled on kubelet | ⚠️ Verify |
| 4.2.4 | Read-only port disabled | ✅ (default) |

### Policies

| ID | Description | Status |
|----|-------------|--------|
| 5.1.1 | RBAC properly configured | ✅ |
| 5.2.1 | Pod Security Standards | ⚠️ Configure per namespace |
| 5.3.1 | NetworkPolicies defined | ⚠️ Configure per namespace |

## Security Maintenance

### Regular Tasks

| Task | Frequency | Command |
|------|-----------|---------|
| Review RBAC | Monthly | `kubectl get clusterrolebindings` |
| Rotate certificates | Annually | `kubeadm certs renew all` |
| Check CVEs | Weekly | Review Kubernetes security announcements |
| Update components | Quarterly | `kubeadm upgrade` |

### Security Scanning

```bash
# Scan for vulnerabilities
kubectl run trivy --rm -it --image=aquasec/trivy -- image <your-image>

# Scan cluster configuration
kubectl run kube-bench --rm -it --image=aquasec/kube-bench -- run
```
