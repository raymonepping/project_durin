# compose/vault/vault-agent/config.hcl
#
# Owns exactly two things for the durin-backend identity:
#   1. AppRole auto-auth + token renewal
#   2. Rendering dynamic database/creds/durin-backend-role credentials to a file
#
# role-id and secret-id are read from /run/approle, the shared volume managed
# by the vault-rotator sidecar (see compose.yaml for the depends_on wiring).
#
# Does NOT proxy/cache other Vault API calls (Transit) — those go straight
# from durin-backend to Vault using the token this agent renders.

pid_file = "/tmp/pidfile"

vault {
  address = "https://vault-lb:8200"  # HAProxy → active node
  ca_cert = "/vault/tls/ca-chain.pem"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/run/approle/role-id"
      secret_id_file_path                 = "/run/approle/secret-id"
      # vault-rotator atomically replaces the secret-id file on rotation —
      # must not be deleted after first use so vault-agent can re-read it
      # on subsequent re-auths without waiting for the next rotation cycle.
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/vault/secrets/token"
    }
  }
}

template {
  destination = "/vault/secrets/db-creds.json"
  contents = <<EOF
{{ with secret "database/creds/durin-backend-role" }}
{"username":"{{ .Data.username }}","password":"{{ .Data.password }}","lease_id":"{{ .LeaseID }}","lease_duration":{{ .LeaseDuration }}}
{{ end }}
EOF
}
