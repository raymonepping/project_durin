# Compose stacks

Arcanium uses separate Compose projects managed through `scripts/compose.sh`. Each project is named `arcanium-<stack>` and reads the root `.env`.

| Stack | Guide | Purpose |
| --- | --- | --- |
| `vault` | [Vault](vault/README.md) | Transit seal provider and three-node Raft cluster |
| `infra` | [Infrastructure](infra/README.md) | PostgreSQL |
| `hsm` | [HSM](hsm/README.md) | PKCS#11 proxy and Vault HSM demonstration |
| `arcanium` | [Arcanium](arcanium/README.md) | API and UI |
| `workloads` | [Workloads](workloads/README.md) | Crypto clients |
| `observability` | [Observability](observability/README.md) | Optional Prometheus/Grafana/OTel |
| `kms-sim` | [KMS emulator](kms-sim/README.md) | Optional LocalStack KMS |

```sh
make network
make compose-config
./scripts/compose.sh arcanium up -d
./scripts/compose.sh arcanium logs -f
```

The wrapper defaults to `podman-compose`; override `PODMAN_COMPOSE_PROVIDER` only deliberately. UI traffic stays on `arcanium-control`; Vault clients join `arcanium-vault-internal` as required. The legacy `arcanium` network also has a Make target, but it is not the sole network used by current stacks.

Named volumes preserve state across normal recreation. Destructive volume cleanup is not a restart. See [architecture](../docs/architecture.md) and [operations](../docs/operations.md) for trust and backup boundaries.
