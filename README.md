# DevOps Hackathon 2026 — решение

## Архитектура
(описание + схема)

## Технологии и версии
- Ubuntu 24.04 LTS
- Kubernetes 1.31 (kubeadm)
- Calico 3.28 (ipipMode: Never)
- Envoy Gateway 1.0.2
- MetalLB
- kube-prometheus-stack
- Loki + Promtail

## Установка
\`\`\`bash
make deploy
\`\`\`

## Проверка
\`\`\`bash
make verify
\`\`\`
