# ── Per-tenant Transit keys ───────────────────────────────────────────────────
# Two keys per tenant: one for customer PII, one for documents.
# This ensures a key rotation or compromise on one data type does not affect
# the other — defence-in-depth at the key level.
#
# All keys:
#   type              = aes256-gcm96 (authenticated encryption, NIST approved)
#   exportable        = false        (key material never leaves Vault)
#   deletion_allowed  = false        (prevent accidental data loss in demos)
#   allow_plaintext_backup = false   (no raw key export)
#   min_decryption_version = 1       (initial floor — raised at runtime by the
#                                     Shield/Fortify scenario, hence ignore_changes)
#   min_encryption_version = 0       (always encrypt with the latest version)
#
# Three keys per tenant: customer-data, documents, and restricted. RESTRICTED
# documents use their own key so that recovery authority can be withheld by
# Vault policy (tenant tokens may encrypt but not decrypt it — see policies.tf).

# ── ACME tenant ──────────────────────────────────────────────────────────────

resource "vault_transit_secret_backend_key" "durin_acme_customer_data" {
  backend                = vault_mount.transit.path
  name                   = "durin-acme-customer-data"
  type                   = "aes256-gcm96"
  deletion_allowed       = false
  exportable             = false
  allow_plaintext_backup = false
  min_decryption_version = 1
  min_encryption_version = 0

  lifecycle {
    ignore_changes = [min_decryption_version]
  }
}

resource "vault_transit_secret_backend_key" "durin_acme_documents" {
  backend                = vault_mount.transit.path
  name                   = "durin-acme-documents"
  type                   = "aes256-gcm96"
  deletion_allowed       = false
  exportable             = false
  allow_plaintext_backup = false
  min_decryption_version = 1
  min_encryption_version = 0

  lifecycle {
    ignore_changes = [min_decryption_version]
  }
}

# ── Globex tenant ─────────────────────────────────────────────────────────────

resource "vault_transit_secret_backend_key" "durin_globex_customer_data" {
  backend                = vault_mount.transit.path
  name                   = "durin-globex-customer-data"
  type                   = "aes256-gcm96"
  deletion_allowed       = false
  exportable             = false
  allow_plaintext_backup = false
  min_decryption_version = 1
  min_encryption_version = 0

  lifecycle {
    ignore_changes = [min_decryption_version]
  }
}

resource "vault_transit_secret_backend_key" "durin_globex_documents" {
  backend                = vault_mount.transit.path
  name                   = "durin-globex-documents"
  type                   = "aes256-gcm96"
  deletion_allowed       = false
  exportable             = false
  allow_plaintext_backup = false
  min_decryption_version = 1
  min_encryption_version = 0

  lifecycle {
    ignore_changes = [min_decryption_version]
  }
}

# ── Initech tenant ────────────────────────────────────────────────────────────

resource "vault_transit_secret_backend_key" "durin_initech_customer_data" {
  backend                = vault_mount.transit.path
  name                   = "durin-initech-customer-data"
  type                   = "aes256-gcm96"
  deletion_allowed       = false
  exportable             = false
  allow_plaintext_backup = false
  min_decryption_version = 1
  min_encryption_version = 0

  lifecycle {
    ignore_changes = [min_decryption_version]
  }
}

resource "vault_transit_secret_backend_key" "durin_initech_documents" {
  backend                = vault_mount.transit.path
  name                   = "durin-initech-documents"
  type                   = "aes256-gcm96"
  deletion_allowed       = false
  exportable             = false
  allow_plaintext_backup = false
  min_decryption_version = 1
  min_encryption_version = 0

  lifecycle {
    ignore_changes = [min_decryption_version]
  }
}

# ── RESTRICTED documents (all tenants) ───────────────────────────────────────
# Recovery requires an approved, single-use break-glass token.

resource "vault_transit_secret_backend_key" "durin_restricted" {
  for_each = toset(local.tenants)

  backend                = vault_mount.transit.path
  name                   = "durin-${each.key}-restricted"
  type                   = "aes256-gcm96"
  deletion_allowed       = false
  exportable             = false
  allow_plaintext_backup = false
  min_decryption_version = 1
  min_encryption_version = 0

  lifecycle {
    ignore_changes = [min_decryption_version]
  }
}
