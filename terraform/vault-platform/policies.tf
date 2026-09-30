# ── Vault policies ────────────────────────────────────────────────────────────
# Terraform owns policy definitions (foundational desired state).
# Durin backend owns runtime operations (encrypt/decrypt/protect/recover).

# Administrative access for a HUMAN operator (break-glass for the platform
# itself). Attached to no application identity — the backend runs under
# durin-backend (broker) + durin-database only.
resource "vault_policy" "durin_admin" {
  name = "durin-admin"

  policy = <<-EOT
    # ── Secrets engine management ────────────────────────────────────────────
    path "sys/mounts" {
      capabilities = ["read", "list"]
    }
    path "sys/mounts/*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }

    # ── Auth method management ───────────────────────────────────────────────
    path "sys/auth" {
      capabilities = ["read", "list"]
    }
    path "sys/auth/*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }

    # ── Policy management ────────────────────────────────────────────────────
    path "sys/policies/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "sys/policy/*" {
      capabilities = ["create", "read", "update", "delete"]
    }

    # ── Namespaces (Enterprise) ──────────────────────────────────────────────
    path "sys/namespaces/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # ── Identity ─────────────────────────────────────────────────────────────
    path "identity/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # ── Audit ────────────────────────────────────────────────────────────────
    path "sys/audit" {
      capabilities = ["read", "list", "sudo"]
    }
    path "sys/audit/*" {
      capabilities = ["read", "list", "create", "sudo"]
    }

    # ── AppRole ──────────────────────────────────────────────────────────────
    path "auth/approle/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # ── Database secrets engine ──────────────────────────────────────────────
    path "database/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # ── Transit secrets engine ───────────────────────────────────────────────
    path "transit/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }

    # ── Lease management ─────────────────────────────────────────────────────
    path "sys/leases/*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }
    path "sys/renew" {
      capabilities = ["update"]
    }
    path "sys/revoke" {
      capabilities = ["update"]
    }
  EOT
}

# ── Backend broker policy ─────────────────────────────────────────────────────
# Attached to the durin-backend AppRole (the identity Vault Agent logs in as).
#
# Since prompts/improvements/01_04 the backend holds NO cryptographic
# authority of its own. Everything that touches data or keys runs under a token
# Vault issued to a *person* (auth/jwt, identity-authority.tf):
#   ✓ list keys, read key metadata   (state / inspector views — never key material)
#   ✗ mint any token                 (no auth/token/create/*)
#   ✗ encrypt / decrypt / rewrap / datakey / export / backup
#   ✗ rotate, change key config
#   ✗ sys/*
# A compromised backend with nobody logged in can therefore decrypt nothing.

locals {
  tenants      = ["acme", "globex", "initech"]
  key_purposes = ["customer-data", "documents", "restricted"]
}

resource "vault_policy" "durin_backend" {
  name = "durin-backend"

  policy = <<-EOT
    # Key metadata only (keys are exportable=false; no export path exists here).
    path "transit/keys" {
      capabilities = ["list"]
    }
    path "transit/keys/durin-*" {
      capabilities = ["read"]
    }
  EOT
}

# Database-scoped policy — read dynamic credentials for durin-backend-role.
# This is the only database path the backend may access.
resource "vault_policy" "durin_database" {
  name = "durin-database"

  policy = <<-EOT
    path "database/creds/durin-backend-role" {
      capabilities = ["read"]
    }
    path "sys/leases/renew" {
      capabilities = ["update"]
    }
    path "sys/leases/revoke" {
      capabilities = ["update"]
    }
  EOT
}

# Read-only policy for demo views and the Database Inspector.
# Can read Transit key metadata and list keys, but cannot encrypt or decrypt.
resource "vault_policy" "durin_readonly" {
  name = "durin-readonly"

  policy = <<-EOT
    path "transit/keys" {
      capabilities = ["list"]
    }
    path "transit/keys/durin-*" {
      capabilities = ["read"]
    }
    path "sys/mounts" {
      capabilities = ["read", "list"]
    }
    path "sys/auth" {
      capabilities = ["read", "list"]
    }
    path "sys/policies/acl" {
      capabilities = ["list"]
    }
    path "sys/policies/acl/durin-*" {
      capabilities = ["read"]
    }
  EOT
}

# vault-rotator sidecar policy — scoped strictly to generating fresh secret-ids
# for the durin-backend role.  Cannot read, modify, or delete anything else.
resource "vault_policy" "durin_rotator" {
  name = "durin-rotator"

  policy = <<-EOT
    path "auth/approle/role/durin-backend/secret-id" {
      capabilities = ["create", "update"]
    }
    path "auth/approle/role/durin-backend/custom-secret-id" {
      capabilities = ["create", "update"]
    }
    path "auth/approle/role/durin-backend/secret-id-accessor" {
      capabilities = ["list"]
    }
    path "auth/approle/role/durin-backend/secret-id-accessor/*" {
      capabilities = ["read", "list", "delete"]
    }
    path "auth/approle/role/durin-backend/role-id" {
      capabilities = ["read"]
    }

    # 2026-09-30: the rotator decides on Vault's own answer — it looks the
    # current secret-id up (expiry, accessor) instead of trusting a local
    # schedule, and destroys the secret-id it replaced.
    path "auth/approle/role/durin-backend/secret-id/lookup" {
      capabilities = ["update"]
    }

    path "auth/approle/role/durin-backend/secret-id-accessor/destroy" {
      capabilities = ["update"]
    }
  EOT
}

# Per-tenant Transit policies (durin-transit-<tenant>) and break-glass policies
# are owned by terraform/vault-transit/policies.tf — not defined here.
