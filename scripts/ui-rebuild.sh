#!/bin/sh
# Rebuild from a streamed source archive to avoid stale VM-mounted source files.
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
ARCHIVE=$(mktemp /tmp/factory-ui-build.XXXXXX)
trap 'rm -f "$ARCHIVE"' EXIT HUP INT TERM
tar -C "$UI_DIR" --exclude=node_modules --exclude=.nuxt --exclude=.output --exclude=test-results --exclude=playwright-report --exclude=.env --exclude=.playwright-cli --exclude=.artifacts --exclude=.claude --exclude=.agents -czf "$ARCHIVE" .
echo 'Building factory-ui:local…'
podman build --format docker --platform "linux/$(uname -m | sed 's/x86_64/amd64/')" -t factory-ui:local -f Containerfile - <"$ARCHIVE"
echo 'Recreating factory-ui…'
"$SCRIPT_DIR/compose.sh" ui up -d --no-deps --force-recreate ui
WAIT=0
while [ "$WAIT" -lt 60 ]; do
  STATUS=$(podman inspect factory-ui --format '{{.State.Health.Status}}' 2>/dev/null || echo starting)
  if [ "$STATUS" = healthy ]; then
    echo 'factory-ui is healthy: http://localhost:3000/'
    if [ "$TAIL_LOGS" -eq 1 ]; then podman logs -f factory-ui; fi
    exit 0
  fi
  sleep 2
  WAIT=$((WAIT + 2))
done
echo 'UI did not become healthy. Inspect: podman logs factory-ui' >&2
exit 1
