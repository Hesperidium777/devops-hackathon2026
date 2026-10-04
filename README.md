# DevOps Hackathon 2026 — решение

Развёртывание Nginx в Kubernetes с доступом через Gateway API, мониторингом (Prometheus + Grafana) и сбором логов (Loki + Promtail).

## Стек

| Компонент | Версия |
|---|---|
| Ubuntu Server | 24.04 LTS |
| Kubernetes (kubeadm) | 1.31.x |
| containerd | 1.7+ |
| Calico | 3.28.0 (`ipipMode: Never`, `natOutgoing: true`) |
| Envoy Gateway | 1.0.2 |
| MetalLB | 0.14.x (L2) |
| Nginx | 1.27-alpine |
| kube-prometheus-stack | 91.9.0 |
| Loki | 3.x |
| Promtail | 3.5.1 |
| Helm | 3.x |

## Архитектура

```
Пользователь → MetalLB (192.168.1.240)
             → Envoy Gateway (GatewayClass eg → Gateway my-gateway)
             → HTTPRoute nginx-route
             → Service nginx-svc → Deployment nginx → "Hello World!"

Nginx stdout → Promtail (DaemonSet, /var/log/pods) → Loki → Grafana Explore
Infra        → kube-prometheus-stack → Prometheus (NodePort 30900) → Grafana
```

**Ресурсы Gateway API:** `GatewayClass eg`, `Gateway my-gateway` (listener HTTP :80), `HTTPRoute nginx-route` (PathPrefix `/` → `nginx-svc:80`).

## Требования к среде

- Ubuntu Server 24.04 LTS, 4 vCPU, 8 GB RAM, 60 GB диска
- Bridged Adapter, статический IP (пример: `192.168.1.6`)
- Свободный IP для MetalLB (пример: `192.168.1.240`), вне DHCP-пула роутера
- Отключённый swap, работающий NTP (chrony)
- На хосте **отключён VPN** — иначе браузер не откроет локальные сервисы `192.168.x.x`

> ⚠️ **IP-адреса в примерах — `192.168.1.6` и `192.168.1.240`. Замените их на свои.** IP узла передаётся в `make deploy NODE_IP=...`.

## Установка

### Шаг 1. Подготовка ОС

```bash
sudo apt-get update && sudo apt-get install -y \
  curl gnupg git make chrony \
  conntrack socat ebtables ethtool

sudo swapoff -a && sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo systemctl enable --now chrony
sudo chronyc makestep

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay && sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

**Пакеты `conntrack socat ebtables ethtool` обязательны** — без `conntrack` `kubeadm init` упадёт.

### Шаг 2. containerd

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update && sudo apt-get install -y containerd.io
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml
sudo systemctl restart containerd && sudo systemctl enable containerd
```

### Шаг 3. kubeadm / kubelet / kubectl

```bash
sudo mkdir -p /etc/apt/keyrings

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
sudo chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# ВАЖНО: одной строкой, без переносов
sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null <<'EOF'
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /
EOF

sudo apt-get update && sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

### Шаг 4. Инициализация кластера

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.1.6 \
  --cri-socket=unix:///var/run/containerd/containerd.sock

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
kubectl taint nodes --all node-role.kubernetes.io/control-plane- || true
```

> `--pod-network-cidr` должен быть `10.244.0.0/16`, иначе конфликт с домашней сетью `192.168.1.0/24`.

### Шаг 5. Calico

```bash
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
kubectl wait --for=condition=Ready pods --all -n kube-system --timeout=300s

kubectl patch ippool default-ipv4-ippool --type=merge \
  -p '{"spec":{"ipipMode":"Never","vxlanMode":"Never","natOutgoing":true}}'
kubectl rollout restart daemonset calico-node -n kube-system
kubectl rollout status daemonset calico-node -n kube-system

kubectl get nodes   # Ready
```

### Шаг 6. Helm

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

### Шаг 7. Развёртывание проекта

```bash
make deploy
```

Или с явным IP:

```bash
make deploy NODE_IP=192.168.1.6 GATEWAY_IP=192.168.1.240
```

### Шаг 8. Алиас MetalLB (обход Bridged VirtualBox)

В Bridged-режиме MetalLB не может отвечать на ARP для виртуального IP. Назначьте алиас:

```bash
sudo ip addr add 192.168.1.240/32 dev enp0s3
```

Для фиксации в `netplan` (`/etc/netplan/01-netcfg.yaml`):

```yaml
network:
  version: 2
  ethernets:
    enp0s3:
      dhcp4: no
      addresses: [192.168.1.6/24, 192.168.1.240/32]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```

```bash
sudo chmod 600 /etc/netplan/01-netcfg.yaml && sudo netplan apply
```

## Проверка

### Приложение

```bash
curl http://192.168.1.240        # → Hello World!
kubectl get gateway              # → PROGRAMMED: True, ADDRESS: 192.168.1.240
kubectl get httproute            # → ACCEPTED: True
kubectl get gatewayclass         # → ACCEPTED: True
```

### Мониторинг

| | URL |
|---|---|
| Prometheus | `http://192.168.1.6:30900` |
| Grafana | `http://192.168.1.6:30300` (admin / admin) |

Проверка Prometheus:
```bash
curl http://192.168.1.6:30900/-/healthy
# Prometheus Server is Healthy.
```

Проверка datasources:
```bash
curl -s -u admin:admin http://192.168.1.6:30300/api/datasources | python3 -m json.tool
```
Должны быть три datasource: `Prometheus`, `Alertmanager`, `Loki`.

### Логирование

1. `curl http://192.168.1.240`
2. Grafana → **Explore** → Loki → **Last 15 minutes**.
3. Запрос:
   ```
   {app="nginx"}
   ```
4. Run query.

Должны появиться access-логи Nginx.

## Известные ограничения

1. **MetalLB в Bridged VirtualBox** — ARP не проходит для виртуального IP, используется алиас `192.168.1.240/32` на интерфейсе ВМ.
2. **VPN на хосте должен быть отключён** — иначе браузер не откроет локальные сервисы `192.168.x.x`.
3. **Loki datasource через ConfigMap** — `additionalDataSources` в Helm ломает Grafana (конфликт `only one datasource per organization can be marked as default`). Используется `manifests/loki-datasource.yaml` с `isDefault: false`, подхватывается через `grafana.sidecar.datasources.enabled=true`.
4. **Loki `persistence.enabled: false`** — при SingleBinary-режиме Loki требует writable-том для `/var/loki`. Настроено через `extraVolumes` (emptyDir) + `securityContext.runAsUser: 0`.
5. **Prometheus NodePort** — Helm не всегда меняет тип сервиса с `ClusterIP` на `NodePort` при `helm upgrade`. В `Makefile` добавлен `kubectl patch` для принудительной смены.
6. **`loki-gateway` отключён** — в однонодовом кластере под не планируется из-за anti-affinity. Promtail и Grafana обращаются к Loki напрямую.
7. **`frrk8s` в MetalLB отключён** — не нужен в L2-режиме.
8. **NTP (chrony)** — при сбитом времени Grafana не находит логи в диапазоне. Решение: `chronyc makestep` + перезапуск подов.
9. **Порядок `make deploy`** — Envoy Gateway и monitoring устанавливаются **до** применения `manifests/`, потому что CRD Gateway API появляются только после Envoy Gateway, а namespace `monitoring` — после `kube-prometheus-stack`.

## Структура репозитория

```
.
├── README.md
├── Makefile
├── .gitignore
├── manifests/
│   ├── gatewayclass.yaml
│   ├── gateway.yaml
│   ├── httproute.yaml
│   ├── nginx-configmap.yaml
│   ├── nginx-app.yaml
│   └── loki-datasource.yaml
├── helm/
│   ├── monitoring-values.yaml
│   ├── loki-values.yaml
│   ├── promtail-values.yaml
│   └── metallb-values.yaml
├── metallb/
│   └── ipaddresspool.yaml
└── docs/
    └── passport.pdf
```

## Сдача

- **`Ссылка.txt`** — ссылка на публичный Git-репозиторий.
- **`Паспорт.pdf`** — паспорт решения (≤ 4 страницы).
