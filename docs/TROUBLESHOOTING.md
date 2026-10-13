# Troubleshooting Guide

## Common Issues and Solutions

### Connection Issues

#### Issue: kubectl hangs or times out

**Symptoms:**
```
Unable to connect to the server: dial tcp 127.0.0.1:6443: connect: connection refused
```

**Causes & Solutions:**

1. **SSH tunnel not running**
   ```bash
   # Check if tunnel is active
   ss -lntp | grep 6443
   
   # Start tunnel
   bash ~/ssh-keys/start_k8s_tunnel.sh
   ```

2. **Tunnel process died**
   ```bash
   # Kill any stale tunnels
   pkill -f "ssh.*6443"
   
   # Restart
   bash ~/ssh-keys/start_k8s_tunnel.sh
   ```

3. **VM not reachable**
   ```bash
   # Test SSH
   ssh ubuntu@<VM_PUBLIC_IP> "echo connected"
   ```

---

#### Issue: TLS certificate error

**Symptoms:**
```
x509: certificate is valid for 10.96.0.1, 10.0.129.132, not 127.0.0.1
```

**Solution:**
Use `--tls-server-name` flag:
```bash
kubectl --tls-server-name=10.0.129.132 get nodes
```

Or set permanently:
```bash
kubectl config set-cluster kubernetes \
  --server=https://127.0.0.1:6443 \
  --tls-server-name=10.0.129.132
```

---

#### Issue: Permission denied copying kubeconfig

**Symptoms:**
```
scp: remote open "/etc/kubernetes/admin.conf": Permission denied
```

**Solution:**
Use `sudo cat` instead of direct scp:
```bash
ssh ubuntu@<VM_IP> "sudo cat /etc/kubernetes/admin.conf" > ~/kubeadm.conf
```

---

### Installation Issues

#### Issue: APT repository error

**Symptoms:**
```
E: Malformed entry 1 in list file /etc/apt/sources.list.d/kubernetes.list
```

**Solution:**
```bash
# Delete corrupt file
sudo rm -f /etc/apt/sources.list.d/kubernetes.list

# Recreate correctly (single line!)
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update
sudo apt update
```

---

#### Issue: kubeadm init fails

**Symptoms:**
```
[preflight] Running pre-flight checks
error execution phase preflight: [preflight] Some fatal errors occurred
```

**Common causes:**

1. **Swap enabled**
   ```bash
   sudo swapoff -a
   sudo sed -i '/ swap / s/^/#/' /etc/fstab
   ```

2. **Container runtime not running**
   ```bash
   sudo systemctl status containerd
   sudo systemctl restart containerd
   ```

3. **Ports already in use**
   ```bash
   sudo netstat -tlnp | grep -E "6443|2379|2380|10250"
   # Kill conflicting processes if any
   ```

4. **Previous kubeadm run**
   ```bash
   sudo kubeadm reset -f
   sudo rm -rf /etc/cni/net.d
   sudo rm -rf ~/.kube
   ```

---

#### Issue: Calico pods not starting

**Symptoms:**
```
calico-node-xxxxx   0/1     Init:CrashLoopBackOff
```

**Solutions:**

1. **Check CNI configuration**
   ```bash
   kubectl describe pod -n kube-system -l k8s-app=calico-node
   ```

2. **Delete and reinstall**
   ```bash
   kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/calico.yaml
   kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.32.2/manifests/calico.yaml
   ```

---

### MetalLB Issues

#### Issue: Webhook connection refused

**Symptoms:**
```
failed calling webhook "ipaddresspoolvalidationwebhook.metallb.io": connection refused
```

**Cause:** MetalLB webhook not ready yet (timing issue)

**Solution:**
```bash
# Wait for pods to be ready
kubectl get pods -n metallb-system -w

# Once all Running, retry
kubectl apply -f metallb-pool.yaml
```

---

#### Issue: LoadBalancer IP pending

**Symptoms:**
```
service/ingress-nginx-controller   LoadBalancer   <pending>
```

**Solutions:**

1. **Check MetalLB is running**
   ```bash
   kubectl get pods -n metallb-system
   ```

2. **Check IPAddressPool exists**
   ```bash
   kubectl get ipaddresspools -n metallb-system
   ```

3. **Check MetalLB speaker logs**
   ```bash
   kubectl logs -n metallb-system -l app=metallb -c speaker
   ```

---

### Ingress Issues

#### Issue: Ingress returns 404

**Solutions:**

1. **Check ingress class**
   ```bash
   kubectl get ingress <name> -o yaml | grep ingressClassName
   # Should be: nginx
   ```

2. **Check backend service exists**
   ```bash
   kubectl get svc <service-name>
   kubectl get endpoints <service-name>
   ```

3. **Check ingress controller logs**
   ```bash
   kubectl logs -n ingress-nginx -l app.kubernetes.io/component=controller --tail=100
   ```

---

#### Issue: Ingress returns 502 Bad Gateway

**Solutions:**

1. **Backend pods not running**
   ```bash
   kubectl get pods -l app=<your-app>
   ```

2. **Service port mismatch**
   ```bash
   # Check service target port matches container port
   kubectl describe svc <service-name>
   kubectl describe pod <pod-name>
   ```

3. **Pod failing health checks**
   ```bash
   kubectl describe pod <pod-name>
   # Look for Readiness probe failures
   ```

---

### Pod Issues

#### Issue: ImagePullBackOff

**Solutions:**

1. **Check image name**
   ```bash
   kubectl describe pod <pod-name> | grep -A5 "Image:"
   ```

2. **Test image pull manually**
   ```bash
   # On the node
   sudo crictl pull <image-name>
   ```

3. **Private registry - add imagePullSecrets**
   ```bash
   kubectl create secret docker-registry regcred \
     --docker-server=<registry> \
     --docker-username=<user> \
     --docker-password=<pass>
   ```

---

#### Issue: CrashLoopBackOff

**Solutions:**

1. **Check logs**
   ```bash
   kubectl logs <pod-name>
   kubectl logs <pod-name> --previous
   ```

2. **Check command/args**
   ```bash
   kubectl get pod <pod-name> -o yaml | grep -A10 "containers:"
   ```

3. **Check resource limits (OOMKilled)**
   ```bash
   kubectl describe pod <pod-name> | grep -A5 "Last State"
   ```

---

#### Issue: Pod stuck in Pending

**Solutions:**

1. **Check events**
   ```bash
   kubectl describe pod <pod-name>
   # Look at Events section
   ```

2. **Insufficient resources**
   ```bash
   kubectl describe nodes | grep -A10 "Allocated resources"
   ```

3. **Node selector/affinity not matching**
   ```bash
   kubectl get pod <pod-name> -o yaml | grep -A10 "nodeSelector"
   kubectl get nodes --show-labels
   ```

4. **Taints preventing scheduling**
   ```bash
   kubectl describe nodes | grep Taints
   ```

---

### Certificate Issues

#### Issue: Certificate expired

**Symptoms:**
```
x509: certificate has expired or is not yet valid
```

**Solution:**
```bash
# SSH to control plane
ssh ubuntu@<VM_IP>

# Check expiry
sudo kubeadm certs check-expiration

# Renew all
sudo kubeadm certs renew all

# Restart kubelet
sudo systemctl restart kubelet

# Re-copy kubeconfig locally
ssh ubuntu@<VM_IP> "sudo cat /etc/kubernetes/admin.conf" > ~/kubeadm.conf
```

---

### WSL-Specific Issues

#### Issue: chmod +x fails

**Symptoms:**
```
chmod: changing permissions of 'script.sh': Operation not permitted
```

**Cause:** WSL mounted filesystem doesn't support executable bit

**Solutions:**

1. **Run with bash explicitly**
   ```bash
   bash script.sh
   ```

2. **Move to Linux-native path**
   ```bash
   mkdir -p ~/bin
   cp script.sh ~/bin/
   chmod +x ~/bin/script.sh
   ```

---

#### Issue: /etc/hosts changes don't persist

**Cause:** WSL auto-generates /etc/hosts

**Solution:**
```bash
# Edit WSL config
sudo nano /etc/wsl.conf

# Add:
[network]
generateHosts = false

# Restart WSL (from PowerShell)
wsl --shutdown

# Re-add your entries
sudo nano /etc/hosts
```

---

## Diagnostic Commands Cheatsheet

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A

# Events (recent issues)
kubectl get events -A --sort-by='.lastTimestamp' | tail -30

# Resource usage
kubectl top nodes
kubectl top pods -A

# Logs
kubectl logs <pod> -n <namespace>
kubectl logs <pod> -c <container> --previous

# Describe (detailed info)
kubectl describe node <node>
kubectl describe pod <pod>
kubectl describe svc <service>

# Network debugging
kubectl run curl --rm -it --image=curlimages/curl -- curl <url>
kubectl run dns --rm -it --image=busybox -- nslookup <service>

# Control plane (on node)
sudo systemctl status kubelet
sudo journalctl -u kubelet -f
sudo crictl ps
```

---

## ARM64-Specific Issues

### Issue: exec format error

**Symptoms:**
```
standard_init_linux.go:228: exec user process caused: exec format error
```

**Cause:** Container image doesn't support ARM64 architecture

**Solutions:**

1. **Verify image supports ARM64**
   ```bash
   # Check image manifest
   docker manifest inspect <image> | grep arm64
   
   # Or use crane
   crane manifest <image> | jq '.manifests[].platform'
   ```

2. **Use multi-arch images**
   
   | Safe Images | Source |
   |-------------|--------|
   | nginx | Official |
   | hashicorp/* | HashiCorp |
   | bitnami/* | Bitnami |
   | gcr.io/k8s-staging-* | Kubernetes |

3. **Build ARM64 image yourself**
   ```bash
   docker buildx build --platform linux/arm64 -t myimage:arm64 .
   ```

---

### Issue: Image stuck in ImagePullBackOff (ARM)

**Symptoms:**
```
Warning  Failed   Back-off pulling image "someimage:latest"
```

**Diagnosis:**
```bash
# Check if image exists for ARM
kubectl describe pod <pod-name> | grep -A5 "Events"
```

**Solution:** Find ARM-compatible alternative or build multi-arch image

---

### Issue: Verify cluster is running on ARM64

**Command:**
```bash
kubectl describe node | grep Architecture
```

**Expected output:**
```
Architecture: arm64
```

---

### ARM64 Safe Images Reference

| Component | Image | ARM64 Support |
|-----------|-------|---------------|
| Calico | calico/* | ✅ Multi-arch |
| MetalLB | metallb/* | ✅ Multi-arch |
| NGINX Ingress | ingress-nginx/* | ✅ Multi-arch |
| cert-manager | cert-manager/* | ✅ Multi-arch |
| CoreDNS | coredns/coredns | ✅ Multi-arch |
| etcd | etcd-io/etcd | ✅ Multi-arch |

---

## Emergency Recovery

### Full Cluster Reset

```bash
# SSH to node
ssh ubuntu@<VM_IP>

# Reset kubeadm
sudo kubeadm reset -f

# Clean up
sudo rm -rf /etc/cni/net.d
sudo rm -rf ~/.kube
sudo rm -rf /var/lib/etcd

# Restart container runtime
sudo systemctl restart containerd

# Re-run install script (choose based on architecture)
# For x86_64:
./scripts/install-kubeadm.sh

# For ARM64:
./scripts/install-kubeadm-arm64.sh
```
