# Architecture Documentation

## Overview

This document describes the architecture of the kubeadm-based Kubernetes cluster.

## Component Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              k8s-single (VM)                                 │
│                           Ubuntu 22.04 LTS                                   │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                       Control Plane Components                       │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │                                                                       │    │
│  │  ┌─────────────┐  ┌──────────────────┐  ┌─────────────────────┐     │    │
│  │  │ kube-api    │  │ kube-controller  │  │ kube-scheduler      │     │    │
│  │  │ server      │  │ manager          │  │                     │     │    │
│  │  │ :6443       │  │                  │  │                     │     │    │
│  │  └─────────────┘  └──────────────────┘  └─────────────────────┘     │    │
│  │                                                                       │    │
│  │  ┌─────────────────────────────────────────────────────────────┐     │    │
│  │  │                         etcd                                  │     │    │
│  │  │                    (stacked, single node)                    │     │    │
│  │  │                         :2379                                 │     │    │
│  │  └─────────────────────────────────────────────────────────────┘     │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                        Node Components                               │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │                                                                       │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐      │    │
│  │  │ kubelet     │  │ containerd  │  │ kube-proxy              │      │    │
│  │  │             │  │ (runtime)   │  │                         │      │    │
│  │  └─────────────┘  └─────────────┘  └─────────────────────────┘      │    │
│  │                                                                       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                        Networking Stack                              │    │
│  ├─────────────────────────────────────────────────────────────────────┤    │
│  │                                                                       │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐      │    │
│  │  │ Calico      │  │ MetalLB     │  │ ingress-nginx           │      │    │
│  │  │ CNI         │  │ L2 mode     │  │ controller              │      │    │
│  │  │             │  │             │  │                         │      │    │
│  │  │ Pod Network │  │ LoadBalancer│  │ L7 Routing              │      │    │
│  │  │ Policies    │  │ IPs         │  │ TLS Termination         │      │    │
│  │  └─────────────┘  └─────────────┘  └─────────────────────────┘      │    │
│  │                                                                       │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Network Architecture

### IP Addressing

| Network | CIDR | Purpose |
|---------|------|---------|
| Node Network | 10.0.0.0/16 | VM/Node IPs |
| Pod Network | 192.168.0.0/16 | Pod IPs (Calico) |
| Service Network | 10.96.0.0/12 | ClusterIP services |
| LoadBalancer Pool | 10.0.0.200-210 | MetalLB external IPs |

### Traffic Flow

```
                    External Request
                           │
                           ▼
              ┌────────────────────────┐
              │  MetalLB VIP           │
              │  10.0.0.200            │
              └────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │  ingress-nginx         │
              │  (L7 routing)          │
              │  - TLS termination     │
              │  - Host-based routing  │
              │  - Path-based routing  │
              └────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │  ClusterIP Service     │
              │  (kube-proxy iptables) │
              └────────────────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │  Pod (application)     │
              │  192.168.x.x           │
              └────────────────────────┘
```

## Component Details

### Control Plane

#### kube-apiserver
- **Port**: 6443 (HTTPS)
- **Authentication**: X.509 client certificates
- **Authorization**: RBAC
- **Admission**: PodSecurity, ValidatingWebhook, MutatingWebhook

#### kube-controller-manager
- Manages controller loops
- Handles node lifecycle
- Manages service accounts

#### kube-scheduler
- Pod scheduling decisions
- Resource-aware placement
- Topology spread constraints

#### etcd
- **Mode**: Stacked (embedded with control plane)
- **Port**: 2379 (client), 2380 (peer)
- **Data**: /var/lib/etcd
- **⚠️ Limitation**: Single instance, no quorum

### Node Components

#### kubelet
- Node agent
- Pod lifecycle management
- Container runtime interface (CRI)
- CSI volume mounting

#### containerd
- Container runtime
- **Cgroup driver**: systemd (required for Kubernetes)
- Image pulling and storage

#### kube-proxy
- **Mode**: iptables
- Service load balancing
- ClusterIP → Pod routing

### Networking Add-ons

#### Calico CNI
- **Version**: v3.27.0
- **Features**:
  - Pod networking (IPIP or VXLAN)
  - NetworkPolicy enforcement
  - BGP peering (optional)

#### MetalLB
- **Version**: v0.14.5
- **Mode**: L2 (Layer 2)
- **Purpose**: Provides LoadBalancer IPs on bare-metal/VMs
- **⚠️ Limitation**: Not compatible with cloud networking (AWS VPC)

#### ingress-nginx
- **Type**: Kubernetes Ingress Controller
- **Features**:
  - Host-based routing
  - Path-based routing
  - TLS termination
  - ModSecurity WAF
  - Rate limiting

## Storage Architecture

### Current State
- **No persistent storage configured**
- Workloads use emptyDir or hostPath only

### Recommended Additions
For production:
- Local path provisioner (single node)
- NFS (multi-node)
- CSI drivers (cloud/enterprise)

## High Availability Considerations

### Current Limitations (Single Node)

| Component | Limitation | Impact |
|-----------|------------|--------|
| etcd | Single instance | No quorum, data at risk |
| API server | Single instance | SPOF for control plane |
| Control plane | Not redundant | Node failure = cluster down |

### Path to HA (3+ Nodes)

```
                    ┌──────────────────┐
                    │ External LB      │
                    │ (HAProxy/NLB)    │
                    │ VIP: x.x.x.100   │
                    └────────┬─────────┘
                             │
        ┌────────────────────┼────────────────────┐
        │                    │                    │
        ▼                    ▼                    ▼
┌───────────────┐   ┌───────────────┐   ┌───────────────┐
│   cp-1        │   │   cp-2        │   │   cp-3        │
│   etcd        │◄──│   etcd        │──►│   etcd        │
│   api-server  │   │   api-server  │   │   api-server  │
└───────────────┘   └───────────────┘   └───────────────┘
```

## Version Matrix

| Component | Version | Notes |
|-----------|---------|-------|
| Kubernetes | v1.35.0 | LTS recommended |
| containerd | 1.7.x | Distro default |
| Calico | v3.27.0 | Latest stable |
| MetalLB | v0.14.5 | Latest stable |
| ingress-nginx | latest | Main branch |

## Certificate Architecture

### PKI Hierarchy

```
kubernetes-ca (CA)
├── kube-apiserver (server)
├── kube-apiserver-kubelet-client (client)
├── front-proxy-client (client)
└── admin.conf (client, cluster-admin)

etcd-ca (CA)
├── etcd-server (server)
├── etcd-peer (peer)
└── etcd-healthcheck-client (client)

front-proxy-ca (CA)
└── front-proxy-client (client)
```

### Certificate Locations

| Certificate | Path | Purpose |
|-------------|------|---------|
| CA | /etc/kubernetes/pki/ca.crt | Cluster CA |
| API Server | /etc/kubernetes/pki/apiserver.crt | API TLS |
| etcd | /etc/kubernetes/pki/etcd/server.crt | etcd TLS |
| admin.conf | /etc/kubernetes/admin.conf | Admin kubeconfig |

### TLS SANs (API Server)

The API server certificate includes these SANs:
- `10.96.0.1` (kubernetes service IP)
- `10.0.129.132` (node private IP)
- `kubernetes`
- `kubernetes.default`
- `kubernetes.default.svc`
- `kubernetes.default.svc.cluster.local`

**Note**: `127.0.0.1` is NOT included, hence the `--tls-server-name` requirement for SSH tunnel access.
