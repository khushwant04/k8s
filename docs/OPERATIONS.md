# Operations Guide

## Day-2 Operations Manual

This document covers common operational tasks for the kubeadm Kubernetes cluster.

## Access Management

### SSH Tunnel for kubectl

```bash
# Start tunnel (backgrounded)
bash ~/ssh-keys/start_k8s_tunnel.sh

# Verify tunnel is running
ss -lntp | grep 6443

# Test kubectl
kubectl get nodes
```

### Kill Existing Tunnel

```bash
# Find SSH tunnel process
ps aux | grep "ssh.*6443"

# Kill it
pkill -f "ssh.*6443"
```

### kubeconfig Management

```bash
# Current context
kubectl config current-context

# List all contexts
kubectl config get-contexts

# Switch context
kubectl config use-context kubeadm-single

# View cluster info
kubectl cluster-info
```

## Cluster Health Checks

### Quick Health Check

```bash
# Node status
kubectl get nodes -o wide

# All pods status
kubectl get pods -A

# Component status (deprecated but useful)
kubectl get componentstatuses

# Cluster events (recent issues)
kubectl get events -A --sort-by='.lastTimestamp' | tail -20
```

### Detailed Health Check

```bash
# Control plane pods
kubectl get pods -n kube-system -l tier=control-plane

# CNI status
kubectl get pods -n kube-system -l k8s-app=calico-node

# Ingress status
kubectl get pods -n ingress-nginx

# MetalLB status
kubectl get pods -n metallb-system

# Check node resources
kubectl top nodes
kubectl top pods -A
```

## Common Tasks

### Deploy an Application

```yaml
# example-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
  namespace: default
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: myapp
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "256Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: myapp
spec:
  selector:
    app: myapp
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  annotations:
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
spec:
  ingressClassName: nginx
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 80
```

```bash
kubectl apply -f example-app.yaml
```

### Scale Deployment

```bash
# Scale up
kubectl scale deployment myapp --replicas=5

# Scale down
kubectl scale deployment myapp --replicas=2

# Check rollout
kubectl rollout status deployment/myapp
```

### Update Deployment

```bash
# Update image
kubectl set image deployment/myapp myapp=nginx:1.25

# Check rollout history
kubectl rollout history deployment/myapp

# Rollback
kubectl rollout undo deployment/myapp
kubectl rollout undo deployment/myapp --to-revision=2
```

### Debug Pod Issues

```bash
# Describe pod (events, conditions)
kubectl describe pod <pod-name>

# Pod logs
kubectl logs <pod-name>
kubectl logs <pod-name> -c <container-name>  # multi-container
kubectl logs <pod-name> --previous           # previous instance

# Exec into pod
kubectl exec -it <pod-name> -- /bin/sh

# Port forward for debugging
kubectl port-forward pod/<pod-name> 8080:80
```

## Certificate Management

### Check Certificate Expiry

```bash
# SSH into the cluster
ssh ubuntu@<VM_IP>

# Check all certificates
sudo kubeadm certs check-expiration
```

### Renew Certificates

```bash
# Renew all certificates
sudo kubeadm certs renew all

# Restart control plane components
sudo systemctl restart kubelet

# Update kubeconfig
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
```

## Backup & Recovery

### etcd Backup

```bash
# SSH into control plane node
ssh ubuntu@<VM_IP>

# Create backup
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%F).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify backup
ETCDCTL_API=3 etcdctl snapshot status /backup/etcd-*.db
```

### etcd Restore (Disaster Recovery)

```bash
# Stop kubelet
sudo systemctl stop kubelet

# Move old data
sudo mv /var/lib/etcd /var/lib/etcd.bak

# Restore from snapshot
ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-YYYY-MM-DD.db \
  --data-dir=/var/lib/etcd

# Fix permissions
sudo chown -R etcd:etcd /var/lib/etcd

# Start kubelet
sudo systemctl start kubelet
```

### Backup Kubernetes Resources

```bash
# Backup all resources in a namespace
kubectl get all -n <namespace> -o yaml > namespace-backup.yaml

# Backup specific resources
kubectl get deployments,services,configmaps,secrets -n <namespace> -o yaml > resources.yaml

# Backup cluster-wide resources
kubectl get pv,sc,clusterroles,clusterrolebindings -o yaml > cluster-resources.yaml
```

## Monitoring

### Resource Usage

```bash
# Node resources
kubectl top nodes

# Pod resources
kubectl top pods -A
kubectl top pods -n <namespace>

# Sort by CPU
kubectl top pods -A --sort-by=cpu

# Sort by memory
kubectl top pods -A --sort-by=memory
```

### Logs

```bash
# Control plane logs
kubectl logs -n kube-system -l component=kube-apiserver
kubectl logs -n kube-system -l component=kube-controller-manager
kubectl logs -n kube-system -l component=kube-scheduler

# Ingress logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller

# Follow logs
kubectl logs -f <pod-name>

# Logs with timestamps
kubectl logs --timestamps <pod-name>
```

## Networking Operations

### Check Services

```bash
# List all services
kubectl get svc -A

# Get service endpoints
kubectl get endpoints <service-name>

# Check LoadBalancer IPs
kubectl get svc -A -o wide | grep LoadBalancer
```

### Check Ingress

```bash
# List all ingresses
kubectl get ingress -A

# Describe ingress
kubectl describe ingress <ingress-name>

# Check ingress controller logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=100
```

### DNS Debugging

```bash
# Run a debug pod
kubectl run dnsutils --image=registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3 --rm -it -- bash

# Inside the pod
nslookup kubernetes.default
nslookup <service-name>.<namespace>.svc.cluster.local
```

## Maintenance Operations

### Drain Node (for maintenance)

```bash
# Drain node (evict pods)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# Perform maintenance...

# Uncordon node (allow scheduling again)
kubectl uncordon <node-name>
```

### Cordon Node (prevent new pods)

```bash
# Cordon (no new pods)
kubectl cordon <node-name>

# Uncordon
kubectl uncordon <node-name>
```

### Restart Control Plane Components

```bash
# SSH into node
ssh ubuntu@<VM_IP>

# Restart kubelet (restarts all static pods)
sudo systemctl restart kubelet

# Or move and restore manifests (more surgical)
sudo mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
sudo mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

## Troubleshooting Workflows

### Pod Not Starting

```bash
# 1. Check pod status
kubectl get pod <pod-name> -o wide

# 2. Describe pod (look at Events)
kubectl describe pod <pod-name>

# 3. Common issues:
#    - ImagePullBackOff: Check image name, registry auth
#    - Pending: Check resource constraints, node selectors
#    - CrashLoopBackOff: Check logs, command/args
```

### Service Not Reachable

```bash
# 1. Check service exists
kubectl get svc <service-name>

# 2. Check endpoints
kubectl get endpoints <service-name>

# 3. Check pod labels match selector
kubectl get pods -l <selector-from-service>

# 4. Test from within cluster
kubectl run curl --rm -it --image=curlimages/curl -- curl http://<service-name>
```

### Node Not Ready

```bash
# 1. Check node status
kubectl describe node <node-name>

# 2. SSH into node
ssh ubuntu@<node-ip>

# 3. Check kubelet
sudo systemctl status kubelet
sudo journalctl -u kubelet -f

# 4. Check containerd
sudo systemctl status containerd
sudo crictl ps

# 5. Check disk space
df -h

# 6. Check memory
free -h
```

## Runbook: Common Scenarios

### Scenario 1: High Memory Usage

```bash
# Find memory-hungry pods
kubectl top pods -A --sort-by=memory | head -20

# Check for OOMKilled
kubectl get pods -A -o json | jq '.items[] | select(.status.containerStatuses[]?.lastState.terminated.reason == "OOMKilled") | .metadata.name'

# Solution: Increase limits or scale out
kubectl edit deployment <deployment-name>
```

### Scenario 2: etcd Disk Full

```bash
# Check etcd data size
sudo du -sh /var/lib/etcd

# Compact etcd
ETCDCTL_API=3 etcdctl compact $(ETCDCTL_API=3 etcdctl endpoint status --write-out="json" | jq -r '.revision')

# Defragment
ETCDCTL_API=3 etcdctl defrag
```

### Scenario 3: Certificate Expired

```bash
# Check which cert expired
sudo kubeadm certs check-expiration

# Renew all
sudo kubeadm certs renew all

# Restart kubelet
sudo systemctl restart kubelet

# Re-copy admin.conf
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
```
