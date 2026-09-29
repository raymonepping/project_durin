# Observability stack (Prompt 13)

Independent stack. `make observability-up` starts Prometheus, Grafana and the
OpenTelemetry Collector; nothing else depends on it.

| Service | URL | Notes |
|---|---|---|
| Grafana | http://localhost:3010 | anonymous Viewer; dashboards auto-provisioned |
| Prometheus | http://localhost:9090 | |
| OTel Collector | grpc :4317 / http :4318 | receives OTLP from the Arcanium API |

Grafana is on **3010** — the Arcanium UI owns 3000.

## What is scraped

- `vault-1/2/3` — `https://<node>:8200/v1/sys/metrics?format=prometheus`, TLS with
  the shared CA, `Authorization: Bearer <token>` from
  `prometheus/vault-token` (a periodic token with the `metrics` policy —
  `path "sys/metrics" { capabilities = ["read"] }`; **gitignored**, regenerate
  with `vault token create -policy=metrics -period=72h`).
- `arcanium-api:3001/metrics` — Prometheus exposition from the API
  (`src/telemetry/metrics.js`): `arcanium_http_requests_total`,
  `arcanium_http_request_duration_seconds`, `arcanium_crypto_operations_total`,
  `arcanium_provisioning_jobs_total`, `arcanium_approvals_total`.
- `arcanium-otel-collector:8889` — the collector's Prometheus export of OTLP it
  received.

Prometheus joins `arcanium-vault-internal` in addition to `arcanium-control` —
read-only metric scraping is a monitoring concern. Grafana and the collector stay
on `arcanium-control` only.

## The API side

The Arcanium API always exposes `/metrics`. OTLP export is optional and only
wired when `OTEL_ENABLED=true` — the API runs fine with the collector absent
(`input/04` — errors must be safe).

`GET /api/v1/observability/summary` proxies a few PromQL queries so the Arcanium
`/observability` page can show live numbers without the browser talking to
Prometheus. When the stack is down it returns `{ available: false }` and the page
shows the "not connected" state driven by a real probe — not a hard-coded flag.

## SLA dashboard

The `arcanium-sla` dashboard (extend `grafana/dashboards/`) puts, per supplier
namespace: the simulated contract, the **real** rate-limit quota (Prompt 07),
observed req/min, and rejected-by-quota count. Drive traffic against a supplier
namespace first to populate it.

## Adding a panel

Edit `grafana/dashboards/arcanium-overview.json` (or add a new `*.json`) — the
file provider reloads every 30s. Metric names are listed above; Vault's own
metrics use the `vault_*` prefix with a `node` label.
