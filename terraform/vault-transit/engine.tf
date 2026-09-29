# ── Transit secrets engine ────────────────────────────────────────────────────
# The cryptographic foundation for all Durin data protection operations.
# The Durin backend encrypts every sensitive field through this mount before
# writing to PostgreSQL — the database never holds plaintext.

resource "vault_mount" "transit" {
  path                      = "transit"
  type                      = "transit"
  description               = "Durin Transit — application-layer encryption for data protection"
  default_lease_ttl_seconds = 3600
  max_lease_ttl_seconds     = 86400
}
