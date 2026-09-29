output "approle_durin_backend_role_id" {
  description = "AppRole role_id for durin-backend (seed into BACKEND_ROLE_ID in .env)"
  value       = vault_approle_auth_backend_role.durin_backend.role_id
  sensitive   = false
}

output "approle_durin_agent_role_id" {
  description = "AppRole role_id for durin-agent (seed into AGENT_ROLE_ID in .env)"
  value       = vault_approle_auth_backend_role.durin_agent.role_id
  sensitive   = false
}

output "approle_durin_rotator_role_id" {
  description = "AppRole role_id for durin-rotator sidecar (seed into ROTATOR_ROLE_ID in .env)"
  value       = vault_approle_auth_backend_role.durin_rotator.role_id
  sensitive   = false
}

output "approle_path" {
  description = "AppRole auth mount path"
  value       = vault_auth_backend.approle.path
}

output "namespace_acme" {
  description = "Vault namespace for the ACME tenant"
  value       = vault_namespace.acme.path
}

output "namespace_globex" {
  description = "Vault namespace for the Globex tenant"
  value       = vault_namespace.globex.path
}

output "namespace_initech" {
  description = "Vault namespace for the Initech tenant"
  value       = vault_namespace.initech.path
}
