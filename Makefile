# DevOps Hackathon 2026  Makefile
# Все команды идемпотентны: повторный запуск не ломает систему.

SHELL := /bin/bash

# Параметры (при необходимости измените)
NODE_IP        := 192.168.1.6
GATEWAY_IP     := 192.168.1.240
GRAFANA_PORT   := 30300
PROMETHEUS_PORT:= 30900
GRAFANA_PASS   := admin

# Namespaces
NS_EG      := envoy-gateway-system
NS_MLB     := metallb-system
NS_MON     := monitoring

.PHONY: help deploy deploy-manifests deploy-eg deploy-metallb \
        deploy-monitoring deploy-loki deploy-promtail restart-grafana \
        verify verify-app verify-gateway verify-monitoring verify-logging \
        destroy destroy-monitoring destroy-eg destroy-metallb destroy-manifests \
        alias ip-address-pool rollout-status

# ────────────────────────────────────────────────────────────────
# Help
# ────────────────────────────────────────────────────────────────
help:
	@echo "Цели:"
	@echo "  make deploy     — развернуть всё решение"
	@echo "  make verify     — проверить работоспособность"
	@echo "  make destroy    — удалить решение"
	@echo ""
	@echo "  make deploy-manifests   — применить manifests/"
	@echo "  make deploy-eg          — установить Envoy Gateway"
	@echo "  make deploy-metallb     — установить MetalLB + IP-пул"
	@echo "  make deploy-monitoring  — установить Prometheus + Grafana"
	@echo "  make deploy-loki        — установить Loki 3.x"
	@echo "  make deploy-promtail    — установить Promtail"
	@echo ""
	@echo "  make alias              — добавить алиас для MetalLB IP"
	@echo "  make rollout-status     — статус всех подов"

# ────────────────────────────────────────────────────────────────
# Deploy
# ────────────────────────────────────────────────────────────────
deploy: deploy-manifests deploy-eg deploy-metallb deploy-monitoring deploy-loki deploy-promtail restart-grafana alias
	@echo ""
	@echo "✅ Развёртывание завершено."
	@echo "   Приложение: http://$(GATEWAY_IP)"
	@echo "   Grafana:    http://$(NODE_IP):$(GRAFANA_PORT)  (admin / $(GRAFANA_PASS))"
	@echo "   Prometheus: http://$(NODE_IP):$(PROMETHEUS_PORT)"

deploy-manifests:
	@echo "▶ Применяю manifests/ ..."
	kubectl apply -f manifests/

deploy-eg:
	@echo "▶ Устанавливаю Envoy Gateway ..."
	helm repo add envoy-gateway https://gateway.envoyproxy.io/ 2>/dev/null || true
	helm repo update
	helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
	  --version v1.0.2 \
	  -n $(NS_EG) --create-namespace
	kubectl wait --timeout=5m -n $(NS_EG) \
	  deployment/envoy-gateway --for=condition=Available

deploy-metallb:
	@echo "▶ Устанавливаю MetalLB ..."
	helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
	helm repo update
	helm upgrade --install metallb metallb/metallb \
	  -n $(NS_MLB) --create-namespace \
	  --set frrk8s.enabled=false
	kubectl apply -f metallb/

deploy-monitoring:
	@echo "▶ Устанавливаю kube-prometheus-stack ..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	helm repo update
	kubectl create namespace $(NS_MON) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
	  -n $(NS_MON) \
	  -f helm/monitoring-values.yaml

deploy-loki:
	@echo "▶ Устанавливаю Loki 3.x ..."
	helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
	helm repo update
	helm upgrade --install loki grafana/loki \
	  -n $(NS_MON) \
	  -f helm/loki-values.yaml

deploy-promtail:
	@echo "▶ Устанавливаю Promtail ..."
	helm upgrade --install promtail grafana/promtail \
	  -n $(NS_MON) \
	  -f helm/promtail-values.yaml

restart-grafana:
	@echo "▶ Перезапускаю Grafana для применения ConfigMap loki-datasource ..."
	kubectl rollout restart deployment monitoring-grafana -n $(NS_MON) || true
	kubectl rollout status deployment monitoring-grafana -n $(NS_MON) --timeout=120s || true

# ────────────────────────────────────────────────────────────────
# Alias для MetalLB (обход Bridged VirtualBox)
# ────────────────────────────────────────────────────────────────
alias:
	@echo "▶ Добавляю алиас $(GATEWAY_IP)/32 на enp0s3 ..."
	@sudo ip addr show enp0s3 | grep -q "$(GATEWAY_IP)" || \
	  sudo ip addr add $(GATEWAY_IP)/32 dev enp0s3
	@echo "   Проверка: ip addr show enp0s3 | grep $(GATEWAY_IP)"

# ────────────────────────────────────────────────────────────────
# Verify
# ────────────────────────────────────────────────────────────────
verify: verify-gateway verify-app verify-monitoring verify-logging
	@echo ""
	@echo "✅ Проверка завершена."

verify-gateway:
	@echo "=== Nodes ==="
	@kubectl get nodes
	@echo ""
	@echo "=== GatewayClass ==="
	@kubectl get gatewayclass
	@echo ""
	@echo "=== Gateway ==="
	@kubectl get gateway
	@echo ""
	@echo "=== HTTPRoute ==="
	@kubectl get httproute

verify-app:
	@echo ""
	@echo "=== Приложение через Gateway ==="
	@curl -s --max-time 5 http://$(GATEWAY_IP) && echo "" || echo "❌ Не удалось получить ответ"

verify-monitoring:
	@echo ""
	@echo "=== Prometheus ==="
	@curl -sI --max-time 5 http://$(NODE_IP):$(PROMETHEUS_PORT) | head -1 || echo "❌ недоступен"
	@echo "=== Grafana ==="
	@curl -sI --max-time 5 http://$(NODE_IP):$(GRAFANA_PORT) | head -1 || echo "❌ недоступна"
	@echo ""
	@echo "=== Datasources ==="
	@curl -s -u admin:$(GRAFANA_PASS) \
	  http://$(NODE_IP):$(GRAFANA_PORT)/api/datasources | \
	  python3 -c "import json,sys; [print(d['name'], d['type']) for d in json.load(sys.stdin)]" 2>/dev/null || \
	  echo "❌ не удалось получить список datasources"

verify-logging:
	@echo ""
	@echo "=== Логи в Loki ==="
	@curl -s --max-time 5 http://$(GATEWAY_IP) > /dev/null || true
	@echo "   Отправлен тестовый запрос к приложению."
	@echo "   Откройте Grafana → Explore → Loki → {app=\"nginx\"} (Last 15 minutes)."

# ────────────────────────────────────────────────────────────────
# Status
# ────────────────────────────────────────────────────────────────
rollout-status:
	@echo "=== Поды не в Running/Completed ==="
	@kubectl get pods -A | grep -vE "Running|Completed" || echo "Все поды Running/Completed"

# ────────────────────────────────────────────────────────────────
# Destroy
# ────────────────────────────────────────────────────────────────
destroy: destroy-manifests destroy-monitoring destroy-metallb destroy-eg
	@echo "✅ Решение удалено."

destroy-manifests:
	kubectl delete -f manifests/ --ignore-not-found=true
	kubectl delete -f metallb/ --ignore-not-found=true

destroy-monitoring:
	helm uninstall promtail -n $(NS_MON) --ignore-not-found || true
	helm uninstall loki     -n $(NS_MON) --ignore-not-found || true
	helm uninstall monitoring -n $(NS_MON) --ignore-not-found || true
	kubectl delete namespace $(NS_MON) --ignore-not-found=true

destroy-metallb:
	helm uninstall metallb -n $(NS_MLB) --ignore-not-found || true
	kubectl delete namespace $(NS_MLB) --ignore-not-found=true

destroy-eg:
	helm uninstall eg -n $(NS_EG) --ignore-not-found || true
	kubectl delete namespace $(NS_EG) --ignore-not-found=true
