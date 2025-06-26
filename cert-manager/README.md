# 🔐 Setting up HTTPS with cert-manager & Let's Encrypt (Staging & Production)

This guide will help you set up `cert-manager` on Kubernetes to issue TLS certificates from **Let's Encrypt**, using both the **staging** (safe for testing) and **production** (live certs) endpoints.

---

## 📁 Project Structure

```
.
├── nginx-deployment.yaml
├── nginx-service.yaml
├── ingress.yaml
├── issuer-lets-encrypt-staging.yaml
├── issuer-lets-encrypt-production.yaml
└── secret.yaml
```

---

## 🚀 Prerequisites

* A working Kubernetes cluster
* `kubectl` configured
* cert-manager installed

  > Use Helm, Kustomize, or kubectl to install it ([https://cert-manager.io/docs/installation/](https://cert-manager.io/docs/installation/))
* A public DNS record pointing to your LoadBalancer IP (e.g., `api.hexelstudio.com`)
* GKE Ingress controller (for `gce` class) if you're on GCP

---

## ✅ Step-by-Step Setup

---

### 1. Create Namespace

```bash
kubectl create namespace nginx
```

---

### 2. Deploy NGINX

```bash
kubectl apply -f nginx-deployment.yaml
kubectl apply -f nginx-service.yaml
```

---

### 3. Create a Dummy TLS Secret (Optional)

```bash
kubectl apply -f secret.yaml
```

This prevents `cert-manager` from failing on first boot if no secret exists.

---

## ⚙️ Method 1: Using **Staging** Issuer (Safe Testing)

### 🛠 Apply Staging Issuer

```bash
kubectl apply -f issuer-lets-encrypt-staging.yaml
```

### 🌐 Configure Ingress for Staging

Update this annotation:

```yaml
cert-manager.io/issuer: letsencrypt-staging
```

Then apply:

```bash
kubectl apply -f ingress.yaml
```

### ✅ Validate

Check that a TLS certificate is issued successfully:

```bash
kubectl describe certificate web-ssl -n nginx
```

**Staging certs will show a browser warning**, but you can verify setup end-to-end without rate limit concerns.

---

## 🔐 Method 2: Switch to **Production** Issuer (Live Certs)

### ⚠️ Only do this **after staging is successful.**

### 🛠 Apply Production Issuer

```bash
kubectl apply -f issuer-lets-encrypt-production.yaml
```

### 🔄 Update Ingress Annotations

Edit `ingress.yaml`:

```yaml
cert-manager.io/issuer: letsencrypt-production
```

Apply again:

```bash
kubectl apply -f ingress.yaml
```

---

### ✅ Validate

Once again:

```bash
kubectl describe certificate web-ssl -n nginx
```

You should see a valid certificate (not self-signed), and your domain should now serve **HTTPS without browser warnings**.

---

## 📌 YAML Reference

### `issuer-lets-encrypt-staging.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-staging
  namespace: nginx
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: khushwantsanwalot2004@outlook.com
    privateKeySecretRef:
      name: letsencrypt-staging
    solvers:
      - http01:
          ingress:
            name: nginx-ingress
```

### `issuer-lets-encrypt-production.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: letsencrypt-production
  namespace: nginx
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: khushwantsanwalot2004@outlook.com
    privateKeySecretRef:
      name: letsencrypt-production
    solvers:
      - http01:
          ingress:
            name: nginx-ingress
```

### `ingress.yaml`

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-ingress
  namespace: nginx
  annotations:
    kubernetes.io/ingress.class: gce
    kubernetes.io/ingress.allow-http: "true"
    kubernetes.io/ingress.global-static-ip-name: nginx
    cert-manager.io/issuer: letsencrypt-staging # Change to letsencrypt-production when ready
spec:
  tls:
    - secretName: web-ssl
      hosts:
        - api.hexelstudio.com
  defaultBackend:
    service:
      name: nginx-service
      port:
        number: 80
```

---

## 🧠 Pro Tips

* **Staging First, Always:** Avoid Let's Encrypt production rate limits
* **Check Events:** Use `kubectl describe` and `kubectl get events` to debug
* **Ingress Annotations:** Must match your controller (GCE, NGINX, etc.)
* **Static IP:** Recommended for DNS stability

---

## 🧹 Cleanup

To delete everything:

```bash
kubectl delete -f ./
```

---

Let me know if you want:

* A `Makefile` or shell script to automate these steps
* A `Kustomize` variant
* GitHub Actions to deploy from CI/CD

Ready to roll this into a Git repo README?
