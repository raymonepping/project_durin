#!/bin/sh
# scripts/ui-rebuild.sh — rebuild and restart the Durin Web Console (make ui-rebuild).
#
# Builds from a streamed source archive to avoid stale VM-mounted source files
# (podman machine). macOS extended attributes are stripped and AppleDouble
# (._*) files excluded: they otherwise break the Nitro build. Before the
# restart, the durin-ui AppRole secret-id is (re)issued so ui-secrets-init can
# render the OIDC client secret from Vault again.
set -eu
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
UI_DIR="$PROJECT_ROOT/ui"
TAIL_LOGS=0
for arg in "$@"; do
  case "$arg" in
  --logs | -l) TAIL_LOGS=1 ;;
  --help | -h)
    echo "Usage: $0 [--logs]"
    exit 0
    ;;
  *)
    echo "Unknown option: $arg" >&2
    exit 64
    ;;
  esac
done
ARCHIVE=$(mktemp /tmp/durin-ui-build.XXXXXX)
trap 'rm -f "$ARCHIVE"' EXIT HUP INT TERM
xattr -rc "$UI_DIR" 2>/dev/null || true
COPYFILE_DISABLE=1 tar -C "$UI_DIR" --exclude='._*' --exclude=.DS_Store --exclude=tests/.auth --exclude=node_modules --exclude=.nuxt --exclude=.output --exclude=test-results --exclude=playwright-report --exclude=.env --exclude=.playwright-cli --exclude=.artifacts --exclude=.claude --exclude=.agents -czf "$ARCHIVE" .
echo 'Building durin-ui:local…'
podman build --format docker --platform "linux/$(uname -m | sed 's/x86_64/amd64/')" -t durin-ui:local -f Containerfile - <"$ARCHIVE"
echo 'Issuing the durin-ui AppRole secret-id…'
"$SCRIPT_DIR/identity-secrets.sh" >/dev/null
echo 'Recreating ui-secrets-init and durin-ui…'
"$SCRIPT_DIR/compose.sh" ui up -d --force-recreate
WAIT=0
while [ "$WAIT" -lt 60 ]; do
  STATUS=$(podman inspect durin-ui --format '{{.State.Health.Status}}' 2>/dev/null || echo starting)
  if [ "$STATUS" = healthy ]; then
    echo 'durin-ui is healthy: http://localhost:3000/'
    if [ "$TAIL_LOGS" -eq 1 ]; then podman logs -f durin-ui; fi
    exit 0
  fi
  sleep 2
  WAIT=$((WAIT + 2))
done
echo 'UI did not become healthy. Inspect: podman logs durin-ui' >&2
exit 1
