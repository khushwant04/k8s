# ArgoCD & GitOps Setup Guide

## Overview

This guide covers setting up ArgoCD for GitOps-driven deployment management. GitOps enables:

- **Declarative infrastructure**: Everything in Git
- **Automated sync**: Changes auto-deploy on commit
- **Easy rollback**: `git revert` = rollback
- **Audit trail**: Git history = change history
- **Multi-cluster**: Same manifests, different clusters

---

## Prerequisites

- Kubernetes cluster running (kubeadm or managed)
- `kubectl` configured and working
- Git repository for manifests

---

## Phase 1: Install ArgoCD

### 1.1 Create Namespace and Install

```bash
# Create namespace
kubectl create namespace argocd

# Install ArgoCD (stable release)
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for pods to be ready
kubectl wait --for=condition=Ready pods --all -n argocd --timeout=300s
```

### 1.2 Verify Installation

```bash
kubectl get pods -n argocd
```

Expected output:
```
NAME                                               READY   STATUS    RESTARTS   AGE
argocd-application-controller-0                    1/1     Running   0          2m
argocd-applicationset-controller-xxx               1/1     Running   0          2m
argocd-dex-server-xxx                              1/1     Running   0          2m
argocd-notifications-controller-xxx                1/1     Running   0          2m
argocd-redis-xxx                                   1/1     Running   0          2m
argocd-repo-server-xxx                             1/1     Running   0          2m
argocd-server-xxx                                  1/1     Running   0          2m
```

---

## Phase 2: Access ArgoCD UI

### Option A: Port Forward (Development)

```bash
# Port forward ArgoCD server
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Access at https://localhost:8080
```

### Option B: Ingress (Production)

```yaml
# argocd-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server-ingress
  namespace: argocd
  annotations:
    nginx.ingress.kubernetes.io/ssl-passthrough: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: argocd.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
  tls:
  - hosts:
    - argocd.example.com
```

```bash
kubectl apply -f argocd-ingress.yaml
```

### Option C: LoadBalancer

```bash
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
kubectl get svc argocd-server -n argocd
```

---

## Phase 3: Get Admin Password

```bash
# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo  # Print newline

# Username: admin
# Password: <output from above>
```

---

## Phase 4: Install ArgoCD CLI

```bash
# Linux x86_64
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64

# Linux ARM64
curl -sSL -o argocd-linux-arm64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-arm64
sudo install -m 555 argocd-linux-arm64 /usr/local/bin/argocd
rm argocd-linux-arm64

# macOS
brew install argocd

# Verify
argocd version
```

### Login via CLI

```bash
# If using port-forward
argocd login localhost:8080

# If using ingress
argocd login argocd.example.com

# Skip TLS verification (dev only)
argocd login localhost:8080 --insecure
```

---

## Phase 5: Setup Git Repository Structure

### Recommended Repository Layout

```
gitops-repo/
├── README.md
├── apps/                          # Application manifests
│   ├── hello-world/
│   │   ├── deployment.yaml
│   │   ├── service.yaml
│   │   └── ingress.yaml
│   ├── api-service/
│   │   ├── kustomization.yaml
│   │   ├── base/
│   │   │   ├── deployment.yaml
│   │   │   └── service.yaml
│   │   └── overlays/
│   │       ├── dev/
│   │       └── prod/
│   └── web-frontend/
│       └── ...
├── infrastructure/                 # Cluster infrastructure
│   ├── ingress-nginx/
│   │   └── helmrelease.yaml
│   ├── cert-manager/
│   │   └── helmrelease.yaml
│   ├── monitoring/
│   │   ├── prometheus/
│   │   └── grafana/
│   └── argocd/
│       └── argocd-cm.yaml
├── clusters/                       # Per-cluster configuration
│   ├── kubeadm-single/
│   │   ├── apps.yaml              # ApplicationSet or App-of-Apps
│   │   └── infrastructure.yaml
│   ├── kubeadm-ha/
│   │   ├── apps.yaml
│   │   └── infrastructure.yaml
│   └── eks-prod/
│       ├── apps.yaml
│       └── infrastructure.yaml
└── .github/
    └── workflows/
        └── validate.yaml          # CI validation
```

---

## Phase 6: Create Your First Application

### 6.1 Simple Application (CLI)

```bash
argocd app create hello-world \
  --repo https://github.com/your-org/gitops-repo.git \
  --path apps/hello-world \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

### 6.2 Application via Manifest

```yaml
# applications/hello-world.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hello-world
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/gitops-repo.git
    targetRevision: HEAD
    path: apps/hello-world
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true       # Delete resources not in Git
      selfHeal: true    # Revert manual changes
    syncOptions:
      - CreateNamespace=true
```

```bash
kubectl apply -f applications/hello-world.yaml
```

### 6.3 Verify Application

```bash
# List applications
argocd app list

# Get app status
argocd app get hello-world

# Sync manually (if not auto-sync)
argocd app sync hello-world

# View in UI
# https://localhost:8080/applications/hello-world
```

---

## Phase 7: App-of-Apps Pattern

Manage all applications from a single root application:

```yaml
# clusters/kubeadm-single/apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/gitops-repo.git
    targetRevision: HEAD
    path: clusters/kubeadm-single
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Then in `clusters/kubeadm-single/`:

```yaml
# clusters/kubeadm-single/hello-world.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: hello-world
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/gitops-repo.git
    path: apps/hello-world
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Phase 8: Private Repository Access

### 8.1 HTTPS with Token

```bash
argocd repo add https://github.com/your-org/private-repo.git \
  --username git \
  --password ghp_xxxxxxxxxxxx
```

### 8.2 SSH Key

```bash
# Add SSH key
argocd repo add git@github.com:your-org/private-repo.git \
  --ssh-private-key-path ~/.ssh/id_rsa
```

### 8.3 Via Kubernetes Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: private-repo
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repository
stringData:
  type: git
  url: https://github.com/your-org/private-repo.git
  username: git
  password: ghp_xxxxxxxxxxxx
```

---

## Phase 9: Helm Charts with ArgoCD

### 9.1 Helm Repository

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx-ingress
  namespace: argocd
spec:
  project: default
  source:
    chart: ingress-nginx
    repoURL: https://kubernetes.github.io/ingress-nginx
    targetRevision: 4.9.0
    helm:
      values: |
        controller:
          replicaCount: 2
          service:
            type: LoadBalancer
  destination:
    server: https://kubernetes.default.svc
    namespace: ingress-nginx
  syncPolicy:
    automated:
      prune: true
    syncOptions:
      - CreateNamespace=true
```

### 9.2 Helm Chart from Git

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/gitops-repo.git
    path: charts/my-app
    targetRevision: HEAD
    helm:
      valueFiles:
        - values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: production
```

---

## Phase 10: Kustomize with ArgoCD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/gitops-repo.git
    path: apps/my-app/overlays/prod
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

---

## Phase 11: Multi-Cluster Management

### 11.1 Add Cluster

```bash
# List current contexts
kubectl config get-contexts

# Add cluster to ArgoCD
argocd cluster add <context-name>

# List clusters
argocd cluster list
```

### 11.2 Deploy to External Cluster

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-on-eks
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/gitops-repo.git
    path: apps/my-app
  destination:
    server: https://XXXXX.eks.amazonaws.com  # External cluster API
    namespace: production
```

---

## Phase 12: Notifications

### 12.1 Slack Notifications

```yaml
# argocd-notifications-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.slack: |
    token: $slack-token
  template.app-sync-succeeded: |
    message: |
      Application {{.app.metadata.name}} sync succeeded!
  trigger.on-sync-succeeded: |
    - when: app.status.operationState.phase in ['Succeeded']
      send: [app-sync-succeeded]
```

### 12.2 Configure Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: argocd-notifications-secret
  namespace: argocd
stringData:
  slack-token: xoxb-your-slack-token
```

---

## Common Commands Reference

```bash
# Applications
argocd app list                          # List all apps
argocd app get <app>                     # Get app details
argocd app sync <app>                    # Sync app
argocd app diff <app>                    # Show diff
argocd app history <app>                 # Show history
argocd app rollback <app> <revision>     # Rollback

# Repositories
argocd repo list                         # List repos
argocd repo add <url>                    # Add repo

# Clusters
argocd cluster list                      # List clusters
argocd cluster add <context>             # Add cluster

# Projects
argocd proj list                         # List projects
argocd proj create <name>                # Create project

# Account
argocd account update-password           # Change password
argocd account list                      # List accounts
```

---

## Best Practices

### Do's ✅

1. **Always use automated sync with self-heal**
2. **Enable prune** to remove orphaned resources
3. **Use App-of-Apps** for managing multiple applications
4. **Separate environments** (dev/staging/prod) with overlays
5. **Use semantic versioning** for targetRevision
6. **Enable RBAC** for multi-team access
7. **Set resource limits** on ArgoCD components

### Don'ts ❌

1. **Don't commit secrets** to Git (use Sealed Secrets or External Secrets)
2. **Don't use `latest` tags** in container images
3. **Don't disable self-heal** in production
4. **Don't give everyone admin access**
5. **Don't mix environment configs** in same path

---

## Troubleshooting

### Application Stuck in Progressing

```bash
# Check app events
argocd app get <app> --show-operation

# Check pod status
kubectl get pods -n <namespace>
kubectl describe pod <pod> -n <namespace>
```

### Sync Failed

```bash
# View sync details
argocd app sync <app> --dry-run

# Force sync
argocd app sync <app> --force
```

### Repository Connection Failed

```bash
# Test repository access
argocd repo list

# Re-add with correct credentials
argocd repo rm <url>
argocd repo add <url> --username <user> --password <token>
```

---

## Security Hardening

### 11.1 Disable Admin Account

```bash
argocd account update-password
# Then disable in argocd-cm:
kubectl patch configmap argocd-cm -n argocd --patch '{"data":{"admin.enabled":"false"}}'
```

### 11.2 Enable RBAC

```yaml
# argocd-rbac-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.csv: |
    p, role:developer, applications, get, */*, allow
    p, role:developer, applications, sync, */*, allow
    g, developers, role:developer
  policy.default: role:readonly
```

### 11.3 SSO Integration

```yaml
# argocd-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.example.com
  dex.config: |
    connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: $dex.github.clientID
          clientSecret: $dex.github.clientSecret
          orgs:
            - name: your-org
```

---

## Quick Start Checklist

- [ ] ArgoCD installed in cluster
- [ ] Admin password retrieved
- [ ] ArgoCD CLI installed
- [ ] Git repository created
- [ ] Repository added to ArgoCD
- [ ] First application created
- [ ] Auto-sync enabled
- [ ] Notifications configured (optional)
- [ ] RBAC configured (production)
