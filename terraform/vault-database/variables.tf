variable "vault_addr" {
  description = "Vault cluster API address"
  type        = string
  default     = "https://127.0.0.1:18300" # vault-lb (HAProxy → active node)
}

variable "vault_cacert" {
  description = "Absolute path to the CA certificate for TLS verification"
  type        = string
  default     = "../../vault-tls/ca-chain.pem"
}

variable "postgres_host" {
  description = "PostgreSQL hostname reachable from the Vault container. Uses host-published port via host.containers.internal so Vault can reach Postgres without sharing a compose network."
  type        = string
  default     = "host.containers.internal"
}

variable "postgres_port" {
  description = "PostgreSQL port (host-published)"
  type        = number
  default     = 5432
}

variable "postgres_user" {
  description = "PostgreSQL management superuser (Vault uses this to create/revoke dynamic roles)"
  type        = string
  sensitive   = true
}

variable "postgres_password" {
  description = "PostgreSQL management password (stored in Vault internal storage, never exposed to app)"
  type        = string
  sensitive   = true
}

variable "postgres_db" {
  description = "PostgreSQL database name"
  type        = string
  default     = "durin_db"
}
