# Memory

[<- README](../README.md) · [Architecture](architecture.md) · [Cost](cost.md) · **Memory** · [Decisions](decisions.md)

---

OS + k3s + Envoy Gateway + Postgres + JVM exceed 1 GB of RAM. A 4 GB swapfile and kubelet `LimitedSwap` absorb the overflow.

| Component | Request / limit | Measured (1 GiB rehearsal) |
|---|---|---|
| k3s server | - | ~350-400 MiB |
| ktor (JVM) | 128Mi / 512Mi | ~105 MiB |
| envoy-gateway controller | 48Mi / 256Mi | ~85 MiB |
| envoy proxy + shutdown-manager | 48Mi / 160Mi | ~60 MiB |
| postgres 18 | 64Mi / 256Mi | ~60 MiB |
| coredns | 70Mi / 170Mi | ~40 MiB |
| total | ~360Mi | ~740 MiB, + ~150-200 MiB for AL2023 |

## Swap

- Host: `/swapfile` 4 GB from `user_data.sh`, `vm.swappiness=30`
- Pods: kubelet drop-in sets `failSwapOn: false` and `swapBehavior: LimitedSwap` (cgroup v2). Only Burstable pods (request < limit) swap, up to `request / node RAM * swap`, so ktor gets ~0.5 GB on top of its 512Mi limit
- Eviction: `memory.available<50Mi` (default 100Mi), so swap absorbs pressure before pods are evicted

## JVM

`-Xms64m -Xmx320m -XX:+UseSerialGC -XX:MaxMetaspaceSize=96m -XX:ReservedCodeCacheSize=32m -XX:MaxDirectMemorySize=32m -Xss512k -XX:TieredStopAtLevel=1 -XX:-UsePerfData -XX:+ExitOnOutOfMemoryError`

Heap plus off-heap caps stay under 512Mi; C1-only JIT trades peak throughput for less memory and CPU.

## Signs of trouble

- `vmstat 5`: sustained `si`/`so` = thrashing -> `instance_type = "t3.small"`
- `kubectl get events -A | grep -iE 'oom|evict'`
