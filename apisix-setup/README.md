# APISIX API Gateway Productive Setup on Kubernetes

## Prerequisites
- Kubernetes v1.19+
- Helm 3.x
- kubectl

## 1. Monitoring Stack (Prometheus + Grafana)
```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install -n monitoring prometheus prometheus-community/kube-prometheus-stack --create-namespace
```
Grafana: `kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80`
Password: `kubectl -n monitoring get secrets prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo`

## 2. Add APISIX Helm Repo
```bash
helm repo add apisix https://charts.apiseven.com
helm repo update
```

## 3. Deploy APISIX (Single Node, Secure)
```bash
helm upgrade --install apisix apisix/apisix \
  --create-namespace \
  --namespace apisix \
  --set replicaCount=1 \
  --set etcd.replicaCount=1 \
  --set dashboard.enabled=true \
  --set ingress-controller.enabled=true \
  --set ingress-controller.config.apisix.serviceNamespace=apisix \
  --set rbac.create=true \
  --set serviceAccount.create=true \
  --set metrics.serviceMonitor.enabled=true \
  --set apisix.admin.credentials.admin=YOUR_ADMIN_KEY \
  --set apisix.admin.credentials.viewer=YOUR_VIEWER_KEY \
  --set apisix.admin.allow.ipList='{127.0.0.1/24,10.0.0.0/8}' \
  --set service.type=LoadBalancer
```

## 4. Verify
```bash
kubectl get pods -n apisix
kubectl get svc -n apisix
```

## 5. Expose Dashboard
```bash
kubectl expose deployment apisix-dashboard \
  --type=LoadBalancer \
  --name=apisix-dashboard-lb \
  --port=80 \
  --target-port=9000 \
  -n apisix
kubectl get svc apisix-dashboard-lb -n apisix
```

## 6. Enable SSL/TLS
```bash
helm upgrade apisix apisix/apisix \
  -n apisix \
  --set apisix.ssl.enabled=true \
  --set apisix.ssl.sslProtocols="TLSv1.2 TLSv1.3"
```

## 7. Scale for HA
```bash
helm upgrade apisix apisix/apisix \
  -n apisix \
  --set replicaCount=3 \
  --set etcd.replicaCount=3 \
  --set podDisruptionBudget.enabled=true
```

## 8. Enable Autoscaling
```bash
helm upgrade apisix apisix/apisix \
  -n apisix \
  --set autoscaling.enabled=true \
  --set autoscaling.minReplicas=1 \
  --set autoscaling.maxReplicas=10 \
  --set autoscaling.targetCPUUtilizationPercentage=80
```

## 9. Load Balancer Config
```bash
helm upgrade apisix apisix/apisix \
  -n apisix \
  --set service.type=LoadBalancer \
  --set service.externalTrafficPolicy=Local
```

## 10. Troubleshooting
- Dashboard pod Completed: normal, use LoadBalancer svc
- ServiceMonitor CRD missing: install Prometheus Operator first
- SSL: check cert validity and pod mounts
- Performance: monitor, scale, or adjust resources

## 11. Security Checklist
- Change all default passwords/keys
- Enable SSL/TLS
- Set RBAC
- Set resource limits
- Enable PodDisruptionBudget
- Backup etcd
- Set up log aggregation
- Configure network policies
- Enable audit logging

---
This is a minimal, productive APISIX setup for Kubernetes. Scale and harden as needed for production.
