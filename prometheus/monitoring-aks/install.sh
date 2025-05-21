#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Installing monitoring for BeStrong API ===${NC}"

# Check connection to the cluster
echo -e "${YELLOW}Checking connection to the cluster...${NC}"
kubectl get nodes || { echo "Error: No connection to the cluster"; exit 1; }

# Get information about available Ingress classes
echo -e "${YELLOW}Checking available IngressClasses...${NC}"
kubectl get ingressclass

# Ask user to select the correct IngressClass
echo -e "${YELLOW}Enter IngressClass name (default: nginx):${NC}"
read INGRESS_CLASS_NAME
INGRESS_CLASS_NAME=${INGRESS_CLASS_NAME:-nginx}
echo -e "${GREEN}Using IngressClass: ${INGRESS_CLASS_NAME}${NC}"

# Create alert rules file
echo -e "${YELLOW}Creating alert rules file...${NC}"
cat > bestrong-alerts.yaml << EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: bestrong-api-alerts
  namespace: monitoring
  labels:
    release: prometheus
spec:
  groups:
  - name: bestrong.rules
    rules:
    - alert: BeStrongHighCPUUsage
      expr: sum(rate(container_cpu_usage_seconds_total{container="bestrong-api"}[5m])) / sum(container_spec_cpu_quota{container="bestrong-api"} / container_spec_cpu_period{container="bestrong-api"}) * 100 > 70
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "BeStrong API High CPU Usage"
        description: "BeStrong API is using more than 70% CPU for 5 minutes"
        
    - alert: BeStrongHighMemoryUsage
      expr: sum(container_memory_working_set_bytes{container="bestrong-api"}) / sum(container_spec_memory_limit_bytes{container="bestrong-api"}) * 100 > 70
      for: 5m
      labels:
        severity: warning
      annotations:
        summary: "BeStrong API High Memory Usage"
        description: "BeStrong API is using more than 70% memory for 5 minutes"

  - name: kubecost.rules
    rules:
    - alert: HighDailyCost
      expr: kubecost_cluster_cost_daily > 0.01
      for: 1m
      labels:
        severity: warning
      annotations:
        summary: "High daily cost detected"
        description: "The current estimated daily cost is above $0.01."
EOF

# Create AlertManager configuration for Discord integration
echo -e "${YELLOW}Creating AlertManager configuration...${NC}"
cat > alertmanager-config.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-prometheus-kube-prometheus-alertmanager
  namespace: monitoring
stringData:
  alertmanager.yaml: |-
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'job']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'discord'
      routes:
      - match:
          severity: warning
        receiver: 'discord'
    receivers:
    - name: 'discord'
      webhook_configs:
      - url: 'https://discord.com/api/webhooks/1373711717019680879/1nWgfM6RxL_eDuCdHvx9ZDv7t5lIOQq6pi1gJcubaZqMJ88tctE1DRLdgBQNa5TU3RYM'
        send_resolved: true
type: Opaque
EOF

# Create Discord proxy for AlertManager
echo -e "${YELLOW}Creating Discord proxy configuration...${NC}"
cat > prometheus-discord.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: prometheus-discord
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: prometheus-discord
  template:
    metadata:
      labels:
        app: prometheus-discord
    spec:
      containers:
      - name: prometheus-discord
        image: benjojo/alertmanager-discord
        ports:
        - containerPort: 9094
        env:
        - name: DISCORD_WEBHOOK
          value: "https://discord.com/api/webhooks/1373711717019680879/1nWgfM6RxL_eDuCdHvx9ZDv7t5lIOQq6pi1gJcubaZqMJ88tctE1DRLdgBQNa5TU3RYM"
---
apiVersion: v1
kind: Service
metadata:
  name: prometheus-discord
  namespace: monitoring
spec:
  selector:
    app: prometheus-discord
  ports:
  - port: 9094
    targetPort: 9094
EOF

# Create AlertManager config with Discord proxy
echo -e "${YELLOW}Creating AlertManager Discord proxy configuration...${NC}"
cat > alertmanager-discord-proxy.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-discord-proxy
  namespace: monitoring
stringData:
  alertmanager.yaml: |-
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'job']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: 'discord'
      routes:
      - match:
          severity: warning
        receiver: 'discord'
    receivers:
    - name: 'discord'
      webhook_configs:
      - url: 'http://prometheus-discord:9094/alertmanager'
        send_resolved: true
type: Opaque
EOF

# Use fixed IP address
INGRESS_IP="108.141.93.187"
echo -e "${GREEN}Using IP address: ${INGRESS_IP}${NC}"

# Create values-prometheus.yaml with AlertManagerConfig CRD enabled
echo -e "${YELLOW}Creating Prometheus values file...${NC}"
cat > values-prometheus.yaml << EOF
prometheus:
  prometheusSpec:
    retention: 15d
    resources:
      requests:
        memory: 400Mi
        cpu: 300m
      limits:
        memory: 800Mi
        cpu: 500m
    additionalScrapeConfigs:
      - job_name: 'bestrong-api'
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app]
            regex: bestrong-api
            action: keep
      - job_name: 'kubecost'
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - kubecost
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app]
            regex: cost-analyzer
            action: keep
        metric_relabel_configs:
          - source_labels: [__name__]
            regex: kubecost_.*
            action: keep
    ruleSelector:
      matchLabels:
        release: prometheus

grafana:
  enabled: true
  ingress:
    enabled: true
    ingressClassName: ${INGRESS_CLASS_NAME}
    annotations:
      cert-manager.io/cluster-issuer: "selfsigned-issuer"
    hosts:
      - "grafana.${INGRESS_IP}.nip.io"
    tls:
      - secretName: grafana-tls
        hosts:
          - "grafana.${INGRESS_IP}.nip.io"

alertmanager:
  enabled: true
  config: {}
EOF

# Create ServiceMonitor for Kubecost
echo -e "${YELLOW}Creating ServiceMonitor for Kubecost...${NC}"
cat > kubecost-servicemonitor.yaml << EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kubecost-monitor
  namespace: monitoring
  labels:
    release: prometheus
spec:
  selector:
    matchLabels:
      app: cost-analyzer
  namespaceSelector:
    matchNames:
      - kubecost
  endpoints:
    - port: http-server
      interval: 30s
EOF

# Install cert-manager
echo -e "${YELLOW}Installing cert-manager...${NC}"
helm repo add jetstack https://charts.jetstack.io
helm repo update
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.1/cert-manager.crds.yaml
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.13.1

# Wait for cert-manager to start
echo -e "${YELLOW}Waiting for cert-manager to start...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=available --timeout=300s deployment/cert-manager-webhook -n cert-manager

# Create ClusterIssuer
echo -e "${YELLOW}Creating ClusterIssuer...${NC}"
kubectl apply -f cluster-issuer.yaml

# Update prometheus-ingress.yaml with the correct ingress controller class and IP address
cat > prometheus-ingress.yaml << EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: prometheus-ingress
  namespace: monitoring
  annotations:
    cert-manager.io/cluster-issuer: selfsigned-issuer
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
  - host: "prometheus.${INGRESS_IP}.nip.io"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: prometheus-kube-prometheus-prometheus
            port:
              number: 9090
  tls:
  - hosts:
    - "prometheus.${INGRESS_IP}.nip.io"
    secretName: prometheus-tls
EOF

# Create namespace for monitoring
echo -e "${YELLOW}Creating monitoring namespace...${NC}"
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Generate secure password for Grafana
GRAFANA_PASSWORD=$(openssl rand -base64 20)
echo -e "${GREEN}Grafana password: ${GRAFANA_PASSWORD}${NC}"
echo "Save this password in a secure location!"

# Apply ServiceMonitor for Kubecost
echo -e "${YELLOW}Applying ServiceMonitor for Kubecost...${NC}"
kubectl apply -f kubecost-servicemonitor.yaml

# Install Prometheus and Grafana
echo -e "${YELLOW}Installing Prometheus and Grafana...${NC}"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword="$GRAFANA_PASSWORD" \
  --values values-prometheus.yaml

# Wait for Prometheus and Grafana to start
echo -e "${YELLOW}Waiting for Prometheus and Grafana to start...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/prometheus-grafana -n monitoring
kubectl wait --for=condition=available --timeout=300s deployment/prometheus-kube-state-metrics -n monitoring

# Apply alert rules
echo -e "${YELLOW}Applying alert rules...${NC}"
kubectl apply -f bestrong-alerts.yaml

# Apply AlertManager configuration
echo -e "${YELLOW}Applying AlertManager configuration...${NC}"
kubectl apply -f alertmanager-config.yaml

# Deploy Discord proxy
echo -e "${YELLOW}Deploying Discord proxy...${NC}"
kubectl apply -f prometheus-discord.yaml

# Apply AlertManager Discord proxy configuration
echo -e "${YELLOW}Applying AlertManager Discord proxy configuration...${NC}"
kubectl apply -f alertmanager-discord-proxy.yaml

# Restart AlertManager to apply new configuration
echo -e "${YELLOW}Restarting AlertManager to apply new configuration...${NC}"
kubectl rollout restart statefulset alertmanager-prometheus-kube-prometheus-alertmanager -n monitoring

# Create Ingress for Prometheus
echo -e "${YELLOW}Creating Ingress for Prometheus...${NC}"
kubectl apply -f prometheus-ingress.yaml

# Output access URLs
echo -e "${GREEN}=== Installation complete ====${NC}"
echo -e "${GREEN}Grafana URL: https://grafana.${INGRESS_IP}.nip.io${NC}"
echo -e "${GREEN}Login: admin${NC}"
echo -e "${GREEN}Password: ${GRAFANA_PASSWORD}${NC}"
echo -e "${GREEN}Prometheus URL: https://prometheus.${INGRESS_IP}.nip.io${NC}"
echo -e "${GREEN}Kubecost URL: http://localhost:9090${NC} (Run 'kubectl port-forward -n kubecost svc/kubecost-cost-analyzer 9090:9090' for access)"

echo -e "${YELLOW}Note: Certificate generation may take some time.${NC}"
echo -e "${YELLOW}Check status: kubectl get certificates -n monitoring${NC}"
echo -e "${YELLOW}Check alerts status: kubectl get prometheusrules -n monitoring${NC}"
echo -e "${YELLOW}Check AlertManager config: kubectl get secret alertmanager-prometheus-kube-prometheus-alertmanager -n monitoring${NC}"
echo -e "${YELLOW}Check if Kubecost metrics are collected: kubectl port-forward -n monitoring svc/prometheus-kube-prometheus-prometheus 9090:9090 and search for 'kubecost_cluster_cost_daily'${NC}"