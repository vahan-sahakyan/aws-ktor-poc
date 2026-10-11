# Decisions

[<- README](../README.md) · [Architecture](architecture.md) · [Cost](cost.md) · [Memory](memory.md) · **Decisions**

---

| Decision | Why |
|---|---|
| `useListenerPortAsContainerPort: true` + sysctl `ip_unprivileged_port_start=0` | Envoy Gateway otherwise shifts 80 -> 10080; non-root Envoy can then bind 80/443 on the host |
| Envoy Service `ClusterIP` | a `LoadBalancer` Service is what provisions cloud LBs |
| `Recreate` for envoy, ktor, postgres | host ports can't be shared; two JVMs don't fit; one hostPath writer |
| Envoy Gateway requests shrunk (controller 48Mi, proxy 32Mi) | defaults (256Mi + 512Mi) don't schedule on ~900Mi allocatable |
| `gateway-api-crd.yaml.skip` | k3s v1.37 bundles Gateway API CRDs as a HelmChart, which loops on errors with the helm controller off; Envoy Gateway's pinned CRDs stay the only copy |
| hostPath at `/var/lib/postgresql` | Postgres 18 keeps PGDATA at `/var/lib/postgresql/18/docker` |
| `-Xmx320m` + off-heap caps | `-Xmx384m` overshoots a 512Mi limit once off-heap counts |
| Self-signed TLS | no domain; cert-manager costs ~100 MB |
| No registry | images side-loaded with `k3s ctr images import` |
| `ignore_changes = [ami]` | a new AL2023 release must not replace the node and wipe data |
| Taint removal kept, no-op | k3s servers are schedulable; kept explicit for other distros |
