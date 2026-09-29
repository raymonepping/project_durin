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
