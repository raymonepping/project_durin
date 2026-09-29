# Vault for Arcanium

Copied and adapted from `Personal/vault_reference`, without modifying that
project. The source HCL for vault-s, vault-1, vault-2 and vault-3 and the
autounseal policy are retained at the project root. Both licenses are copied
to `vault-s/config` with mode 0600; all four servers mount `vault_v2.hclic`.
The second license is available locally but is not selected automatically.

This stack contains only a Shamir-sealed transit server (`vault-s`) and one
three-node Raft cluster (`vault-1`, `vault-2`, `vault-3`). It does not include
performance/disaster replication, HAProxy, KinD, plugins or demo credentials.
The initialization and snapshot workflows are adapted from the reference;
unrelated scripts and persistent data were not copied.

## Start

Run from the Arcanium root with Podman running and `podman-compose`, `vault`,
`jq` and OpenSSL installed:

```sh
make vault-prepare
make compose-config
make vault-up
make vault-status
```

`vault-up` also prepares TLS when needed. It initializes vault-s first, unseals
it using its local Shamir key, creates the transit key/policy/token, then starts
the primary cluster. Only vault-1 is initialized; vault-2/3 join through their
copied retry_join configuration. No token or recovery key is printed.

| Node | Local HTTPS endpoint | Container |
| --- | --- | --- |
| vault-s | https://127.0.0.1:18190 | arcanium-vault_s |
| vault-1 | https://127.0.0.1:18200 | arcanium-vault_1 |
| vault-2 | https://127.0.0.1:18201 | arcanium-vault_2 |
| vault-3 | https://127.0.0.1:18202 | arcanium-vault_3 |

Host listeners bind only to loopback. The 18xxx ports avoid the 8200/8201
mappings used by existing Vault projects. Check they are free before starting.
The dedicated `arcanium-vault-internal` network isolates generic Vault DNS names
from other projects. Volumes use the `arcanium-vault` Compose project prefix.
Other future stacks can explicitly join this network as needed.

## Credentials and restart

New TLS certificates are generated for this stack. Clients use
`vault-tls/ca-chain.pem`; the browser needs to trust this local CA separately.
The CA private key lives under `.secrets/vault`, outside the server mounts.
All servers use certificate verification, including transit and Raft joins.

Fresh init output is stored in `.secrets/vault/vault-s-init.json` and
`cluster-init.json`. This local POC uses one Shamir share and one recovery share;
these are not production custody settings. vault-s still needs unsealing after
a VM restart: run `make vault-up`. Recovery keys do not replace the transit key.

The transit token is a scoped orphan periodic token with a 720-hour period.
Vault renews it while running. After an outage longer than its remaining TTL,
`vault-up` issues a replacement and recreates the three primary containers with
their existing volumes. Its secret file is mounted only in those containers.
See the [HashiCorp transit seal documentation](https://developer.hashicorp.com/vault/docs/configuration/seal/transit).

## Persistence and backup

Each node has its own named Raft and audit volumes. Servers run as container
root with all Linux capabilities dropped; under the configured rootless Podman
engine this permits reading host files with mode 0600. mlock is disabled, as in
the reference. The official image entrypoint is replaced with a minimal launcher.

```sh
make vault-backup
make vault-down
```

Backup saves and inspects one snapshot for vault-s and one for the primary
cluster under `backups/` on the Mac. Snapshot inspection checks readability,
not a completed restore test. Keep protected copies of `.secrets/vault`, TLS and
licenses separately. Both snapshots and the root-of-trust material are needed
for recovery. `vault-down` retains volumes; never use `down -v` for a restart.

Licenses, TLS keys, init files and backups are excluded from Git and image build
contexts. Existing reference tokens, data, audit logs and TLS keys are not reused.
