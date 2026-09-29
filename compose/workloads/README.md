# Workloads Stack

Demo consumers that perform **real** Vault API calls, giving Arcanium
something concrete to manage and observe.

## Architecture

```
                MANAGEMENT PLANE
Arcanium API ──► provision key + AppRole in Vault

                CRYPTO DATA PATH (direct to Vault)
payments-api ──AppRole login──► Vault Transit (encrypt/decrypt/rotate)
pki-client   ──AppRole login──► Vault PKI     (issue/renew cert)
```

Workloads connect to `arcanium-vault-internal` only — they never call the
Arcanium API for crypto operations.

## KML stages demonstrated

| Workload | Generatie | Distributie | Opslag | Gebruik | Rotatie | Vernietiging |
|---|---|---|---|---|---|---|
| payments-api | key created by TF | AppRole creds | Vault holds key | encrypt/decrypt | key rotate | key destroy (manual) |
| pki-client | cert issuance | — | Vault holds CA | active cert | cert renewal | cert expiry |

## Prerequisites

```bash
make vault-up      # Vault cluster running
make arcanium-up   # Arcanium API running
make tf-platform   # AppRole + policies
make tf-transit    # Transit engine
make tf-pki        # PKI CA
make tf-workloads  # payments-api-key + workload roles (or run make tf-all)
```

## Onboarding (one-time)

```bash
make onboarding
# → registers apps in Arcanium API
# → applies tf-workloads (idempotent)
# → generates AppRole secret_ids
# → writes .env.workloads (gitignored)
```

## Start

```bash
make workloads-up
make workloads-logs
```

## Demo flags

| Flag | Default | Effect |
|---|---|---|
| `DEMO_FAST_ROTATION=true` | false | payments-api rotates key every 2 minutes instead of 24h |
| `DEMO_SHORT_TTL=true` | false | pki-client issues 2m certs → renewal fires every ~24s |

Set in `.env` before `make workloads-up`:
```bash
echo "DEMO_FAST_ROTATION=true" >> .env
echo "DEMO_SHORT_TTL=true" >> .env
make workloads-up
```

## Health endpoints

| Container | Endpoint | Response |
|---|---|---|
| arcanium-payments-api | `http://localhost:3002/health` | `{ status, authenticated, keyVersion, transitKey }` |
| arcanium-pki-client | `http://localhost:3003/health` | `{ status, authenticated }` |
| arcanium-pki-client | `http://localhost:3003/cert` | `{ serial, cn, issuedAt, expiresAt, ttlRemaining }` |

## Expected log lines

```
# payments-api
[payments-api] AppRole login successful (attempt=1)
[payments-api] encrypted: vault:v1:AQICAHj...
[payments-api] decrypted round-trip OK (card=4111-1111-1111-1111 ...)
[payments-api] key rotated to version 2     ← DEMO_FAST_ROTATION=true

# pki-client
[pki-client] cert issued serial=3a:f1:... cn=pki-client.arcanium.local expires=...
[pki-client] cert valid serial=... ttl_remaining=86399s
[pki-client] cert renewed serial=4b:22:...  ← DEMO_SHORT_TTL=true
```
