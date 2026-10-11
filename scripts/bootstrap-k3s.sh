#!/usr/bin/env bash
# phase 3: install k3s tuned for 1 GB + swap, envoy gateway, and a self-signed tls secret.
# run on the node as ec2-user: bash bootstrap-k3s.sh
set -euo pipefail

# pinned: the channel lookup (update.k3s.io) is not reliably reachable, and pinning is reproducible
K3S_VERSION=${K3S_VERSION:-v1.37.1+k3s1}
EG_VERSION=${EG_VERSION:-v1.9.2}
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

imds() {
  local token
  token=$(curl -sf -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
  curl -sf -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}
PUBLIC_IP=${PUBLIC_IP:-$(imds public-ipv4)}

echo "==> checking swap"
swapon --show --noheadings | grep -q . || { echo "no swap active, check /var/log/user-data.log" >&2; exit 1; }
free -m

echo "==> writing k3s config"
sudo mkdir -p /etc/rancher/k3s /var/lib/rancher/k3s/agent/etc/kubelet.conf.d
# kubelet drop-in, applied after k3s' own 00-k3s-defaults.conf:
# let pods use swap (Burstable only) and evict late, since swap absorbs the pressure
sudo tee /var/lib/rancher/k3s/agent/etc/kubelet.conf.d/50-ktor-poc.conf >/dev/null <<'CONF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
failSwapOn: false
memorySwap:
  swapBehavior: LimitedSwap
evictionHard:
  memory.available: "50Mi"
  nodefs.available: "5%"
  imagefs.available: "5%"
CONF
# drop every packaged component we do not need; envoy gateway replaces traefik + servicelb
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'CONF'
write-kubeconfig-mode: "0644"
disable:
  - traefik
  - servicelb
  - local-storage
  - metrics-server
disable-network-policy: true
disable-helm-controller: true
CONF
# recent k3s releases bundle gateway api crds as a HelmChart; envoy gateway ships its own, so skip k3s' copy
sudo mkdir -p /var/lib/rancher/k3s/server/manifests
sudo touch /var/lib/rancher/k3s/server/manifests/gateway-api-crd.yaml.skip

echo "==> installing k3s $K3S_VERSION"
# al2023 runs selinux permissive and has no k3s-selinux package
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" INSTALL_K3S_SKIP_SELINUX_RPM=true sh -
for _ in $(seq 1 100); do kubectl get nodes >/dev/null 2>&1 && break; sleep 3; done
kubectl wait node --all --for=condition=Ready --timeout=300s

echo "==> removing control-plane taints (no-op on k3s, kept explicit)"
kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
kubectl taint nodes --all node-role.kubernetes.io/master:NoSchedule- 2>/dev/null || true
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

echo "==> installing envoy gateway $EG_VERSION"
kubectl apply --server-side --force-conflicts -f "https://github.com/envoyproxy/gateway/releases/download/$EG_VERSION/install.yaml"
# one replica needs no leader election; on a cpu-throttled node lease renewals time out and the controller restarts
cfg=$(mktemp)
kubectl -n envoy-gateway-system get configmap envoy-gateway-config -o jsonpath='{.data.envoy-gateway\.yaml}' \
  | sed '0,/^  kubernetes:$/s//  kubernetes:\n    leaderElection:\n      disable: true/' > "$cfg"
kubectl -n envoy-gateway-system create configmap envoy-gateway-config --from-file=envoy-gateway.yaml="$cfg" \
  --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f -
rm -f "$cfg"
# default requests are 256Mi; shrink so everything schedules on ~900Mi allocatable
kubectl -n envoy-gateway-system set resources deploy/envoy-gateway -c envoy-gateway \
  --requests=cpu=10m,memory=48Mi --limits=memory=256Mi
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=600s

echo "==> creating self-signed tls secret for $PUBLIC_IP"
kubectl create namespace ktor-poc --dry-run=client -o yaml | kubectl apply -f -
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout "$tmp/tls.key" -out "$tmp/tls.crt" \
  -subj "/CN=$PUBLIC_IP" -addext "subjectAltName=IP:$PUBLIC_IP"
kubectl -n ktor-poc create secret tls ktor-poc-tls --cert="$tmp/tls.crt" --key="$tmp/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> done"
kubectl get pods -A
free -m
