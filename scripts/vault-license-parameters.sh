#!/usr/bin/env bash
# Build the JSON modules block used when constructing a Vault license.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage:
  vault-license-parameters.sh [OPTIONS] PRESET [PRESET ...]
  vault-license-parameters.sh --list

Build a deduplicated Vault license parameters block from one or more presets.
JSON is written to stdout; explanations and errors are written to stderr.

Presets:
  standard          No additional modules
  plus              Governance Policy
  premium           Multi-DC Scale + Governance Policy
  platform          Platform Standard (Vault Enterprise 2.0+)
  platform-kmip     Platform Standard + ADP Key Management (Vault 2.0+)
  self-managed      Multi-DC + Governance + version-appropriate ADP modules
  adp               ADP Transform + ADP Key Management
  adp-km            ADP Key Management only
  adp-transform     ADP Transform only
  pki-only          Exclusive PKI-only packaging; overrides all other modules
  agentic-iam       Agentic IAM (Vault 2.1+)

Options:
  --vault-version VERSION  Validate against VERSION (default: installed Vault)
  --module MODULE          Add a literal module; may be repeated
  --compact                Emit compact JSON
  --explain                Print resolved version and modules to stderr
  --list                   List presets
  -h, --help               Show this help

Examples:
  vault-license-parameters.sh premium adp
  vault-license-parameters.sh --vault-version 2.1.0 platform-kmip agentic-iam
  vault-license-parameters.sh --compact --module platform-standard
EOF
}

list_presets() {
  usage | sed -n '/^Presets:/,/^$/p'
}

normalize_version() {
  printf '%s\n' "$1" | sed -E 's/^Vault[[:space:]]+v//; s/^v//; s/\+.*$//; s/-.*$//'
}

version_at_least() {
  awk -v have="$1" -v need="$2" 'BEGIN {
    hn = split(have, h, "."); nn = split(need, n, ".");
    max = hn > nn ? hn : nn;
    for (i = 1; i <= max; i++) {
      hv = (i <= hn && h[i] != "") ? h[i] + 0 : 0;
      nv = (i <= nn && n[i] != "") ? n[i] + 0 : 0;
      if (hv > nv) exit 0;
      if (hv < nv) exit 1;
    }
    exit 0;
  }'
}

modules=()
selections=()
compact=false
explain=false
requested_version=''

add_module() {
  local candidate=$1 existing
  for existing in "${modules[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  modules+=("$candidate")
}

has_module() {
  local candidate=$1 existing
  for existing in "${modules[@]}"; do
    [[ "$existing" == "$candidate" ]] && return 0
  done
  return 1
}

require_version() {
  local preset=$1 minimum=$2
  if ! version_at_least "$vault_version" "$minimum"; then
    printf 'ERROR: preset %s requires Vault %s or newer; selected version is %s.\n' \
      "$preset" "$minimum" "$vault_version" >&2
    exit 2
  fi
}

literal_modules=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  --vault-version)
    [[ $# -ge 2 ]] || {
      echo 'ERROR: --vault-version requires a value.' >&2
      exit 2
    }
    requested_version=$2
    shift 2
    ;;
  --module)
    [[ $# -ge 2 ]] || {
      echo 'ERROR: --module requires a value.' >&2
      exit 2
    }
    literal_modules+=("$2")
    shift 2
    ;;
  --compact)
    compact=true
    shift
    ;;
  --explain)
    explain=true
    shift
    ;;
  --list)
    list_presets
    exit 0
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  --*)
    printf 'ERROR: unknown option: %s\n' "$1" >&2
    exit 2
    ;;
  *)
    selections+=("$(printf '%s' "$1" | tr '[:upper:]_' '[:lower:]-')")
    shift
    ;;
  esac
done

if [[ -n "$requested_version" ]]; then
  vault_version=$(normalize_version "$requested_version")
elif command -v vault >/dev/null 2>&1; then
  vault_version=$(normalize_version "$(vault version | awk '{print $2}')")
else
  echo 'ERROR: Vault is not installed; supply --vault-version VERSION.' >&2
  exit 127
fi

if [[ ! "$vault_version" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  printf 'ERROR: invalid Vault version: %s\n' "$vault_version" >&2
  exit 2
fi

if [[ ${#selections[@]} -eq 0 && ${#literal_modules[@]} -eq 0 ]]; then
  echo 'ERROR: select at least one preset or use --module MODULE.' >&2
  echo 'Run with --list to see the available presets.' >&2
  exit 2
fi

for preset in "${selections[@]}"; do
  case "$preset" in
  standard) ;;
  plus)
    add_module governance-policy
    ;;
  premium)
    add_module multi-dc-scale
    add_module governance-policy
    ;;
  platform)
    require_version "$preset" 2.0.0
    add_module platform-standard
    ;;
  platform-kmip | platform+kmip)
    require_version "$preset" 2.0.0
    add_module platform-standard
    add_module advanced-data-protection-key-management
    ;;
  self-managed | self-managed-packaging)
    add_module multi-dc-scale
    add_module governance-policy
    if version_at_least "$vault_version" 1.8.0; then
      add_module advanced-data-protection-transform
      add_module advanced-data-protection-key-management
    else
      add_module advanced-data-protection
    fi
    ;;
  adp)
    add_module advanced-data-protection-transform
    add_module advanced-data-protection-key-management
    ;;
  adp-km | kmip)
    add_module advanced-data-protection-key-management
    ;;
  adp-transform | transform)
    add_module advanced-data-protection-transform
    ;;
  pki-only)
    require_version "$preset" 1.21.1
    add_module pki-only
    ;;
  agentic-iam)
    require_version "$preset" 2.1.0
    add_module agentic-iam
    ;;
  *)
    printf 'ERROR: unknown preset: %s\n' "$preset" >&2
    echo 'Run with --list to see the available presets.' >&2
    exit 2
    ;;
  esac
done

for module in "${literal_modules[@]}"; do
  add_module "$module"
done

# PKI-only is a packaging mode, not an additive entitlement. If it appears via
# either a preset or --module, it intentionally replaces the complete module
# selection so an invalid mixed parameters block can never be emitted.
if has_module pki-only; then
  require_version pki-only 1.21.1
  if [[ ${#modules[@]} -gt 1 ]]; then
    echo 'NOTICE: pki-only overrides all other selected modules; emitting only pki-only.' >&2
  fi
  modules=(pki-only)
fi

if [[ "$explain" == true ]]; then
  printf 'Vault version: %s\n' "$vault_version" >&2
  printf 'Presets: %s\n' "${selections[*]:-(none)}" >&2
  if [[ ${#modules[@]} -eq 0 ]]; then
    echo 'Modules: (none)' >&2
  else
    printf 'Modules:\n' >&2
    printf '  - %s\n' "${modules[@]}" >&2
  fi
fi

if ! command -v jq >/dev/null 2>&1; then
  echo 'ERROR: jq is required to produce the JSON parameters block.' >&2
  exit 127
fi

parameters=$(printf '%s\n' "${modules[@]}" | jq -Rs \
  '{modules: (split("\n") | map(select(length > 0)))}')

if [[ "$compact" == true ]]; then
  printf '%s\n' "$parameters" | jq -c .
else
  printf '%s\n' "$parameters"
fi
