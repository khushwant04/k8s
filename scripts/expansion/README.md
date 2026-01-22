# Cluster Expansion Scripts

Scripts for expanding a single-node kubeadm cluster to a multi-node HA configuration.

## Scripts Overview

| Script | Purpose | Run On |
|--------|---------|--------|
| `prepare-node.sh` | Prepare new nodes for joining | New nodes |
| `setup-haproxy.sh` | Install HAProxy load balancer | LB node |
| `generate-join-commands.sh` | Generate join commands | Existing CP |
| `verify-cluster.sh` | Verify cluster health | Any node with kubectl |

## Expansion Workflow

### Phase 1: Setup Load Balancer

On a dedicated LB node (or first control plane):

```bash
# Plan your IPs
# CP1: 10.0.1.10 (existing)
# CP2: 10.0.1.11 (new)
# CP3: 10.0.1.12 (new)

# Install HAProxy
sudo ./setup-haproxy.sh 10.0.1.10 10.0.1.11 10.0.1.12
```

### Phase 2: Prepare New Nodes

On each new node (control plane or worker):

```bash
# Copy script to new node
scp prepare-node.sh ubuntu@<new-node>:~/

# SSH and run
ssh ubuntu@<new-node>
sudo ./prepare-node.sh
```

### Phase 3: Generate Join Commands

On existing control plane:

```bash
# For control plane nodes
sudo ./generate-join-commands.sh --control-plane

# For worker nodes
sudo ./generate-join-commands.sh --worker

# For both
sudo ./generate-join-commands.sh --both
```

### Phase 4: Join Nodes

Run the join command on each new node:

```bash
# Worker nodes
sudo kubeadm join <lb-ip>:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>

# Control plane nodes
sudo kubeadm join <lb-ip>:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane --certificate-key <key>
```

### Phase 5: Verify

```bash
./verify-cluster.sh
```

## Target Architecture

```
                    ┌─────────────────┐
                    │    HAProxy      │
                    │  (LB: :6443)    │
                    └────────┬────────┘
           ┌─────────────────┼─────────────────┐
           ▼                 ▼                 ▼
    ┌─────────────┐   ┌─────────────┐   ┌─────────────┐
    │    CP-1     │   │    CP-2     │   │    CP-3     │
    │ api,etcd,cm │   │ api,etcd,cm │   │ api,etcd,cm │
    └─────────────┘   └─────────────┘   └─────────────┘
           │                 │                 │
           └─────────────────┼─────────────────┘
                             │
              ┌──────────────┴──────────────┐
              ▼                             ▼
       ┌─────────────┐               ┌─────────────┐
       │  Worker-1   │               │  Worker-2   │
       │   kubelet   │               │   kubelet   │
       └─────────────┘               └─────────────┘
```

## Node Requirements

| Role | Min CPU | Min RAM | Disk |
|------|---------|---------|------|
| Control Plane | 2 vCPU | 4 GB | 50 GB |
| Worker | 2 vCPU | 4 GB | 100 GB |
| Load Balancer | 1 vCPU | 1 GB | 20 GB |

## Network Requirements

- All nodes must reach each other on:
  - TCP 6443 (API server)
  - TCP 2379-2380 (etcd)
  - TCP 10250-10252 (kubelet, scheduler, controller)
- Pod network CIDR (default: 192.168.0.0/16)
- Service CIDR (default: 10.96.0.0/12)

## Troubleshooting

### Token Expired

```bash
# Generate new token
sudo kubeadm token create --print-join-command
```

### Certificate Key Expired

Certificate keys expire in 2 hours. Regenerate:

```bash
sudo kubeadm init phase upload-certs --upload-certs
```

### Node NotReady

Check CNI pods:
```bash
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl logs -n kube-system -l k8s-app=calico-node
```

### etcd Issues

Check etcd health:
```bash
kubectl get pods -n kube-system -l component=etcd
kubectl logs -n kube-system <etcd-pod>
```

## Post-Expansion Checklist

- [ ] All nodes Ready
- [ ] All control plane pods running
- [ ] etcd cluster healthy (3 or 5 members)
- [ ] CoreDNS running
- [ ] Calico pods on all nodes
- [ ] kube-proxy on all nodes
- [ ] Ingress controller updated (if using DaemonSet)
- [ ] Update local kubectl config with LB endpoint
