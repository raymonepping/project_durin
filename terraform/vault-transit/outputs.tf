output "transit_mount_path" {
  description = "Transit secrets engine mount path"
  value       = vault_mount.transit.path
}

output "acme_customer_data_key" {
  description = "Transit key name for ACME customer PII"
  value       = vault_transit_secret_backend_key.durin_acme_customer_data.name
}

output "acme_documents_key" {
  description = "Transit key name for ACME documents"
  value       = vault_transit_secret_backend_key.durin_acme_documents.name
}

output "globex_customer_data_key" {
  description = "Transit key name for Globex customer PII"
  value       = vault_transit_secret_backend_key.durin_globex_customer_data.name
}

output "globex_documents_key" {
  description = "Transit key name for Globex documents"
  value       = vault_transit_secret_backend_key.durin_globex_documents.name
}

output "initech_customer_data_key" {
  description = "Transit key name for Initech customer PII"
  value       = vault_transit_secret_backend_key.durin_initech_customer_data.name
}

output "initech_documents_key" {
  description = "Transit key name for Initech documents"
  value       = vault_transit_secret_backend_key.durin_initech_documents.name
}

output "restricted_keys" {
  description = "Transit keys for RESTRICTED documents (break-glass recovery only)"
  value       = { for t, k in vault_transit_secret_backend_key.durin_restricted : t => k.name }
}
