#!/bin/sh
set -eu

project_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
env_file="$project_root/.env"
container_name=factory-ollama
api_url=${OLLAMA_API_URL:-http://127.0.0.1:11434}

if [ -z "${OLLAMA_MODEL:-}" ]; then
  if [ ! -f "$env_file" ]; then
    echo "Missing $env_file. Copy .env.example to .env and configure OLLAMA_MODEL." >&2
    exit 66
  fi

  OLLAMA_MODEL=$(sed -n 's/^OLLAMA_MODEL=//p' "$env_file" | tail -n 1 | tr -d '\r')
fi

case "$OLLAMA_MODEL" in
'' | *[!A-Za-z0-9._:/-]*)
  echo "OLLAMA_MODEL is empty or contains unsupported characters." >&2
  exit 64
  ;;
esac

if ! command -v podman >/dev/null 2>&1; then
  echo "Podman is required but was not found in PATH." >&2
  exit 69
fi

if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "curl and jq are required to verify Ollama's API." >&2
  exit 69
fi

if ! podman container exists "$container_name"; then
  echo "$container_name does not exist. Run 'make ollama-up' to create it." >&2
  exit 69
fi

attempt=0
until tags=$(curl -fsS --max-time 5 "$api_url/api/tags" 2>/dev/null); do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    echo "Ollama did not become ready at $api_url/api/tags within 60 seconds." >&2
    exit 69
  fi
  sleep 2
done

if printf '%s' "$tags" | jq -e --arg model "$OLLAMA_MODEL" \
  'any(.models[]?; .name == $model or .model == $model)' >/dev/null; then
  echo "Ollama model already present: $OLLAMA_MODEL"
else
  echo "Pulling Ollama model: $OLLAMA_MODEL"
  podman exec "$container_name" ollama pull "$OLLAMA_MODEL"
fi

curl -fsS --max-time 5 "$api_url/api/tags" |
  jq -e --arg model "$OLLAMA_MODEL" \
    'any(.models[]?; .name == $model or .model == $model)' >/dev/null

echo "Ollama model ready: $OLLAMA_MODEL"
