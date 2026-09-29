#!/bin/sh
set -eu

if ! command -v podman >/dev/null 2>&1; then
  echo "ERROR: Podman is not installed or is not in PATH." >&2
  exit 1
fi

echo "Podman client"
podman version --format '  version={{.Client.Version}} os={{.Client.OsArch}}'

if [ "$(uname -s)" = "Darwin" ]; then
  echo "Podman machine"
  podman machine list --format '  {{.Name}}: {{.Running}} (cpus={{.CPUs}}, memory={{.Memory}}, disk={{.DiskSize}})'
fi

if ! podman info >/dev/null 2>&1; then
  echo "ERROR: Cannot reach the Podman service. Start it with: podman machine start" >&2
  exit 1
fi

podman info --format 'Podman server
  version={{.Version.Version}}
  platform={{.Host.OS}}/{{.Host.Arch}}
  rootless={{.Host.Security.Rootless}}
  storage={{.Store.GraphRoot}}'

if command -v podman-compose >/dev/null 2>&1; then
  compose_provider=podman-compose
  echo "Compose provider"
  echo "  $compose_provider"
  PODMAN_COMPOSE_PROVIDER="$compose_provider" podman compose version
elif [ -n "${PODMAN_COMPOSE_PROVIDER:-}" ]; then
  echo "Compose provider"
  echo "  $PODMAN_COMPOSE_PROVIDER"
  podman compose version
else
  echo "Compose provider"
  echo "  auto-detected by podman compose"
  podman compose version
fi

echo "OK: Factory can use Podman."
