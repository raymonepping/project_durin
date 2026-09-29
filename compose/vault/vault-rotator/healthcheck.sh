#!/bin/sh
# compose/vault/vault-rotator/healthcheck.sh
# Verifies that role-id, secret-id, and metadata are populated and non-empty.
set -eu

[ -s /run/approle/role-id ] || exit 1
[ -s /run/approle/secret-id ] || exit 1
[ -s /run/approle/metadata.json ] || exit 1

exit 0
