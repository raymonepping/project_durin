# ── Vault Enterprise namespaces ───────────────────────────────────────────────
# One namespace per tenant provides the strongest isolation boundary.
# Each tenant's Transit keys, policies, and identity objects are scoped
# to their own namespace — a token in acme/ cannot reach globex/ resources.
#
# Note: The root-level Transit mount (terraform/vault-transit/) provides
# shared keys for the global backend role.  Per-tenant namespaces enable
# the full Enterprise isolation model for Phase 7 hardening.

resource "vault_namespace" "acme" {
  path = "acme"
}

resource "vault_namespace" "globex" {
  path = "globex"
}

resource "vault_namespace" "initech" {
  path = "initech"
}
