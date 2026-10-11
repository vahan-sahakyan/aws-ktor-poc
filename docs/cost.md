# Cost

[<- README](../README.md) · [Architecture](architecture.md) · **Cost** · [Memory](memory.md) · [Decisions](decisions.md)

---

The account is on the AWS Free plan (created after 2025-07-15). Usage is paid from $100-200 of credits and the plan cannot bill the card; it closes after 6 months or when credits run out, with 90 days to upgrade before AWS deletes everything. Expected burn is ~$14/month gross.

| Item | Choice | Why |
|---|---|---|
| Compute | 1x `t3.micro`, `cpu_credits = standard` | `unlimited` (the T3 default) bills surplus CPU; standard throttles |
| Storage | 30 GB gp3 root, encrypted | deleted with the instance |
| Public IP | 1 auto-assigned IPv4 | billed hourly (credits); no EIP, it bills while stopped |
| Ingress | Envoy on `hostNetwork` | ALB/NLB bill hourly |
| Registry | none, `docker save` over SSH | ECR storage bills |
| Egress | one public subnet, no NAT | NAT bills hourly |
| Guardrail | AWS Budget on gross cost (credits excluded), $20/month, actual + forecast alerts | net cost stays $0 on the free plan, so only gross cost shows the burn rate |

Rules:
- State the cost of any new AWS resource before adding it
- `t3.small` (2 GB) is the only allowed upgrade; it burns credits ~2x
- Never join AWS Organizations, Control Tower or the Partner Network: each auto-upgrades the account to paid
- Free plan terms change; re-check them before relying on a number here
