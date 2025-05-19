## Install cost-analyzer via helm charts

```bash
helm repo add kubecost https://kubecost.github.io/cost-analyzer
helm install kubecost kubecost/cost-analyzer \
  --namespace kubecost --create-namespace

```

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/cloud/deploy.yaml
```

```bash
kubectl get svc ingress-nginx-controller -n ingress-nginx
```

## Install cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
```

## Apply ClusterIssuer

```bash
kubectl apply -f cluster-issuer.yaml
```

## Install ingress controller:

### Change ingress host value in kubecost-ingress.yaml to address of ingress controler EXTERNAL-IP

EX: kubecost.9.163.202.29.nip.io

## Apply kubecost-ingress.yaml to make it accesible

```bash
kubectl apply -f kubecost-ingress.yaml
```

### Kube-cost is avaiable via kubecost.EXTERNAL-IP.nip.io
