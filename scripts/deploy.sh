#!/usr/bin/env bash
# build the amd64 image, side-load it into the node's containerd (no registry), apply the manifests.
# run locally from anywhere: scripts/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=${IMAGE:-ktor-poc:0.1.0}
IP=${IP:-$(terraform -chdir=infra output -raw public_ip)}
KEY=${KEY:-infra/ktor-poc.pem}
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "ec2-user@$IP")

echo "==> building $IMAGE for linux/amd64"
docker build --platform linux/amd64 -t "$IMAGE" app

echo "==> importing $IMAGE into k3s containerd on $IP"
docker save "$IMAGE" | gzip | "${SSH[@]}" 'gunzip | sudo k3s ctr -n k8s.io images import -'

# credentials live only in a git-ignored env file; postgres keeps the first password it initialises with
ENV_FILE=k8s/postgres.env
if [ ! -f "$ENV_FILE" ]; then
  echo "==> generating $ENV_FILE"
  umask 077
  printf 'POSTGRES_DB=ktor\nPOSTGRES_USER=ktor\nPOSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 24)" > "$ENV_FILE"
fi

echo "==> creating postgres-credentials secret"
"${SSH[@]}" 'kubectl create namespace ktor-poc --dry-run=client -o yaml | kubectl apply -f - >/dev/null &&
  kubectl -n ktor-poc create secret generic postgres-credentials --from-env-file=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -' < "$ENV_FILE"

echo "==> applying manifests"
"${SSH[@]}" 'kubectl apply -f -' < k8s/k8s-manifests.yaml

# the tag is reused, so restart to pick up the freshly imported image
echo "==> rolling out"
"${SSH[@]}" 'kubectl -n ktor-poc rollout restart deploy/ktor && kubectl -n ktor-poc rollout status deploy/ktor --timeout=600s'
"${SSH[@]}" 'kubectl -n ktor-poc get pods,svc,gateway,httproute'
