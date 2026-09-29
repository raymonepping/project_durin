# terraform/bootstrap/README.md

# Bootstrap: Terraform pre-flight

Before running `terraform apply` in any Durin Terraform module you must export
`VAULT_TOKEN` from the cluster init file written by `vault-bootstrap.sh`.

## Step 1 — Export the root token

```bash
export VAULT_TOKEN=$(jq -r '.root_token' .secrets/vault/cluster-init.json)
export VAULT_ADDR=https://127.0.0.1:18200
export VAULT_CACERT=$(pwd)/vault-tls/ca-chain.pem
```

Confirm the token is valid:

```bash
vault token lookup
```

## Step 2 — Export PostgreSQL credentials (vault-database only)

The `vault-database` module needs the management superuser credentials so Vault
can create and revoke dynamic roles.  These come from your `.env` file:

```bash
export TF_VAR_postgres_user=$(grep ^POSTGRES_USER .env | cut -d= -f2)
export TF_VAR_postgres_password=$(grep ^POSTGRES_PASSWORD .env | cut -d= -f2)
```

## Step 3 — Apply in order

```bash
# Platform baseline first (AppRole, policies, namespaces, audit)
make tf-apply

# Then Transit keys
make tf-transit

# Then Database secrets engine
make tf-database
```

Or step by step:

```bash
cd terraform/vault-platform && terraform init && terraform apply
cd terraform/vault-transit  && terraform init && terraform apply
cd terraform/vault-database && terraform init && terraform apply
```

## Step 4 — Seed AppRole credentials into .env

After `make tf-apply` succeeds, collect the AppRole role_ids and write them
into `.env`:

```bash
cd terraform/vault-platform
BACKEND_ROLE_ID=$(terraform output -raw approle_durin_backend_role_id)
AGENT_ROLE_ID=$(terraform output -raw approle_durin_agent_role_id)
ROTATOR_ROLE_ID=$(terraform output -raw approle_durin_rotator_role_id)

# Add to .env (or use scripts/vault-admin-bootstrap.sh for a full seed)
echo "BACKEND_ROLE_ID=${BACKEND_ROLE_ID}" >> ../.env
echo "AGENT_ROLE_ID=${AGENT_ROLE_ID}" >> ../.env
echo "ROTATOR_ROLE_ID=${ROTATOR_ROLE_ID}" >> ../.env
```

Then generate secret-ids for each role:

```bash
vault write -f auth/approle/role/durin-backend/secret-id
vault write -f auth/approle/role/durin-agent/secret-id
vault write -f auth/approle/role/durin-rotator/secret-id
```

## State files

Terraform state is stored locally under `.secrets/terraform/` (gitignored).
This is intentional — the state may contain sensitive values (role_ids,
connection strings) and must never be committed.

| Module           | State file                                    |
|------------------|-----------------------------------------------|
| vault-platform   | .secrets/terraform/vault-platform.tfstate     |
| vault-transit    | .secrets/terraform/vault-transit.tfstate      |
| vault-database   | .secrets/terraform/vault-database.tfstate     |
