#!/usr/bin/env bash
# Inspect every .hclic file in a directory and present its entitlements clearly.
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: vault-license-inspect.sh [DIRECTORY]

Inspect all .hclic files directly inside DIRECTORY (default: current directory).
The report omits customer, license, and installation identifiers.
EOF
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

directory=${1:-.}

if [[ $# -gt 1 ]]; then
  usage >&2
  exit 2
fi

if [[ ! -d "$directory" ]]; then
  printf 'ERROR: directory does not exist: %s\n' "$directory" >&2
  exit 2
fi

if ! command -v vault >/dev/null 2>&1; then
  echo 'ERROR: vault is not installed or is not in PATH.' >&2
  exit 127
fi

# Some reference files contain a label or shell assignment before the payload.
# Feed only the actual license payload to `vault license inspect`.
license_payload() {
  local file=$1 first_line
  IFS= read -r first_line <"$file" || true

  case "$first_line" in
  VAULT_LICENSE | VAULT_LICENSE_ENT)
    sed -n '2,$p' "$file"
    ;;
  VAULT_LICENSE=* | VAULT_LICENSE_ENT=*)
    printf '%s\n' "${first_line#*=}"
    ;;
  *)
    cat "$file"
    ;;
  esac
}

field() {
  local label=$1
  awk -v label="$label" '
    $0 ~ "^[[:space:]]*" label ":" {
      sub("^[[:space:]]*" label ":[[:space:]]*", "")
      print
      exit
    }
  '
}

print_entitlements() {
  local report=$1 line kind values item found=false

  while IFS= read -r line; do
    case "$line" in
    *"modules: ["* | *"features: ["*)
      kind=${line%%:*}
      kind=${kind##*[[:space:]]}
      values=${line#*[}
      values=${values%]*}

      if [[ "$kind" == "modules" ]]; then
        echo '  Modules:'
      else
        echo '  Features:'
      fi

      for item in $values; do
        printf '    - %s\n' "$item"
      done
      found=true
      ;;
    esac
  done <<<"$report"

  if [[ "$found" == false ]]; then
    echo '  Modules/features: none reported'
  fi
}

shopt -s nullglob
files=("$directory"/*.hclic)

if [[ ${#files[@]} -eq 0 ]]; then
  printf 'No .hclic files found in %s\n' "$directory" >&2
  exit 1
fi

printf 'Vault license inventory\n'
printf 'Directory: %s\n' "$(cd "$directory" && pwd)"
printf 'Inspector: %s\n' "$(vault version)"

invalid=0
for file in "${files[@]}"; do
  name=$(basename "$file")
  printf '\n%s\n' "$name"
  printf '%*s\n' "${#name}" '' | tr ' ' '-'

  if report=$(vault license inspect <(license_payload "$file") 2>&1); then
    signature=$(printf '%s\n' "$report" | field 'Signature')
    format=$(printf '%s\n' "$report" | field 'Format')
    product=$(printf '%s\n' "$report" | field 'Product')
    start=$(printf '%s\n' "$report" | field 'Start Time')
    expiration=$(printf '%s\n' "$report" | field 'Expiration Time')
    termination=$(printf '%s\n' "$report" | field 'Termination Time')
    non_production=$(printf '%s\n' "$report" | field 'Non-Production')

    printf '  Status: valid (signature=%s, format=%s)\n' "${signature:-unknown}" "${format:-unknown}"
    printf '  Product: %s\n' "${product:-unknown}"
    printf '  Start: %s\n' "${start:-unknown}"
    printf '  Expires: %s\n' "${expiration:-unknown}"
    printf '  Terminates: %s\n' "${termination:-unknown}"
    printf '  Non-production: %s\n' "${non_production:-unknown}"
    print_entitlements "$report"
  else
    invalid=$((invalid + 1))
    echo '  Status: INVALID'
    reason=$(printf '%s\n' "$report" | awk 'tolower($0) ~ /(error|invalid|expired|not yet valid)/ { print; exit }')
    printf '  Reason: %s\n' "${reason:-license inspection failed}"
  fi
done

printf '\nSummary: %d file(s), %d invalid\n' "${#files[@]}" "$invalid"
exit "$invalid"
