# ── Identity-derived authority (prompts/improvements/01_04) ───────────────────
# Vault verifies the PERSON, not the application. The backend forwards the
# user's Keycloak access token to auth/jwt/login; Vault checks signature,
# issuer, audience, role and tenant claims itself before issuing a short-lived
# token. The backend's own (broker) token can no longer mint tenant authority.

variable "keycloak_jwks_url" {
  description = "JWKS endpoint as reached from the Vault nodes (durin-internal)"
  type        = string
  default     = "http://keycloak:8080/realms/durin/protocol/openid-connect/certs"
}

variable "keycloak_issuer" {
  description = "Issuer published in Durin access tokens"
  type        = string
  default     = "http://localhost:8083/realms/durin"
}

resource "vault_jwt_auth_backend" "keycloak" {
  path         = "jwt"
  type         = "jwt"
  description  = "Durin users (Keycloak realm durin) — identity-derived Vault authority"
  jwks_url     = var.keycloak_jwks_url
  bound_issuer = var.keycloak_issuer
}

locals {
  jwt_common = {
    bound_audiences   = ["durin-backend"]
    user_claim        = "sub"
    groups_claim      = "groups"
    bound_claims_type = "string" # "*" in durin_tenants is literal, not a glob
    claim_mappings = {
      preferred_username = "username"
      email              = "email"
    }
  }
  # Separation of duties, enforced by Vault: approvers can never be requesters.
  # (Vault Control Groups do not themselves forbid an approver authorising
  # their own request — verified live — so the requester role excludes them.)
  requester_roles = "durin-viewer,durin-operator"
}

# ── Policies ──────────────────────────────────────────────────────────────────

# Key lifecycle for one tenant, held only by a logged-in operator of that tenant.
resource "vault_policy" "durin_keys" {
  for_each = toset(local.tenants)
  name     = "durin-keys-${each.key}"

  policy = <<-EOT
    %{~for p in local.key_purposes}
    path "transit/keys/durin-${each.key}-${p}" {
      capabilities = ["read"]
    }
    path "transit/keys/durin-${each.key}-${p}/rotate" {
      capabilities = ["update"]
    }
    path "transit/keys/durin-${each.key}-${p}/config" {
      capabilities       = ["update"]
      allowed_parameters = { "min_decryption_version" = [] }
    }
    %{~endfor}
  EOT
}

# Break glass: the requester may ASK Vault to decrypt RESTRICTED data. Vault
# holds the answer (response-wrapped) until one member of the identity group
# durin-security-admins authorises it. Quorum, TTL and single release are
# enforced by Vault (Control Groups, Vault Enterprise).
resource "vault_policy" "durin_breakglass_request" {
  for_each = toset(local.tenants)
  name     = "durin-breakglass-request-${each.key}"

  policy = <<-EOT
    path "transit/decrypt/durin-${each.key}-restricted" {
      capabilities = ["update"]
      control_group = {
        ttl = "15m"
        factor "security-admin" {
          identity {
            group_names = ["durin-security-admins"]
            approvals   = 1
          }
        }
      }
    }
  EOT
}

resource "vault_policy" "durin_breakglass_approver" {
  name = "durin-breakglass-approver"

  policy = <<-EOT
    path "sys/control-group/authorize" {
      capabilities = ["update"]
    }
    path "sys/control-group/request" {
      capabilities = ["update"]
    }
  EOT
}

# ── Identity group for approvers (membership from the JWT groups claim) ───────

resource "vault_identity_group" "security_admins" {
  name     = "durin-security-admins"
  type     = "external"
  metadata = { purpose = "break-glass approvers (Control Groups)" }
}

resource "vault_identity_group_alias" "security_admins" {
  name           = "durin-security-admin" # LDAP/Keycloak group name in the `groups` claim
  mount_accessor = vault_jwt_auth_backend.keycloak.accessor
  canonical_id   = vault_identity_group.security_admins.id
}

# ── JWT roles ─────────────────────────────────────────────────────────────────

resource "vault_jwt_auth_backend_role" "tenant" {
  for_each = toset(local.tenants)

  backend           = vault_jwt_auth_backend.keycloak.path
  role_name         = "tenant-${each.key}"
  role_type         = "jwt"
  bound_audiences   = local.jwt_common.bound_audiences
  user_claim        = local.jwt_common.user_claim
  groups_claim      = local.jwt_common.groups_claim
  claim_mappings    = local.jwt_common.claim_mappings
  bound_claims_type = local.jwt_common.bound_claims_type
  bound_claims = {
    "/durin_tenants"      = "${each.key},*"
    "/realm_access/roles" = "durin-operator"
  }
  token_policies         = ["durin-transit-${each.key}", vault_policy.durin_keys[each.key].name]
  token_ttl              = 300
  token_explicit_max_ttl = 300
  token_type             = "service"
}

resource "vault_jwt_auth_backend_role" "breakglass_requester" {
  for_each = toset(local.tenants)

  backend           = vault_jwt_auth_backend.keycloak.path
  role_name         = "breakglass-requester-${each.key}"
  role_type         = "jwt"
  bound_audiences   = local.jwt_common.bound_audiences
  user_claim        = local.jwt_common.user_claim
  groups_claim      = local.jwt_common.groups_claim
  claim_mappings    = local.jwt_common.claim_mappings
  bound_claims_type = local.jwt_common.bound_claims_type
  bound_claims = {
    "/durin_tenants"      = "${each.key},*"
    "/realm_access/roles" = local.requester_roles
  }
  token_policies = [vault_policy.durin_breakglass_request[each.key].name]
  # The control-group wrapping token is a CHILD of this token (verified live):
  # it must outlive the 15-minute approval window, so the requester token does
  # too. It can only ask for decrypts that always need approval.
  token_ttl              = 900
  token_explicit_max_ttl = 900
  token_type             = "service"
}

resource "vault_jwt_auth_backend_role" "breakglass_approver" {
  backend           = vault_jwt_auth_backend.keycloak.path
  role_name         = "breakglass-approver"
  role_type         = "jwt"
  bound_audiences   = local.jwt_common.bound_audiences
  user_claim        = local.jwt_common.user_claim
  groups_claim      = local.jwt_common.groups_claim
  claim_mappings    = local.jwt_common.claim_mappings
  bound_claims_type = local.jwt_common.bound_claims_type
  bound_claims = {
    "/realm_access/roles" = "durin-security-admin"
  }
  token_policies         = [vault_policy.durin_breakglass_approver.name]
  token_ttl              = 120
  token_explicit_max_ttl = 120
  token_type             = "service"
}

output "jwt_auth_accessor" {
  value = vault_jwt_auth_backend.keycloak.accessor
}
