#!/bin/sh
set -eu

if ! podman info >/dev/null 2>&1; then
  echo "Cannot reach Podman. Run: make check" >&2
  exit 1
fi

if [ "$(uname -s)" = "Darwin" ]; then
  echo "Podman machine capacity"
  podman machine list --format '  {{.Name}}: disk={{.DiskSize}}, memory={{.Memory}}, running={{.Running}}'
  echo
fi

echo "Container storage"
podman system df

echo
volume_count=$(podman volume ls --quiet | wc -l | tr -d ' ')
echo "Named volumes: $volume_count total"
echo "Factory volumes"
factory_volumes=$(podman volume ls --quiet --filter name=factory)
if [ -n "$factory_volumes" ]; then
  printf '%s\n' "$factory_volumes" | sort | sed 's/^/  /'
else
  echo "  none"
fi

echo
echo "No cleanup was performed. Use explicit Podman prune commands only after reviewing this report."
