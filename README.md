## Install cost-analyzer via helm charts

```bash
helm install kubecost cost-analyzer \
--repo https://kubecost.github.io/cost-analyzer/ \
--namespace kubecost --create-namespace
```

## Install ingress controller:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.9.4/deploy/static/provider/cloud/deploy.yaml
```

### Change ingress host value in kubecost-ingress.yaml to address of ingress controler EXTERNAL-IP

EX: kubecost.9.163.202.29.nip.io

## Apply kubecost-ingress.yaml to make it accesible

```bash
kubectl apply -f kubecost-ingress.yaml
```

### Kube-cost is avaiable via kubecost.EXTERNAL-IP.nip.io
