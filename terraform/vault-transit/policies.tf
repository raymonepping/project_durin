# ── Per-tenant Transit authority ──────────────────────────────────────────────
# Cryptographic isolation is enforced here, by Vault, not by application code.
#
# The Durin backend never holds these policies on its own token. For every
# data operation Vault issues a short-lived token carrying this policy to the
# logged-in operator (auth/jwt role tenant-<t>, vault-platform/identity-authority.tf).
# A request running under ACME authority therefore physically carries a token
# that Vault will refuse for any durin-globex-* or durin-initech-* key.
#
# Authority per tenant token (durin-transit-<tenant>):
#   customer-data  encrypt  decrypt  rewrap
#   documents      encrypt  decrypt  rewrap
#   restricted     encrypt           rewrap   ← protect yes, recover NO
#
# Rewrap never returns plaintext (Vault decrypts + re-encrypts internally), so
# granting it on the restricted key does not grant recovery authority.
#
# Recovering RESTRICTED data requires a break-glass token (durin-breakglass-*
# below), minted only after a security-admin approves a request.
#
# Key lifecycle (read / rotate / min_decryption_version) is NOT part of tenant
# authority — it belongs to the backend broker policy in vault-platform.

locals {
  tenants = ["acme", "globex", "initech"]
}

resource "vault_policy" "durin_transit_acme" {
  name   = "durin-transit-acme"
  policy = templatefile("${path.module}/templates/tenant-policy.hcl.tftpl", { tenant = "acme" })
}

resource "vault_policy" "durin_transit_globex" {
  name   = "durin-transit-globex"
  policy = templatefile("${path.module}/templates/tenant-policy.hcl.tftpl", { tenant = "globex" })
}

resource "vault_policy" "durin_transit_initech" {
  name   = "durin-transit-initech"
  policy = templatefile("${path.module}/templates/tenant-policy.hcl.tftpl", { tenant = "initech" })
}

# Break-glass authority moved to terraform/vault-platform/identity-authority.tf
# (Vault Control Groups on transit/decrypt/durin-<t>-restricted).
