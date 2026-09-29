output "database_engine_path" {
  description = "Database secrets engine mount path"
  value       = vault_mount.database.path
}

output "database_creds_path" {
  description = "Path the Durin backend reads to obtain dynamic PostgreSQL credentials"
  value       = "database/creds/${vault_database_secret_backend_role.durin_backend.name}"
}

output "database_connection_name" {
  description = "PostgreSQL connection name registered in the Database secrets engine"
  value       = vault_database_secret_backend_connection.postgres.name
}
