ui = true
disable_mlock = true
license_path = "/vault/config/vault_v2.hclic"

api_addr     = "https://vault-s:8200"
cluster_addr = "https://vault-s:8201"

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/vault/config/tls/vault.crt"
  tls_key_file    = "/vault/config/tls/vault.key"
  tls_min_version = "tls13"
}

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-s"
}

log_level = "warn"

telemetry {
  prometheus_retention_time = "300s"
  disable_hostname          = true
}
