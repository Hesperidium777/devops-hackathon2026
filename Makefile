# DevOps Hackathon 2026 — Makefile
# Все команды идемпотентны: повторный запуск не ломает систему.

SHELL := /bin/bash

# ────────────────────────────────────────────────────────────────
# Параметры — ИЗМЕНИТЕ под свою ВМ перед запуском
# ────────────────────────────────────────────────────────────────
NODE_IP         ?= 192.168.1.6
GATEWAY_IP      ?= 192.168.1.240
GRAFANA_PORT    ?= 30300
PROMETHEUS_PORT ?= 30900
GRAFANA_PASS    ?= admin

# Namespaces
NS_EG      := envoy-gateway-system
NS_MLB     := metallb-system
NS_MON     := monitoring

.PHONY: help deploy deploy-eg deploy-metallb deploy-monitoring \
        deploy-loki deploy-promtail deploy-manifests restart-grafana \
        alias verify verify-gateway verify-app verify-monitoring \
        destroy destroy-monitoring destroy-metallb destroy-eg destroy-manifests \
        rollout-status

# ────────────────────────────────────────────────────────────────
# Help
# ────────────────────────────────────────────────────────────────
help:
	@echo "Цели:"
	@echo "  make deploy     — развернуть всё решение"
	@echo "  make verify     — проверить работоспособность"
	@echo "  make destroy    — удалить решение"
	@echo ""
	@echo "Переменные (можно переопределить):"
	@echo "  NODE_IP         = $(NODE_IP)"
	@echo "  GATEWAY_IP      = $(GATEWAY_IP)"
	@echo "  GRAFANA_PORT    = $(GRAFANA_PORT)"
	@echo "  PROMETHEUS_PORT = $(PROMETHEUS_PORT)"
	@echo "  GRAFANA_PASS    = $(GRAFANA_PASS)"

# ────────────────────────────────────────────────────────────────
# Deploy
# ────────────────────────────────────────────────────────────────
deploy: deploy-eg deploy-metallb deploy-monitoring deploy-loki deploy-promtail deploy-manifests restart-grafana alias
	@echo ""
	@echo "✅ Развёртывание завершено."
	@echo "   Приложение: http://$(GATEWAY_IP)"
	@echo "   Grafana:    http://$(NODE_IP):$(GRAFANA_PORT)  (admin / $(GRAFANA_PASS))"
	@echo "   Prometheus: http://$(NODE_IP):$(PROMETHEUS_PORT)"

deploy-eg:
	@echo "▶ Устанавливаю Envoy Gateway ..."
	helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
	  --version v1.0.2 \
	  -n $(NS_EG) --create-namespace
	kubectl wait --timeout=5m -n $(NS_EG) \
	  deployment/envoy-gateway --for=condition=Available

deploy-metallb:
	@echo "▶ Устанавливаю MetalLB ..."
	helm repo add metallb https://metallb.github.io/metallb --force-update
	helm repo update
	helm upgrade --install metallb metallb/metallb \
	  -n $(NS_MLB) --create-namespace \
	  --set frrk8s.enabled=false
	kubectl wait --timeout=120s -n $(NS_MLB) \
	  deployment/metallb-controller --for=condition=Available || true
	sleep 15
	kubectl apply -f metallb/

deploy-monitoring:
	@echo "▶ Устанавливаю kube-prometheus-stack ..."
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update
	kubectl create namespace $(NS_MON) --dry-run=client -o yaml | kubectl apply -f -
	helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
	  -n $(NS_MON) \
	  -f helm/monitoring-values.yaml
	# Принудительно NodePort для Prometheus (Helm не всегда меняет тип)
	kubectl patch svc monitoring-kube-prometheus-prometheus -n $(NS_MON) \
	  -p '{"spec":{"type":"NodePort","ports":[{"name":"http-web","port":9090,"targetPort":9090,"nodePort":$(PROMETHEUS_PORT)}]}}' \
	  2>/dev/null || true

deploy-loki:
	@echo "▶ Устанавливаю Loki 3.x ..."
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	helm repo update
	# Удалить StatefulSet, если меняется persistence
	kubectl delete statefulset loki -n $(NS_MON) --ignore-not-found || true
	helm upgrade --install loki grafana/loki \
	  -n $(NS_MON) \
	  -f helm/loki-values.yaml

deploy-promtail:
	@echo "▶ Устанавливаю Promtail ..."
	helm repo add grafana https://grafana.github.io/helm-charts --force-update
	helm repo update
	helm upgrade --install promtail grafana/promtail \
	  -n $(NS_MON) \
	  -f helm/promtail-values.yaml

deploy-manifests:
	@echo "▶ Применяю manifests/ ..."
	sleep 10
	kubectl apply -f manifests/

restart-grafana:
	@echo "▶ Перезапускаю Grafana для применения ConfigMap loki-datasource ..."
	kubectl rollout restart deployment monitoring-grafana -n $(NS_MON) || true
	kubectl rollout status deployment monitoring-grafana -n $(NS_MON) --timeout=120s || true

alias:
	@echo "▶ Добавляю алиас $(GATEWAY_IP)/32 на enp0s3 ..."
	@sudo ip addr show enp0s3 | grep -q "$(GATEWAY_IP)" || \
	  sudo ip addr add $(GATEWAY_IP)/32 dev enp0s3
	@echo "   Проверка: ip addr show enp0s3 | grep $(GATEWAY_IP)"

# ────────────────────────────────────────────────────────────────
# Verify
# ────────────────────────────────────────────────────────────────
verify: verify-gateway verify-app verify-monitoring
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
	@curl -s --max-time 5 http://$(NODE_IP):$(PROMETHEUS_PORT)/-/healthy || echo "❌ недоступен"
	@echo ""
	@echo "=== Grafana ==="
	@curl -sI --max-time 5 http://$(NODE_IP):$(GRAFANA_PORT) | head -1 || echo "❌ недоступна"
	@echo ""
	@echo "=== Datasources ==="
	@curl -s -u admin:$(GRAFANA_PASS) \
	  http://$(NODE_IP):$(GRAFANA_PORT)/api/datasources | \
	  python3 -c "import json,sys; [print(d['name'],d['type']) for d in json.load(sys.stdin)]" 2>/dev/null || \
	  echo "❌ не удалось получить список datasources"
	@echo ""
	@echo "Для проверки логов: Grafana → Explore → Loki → {app=\"nginx\"} (Last 15 minutes)"

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
