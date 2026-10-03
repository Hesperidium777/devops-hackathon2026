.PHONY: deploy verify destroy

deploy:
kubectl apply -f manifests/
kubectl apply -f metallb/
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.0.2 -n envoy-gateway-system --create-namespace
helm upgrade --install metallb metallb/metallb -n metallb-system --create-namespace
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace -f helm/monitoring-values.yaml
helm upgrade --install loki grafana/loki-stack -n monitoring -f helm/loki-values.yaml

verify:
kubectl get nodes
kubectl get gatewayclass
kubectl get gateway
kubectl get httproute
curl -s http://192.168.1.240

destroy:
kubectl delete -f manifests/ --ignore-not-found
helm uninstall loki -n monitoring --ignore-not-found
helm uninstall monitoring -n monitoring --ignore-not-found
helm uninstall metallb -n metallb-system --ignore-not-found
helm uninstall eg -n envoy-gateway-system --ignore-not-found
