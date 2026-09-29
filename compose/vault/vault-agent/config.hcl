# compose/vault/vault-agent/config.hcl
#
# Owns exactly two things for the arcanium-api identity: (1) AppRole
# auto-auth + token renewal, and (2) rendering the dynamic
# database/creds/arcanium-api-role credential to a file on its own schedule.
# role-id and secret-id are read from /run/approle, the shared volume managed
# by the vault-rotator sidecar (see compose.yaml for the depends_on wiring).
#
# Deliberately does NOT proxy/cache other Vault API calls (Transit, PKI,
# Control Group) — those go straight from arcanium-api to Vault using the
# token this file renders.

pid_file = "/tmp/pidfile"

vault {
  address = "https://vault-1:8200"
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
      # The sink's `mode` config did not behave as documented (0640 silently
      # produced 0600; quoted "0640" hard-errored). Container user: 1000:1000
      # matches arcanium-api/worker's UID, so the default 0600 already grants
      # read access — no mode override needed.
    }
  }
}

template {
  destination = "/vault/secrets/db-creds.json"
  # error_on_missing_key left at its default (false is not valid here —
  # Agent's template stanza just fails the render on a missing key, which
  # is the correct behavior: never write a partial/malformed credentials
  # file).
  contents = <<EOF
{{ with secret "database/creds/arcanium-api-role" }}
{"username":"{{ .Data.username }}","password":"{{ .Data.password }}","lease_id":"{{ .LeaseID }}","lease_duration":{{ .LeaseDuration }}}
{{ end }}
EOF
}
