# Architecture

[<- README](../README.md) · **Architecture** · [Cost](cost.md) · [Memory](memory.md) · [Decisions](decisions.md)

---

One EC2 `t3.micro` runs a single-node k3s cluster. Envoy runs on the host network and owns ports 80/443, so there is no cloud load balancer.

```
internet :80/:443 -> SG -> envoy (hostNetwork) -> HTTPRoute -> ktor Service :80 -> ktor :8080 -> postgres Service :5432
                                ^ xDS
                          envoy-gateway controller
```

| Component | Kind | Image / version | Notes |
|---|---|---|---|
| ktor | Deployment, ClusterIP :80 | `ktor-poc:0.1.0` (side-loaded) | REST, `/ws/echo`, `/ws/chat`, HikariCP pool of 5 |
| postgres | Deployment, ClusterIP :5432 | `postgres:18-alpine` | hostPath `/var/lib/ktor-poc/postgres` |
| envoy proxy | Deployment (managed by EG) | Envoy Gateway v1.9.2 | `hostNetwork`, Service `ClusterIP` |
| envoy-gateway | Deployment | v1.9.2 | Gateway API v1.6.1 CRDs from its install.yaml |
| k3s | systemd | v1.37.1+k3s1 (pinned) | traefik, servicelb, local-storage, metrics-server, helm-controller off |

## Routes

| Path | Backend | Timeouts |
|---|---|---|
| `/ws` prefix | `ktor:80` | route timeout off (`0s`), stream idle 1h |
| `/` | `ktor:80` | defaults |

Listeners: `http:80`, `https:443` (self-signed `ktor-poc-tls`, SAN = public IP).

## Endpoints

| Endpoint | Purpose |
|---|---|
| `GET /health` | liveness, no DB |
| `GET /ready` | readiness, validates a pooled connection |
| `GET/POST /api/notes` | REST over JDBC |
| `WS /ws/echo` | echo |
| `WS /ws/chat` | broadcast to all sessions; ping 15s, timeout 30s |

## Layout

| Path | What |
|---|---|
| `app/` | Ktor service, Dockerfile, docker-compose for local runs |
| `infra/` | Terraform `main.tf`, `user_data.sh` |
| `scripts/bootstrap-k3s.sh` | k3s + Envoy Gateway + TLS secret, on the node |
| `scripts/deploy.sh` | amd64 build, side-load, apply, from the laptop |
| `k8s/k8s-manifests.yaml` | everything in the cluster |
