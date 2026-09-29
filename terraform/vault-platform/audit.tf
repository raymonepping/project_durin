# ── Audit devices ─────────────────────────────────────────────────────────────
# File audit is enabled by vault-bootstrap.sh via the raw Vault CLI so it is
# available before Terraform runs.  This resource adopts the existing device
# idempotently — Terraform will import it if already present, or create it
# if missing (e.g. after a clean-slate reset).
#
# Vault audit log path inside the container is /vault/logs/audit.log;
# this maps to ./vault-N/logs/ on the host via the named volume.

resource "vault_audit" "file" {
  type = "file"
  path = "file"

  options = {
    file_path     = "/vault/logs/audit.log"
    log_raw       = "false"
    hmac_accessor = "true"
    format        = "json"
  }
}
