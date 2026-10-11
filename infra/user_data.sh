#!/bin/bash
# rendered by terraform templatefile(); bash variables avoid the brace form on purpose
set -euxo pipefail
exec > >(tee -a /var/log/user-data.log) 2>&1

SWAPFILE=/swapfile
SWAP_GB=${swap_size_gb}

# swapfile on the 30 GB root volume: headroom for k3s, postgres and the jvm on 1 GB of ram
if ! swapon --show=NAME --noheadings | grep -qx "$SWAPFILE"; then
  if [ ! -f "$SWAPFILE" ]; then
    fallocate -l "$SWAP_GB"G "$SWAPFILE" || dd if=/dev/zero of="$SWAPFILE" bs=1M count=$((SWAP_GB * 1024))
  fi
  chmod 600 "$SWAPFILE"
  mkswap "$SWAPFILE"
  swapon "$SWAPFILE"
fi
grep -q "^$SWAPFILE " /etc/fstab || echo "$SWAPFILE none swap sw 0 0" >> /etc/fstab

# moderate swappiness keeps hot pages in ram; unprivileged port start lets non-root envoy bind 80/443 on the host network
cat > /etc/sysctl.d/99-ktor-poc.conf <<'SYSCTL'
vm.swappiness = 30
vm.vfs_cache_pressure = 50
net.ipv4.ip_unprivileged_port_start = 0
SYSCTL
sysctl --system

# hostPath target for postgres data
mkdir -p /var/lib/ktor-poc/postgres

dnf install -y -q openssl tar

swapon --show
free -m
echo "user-data done"
