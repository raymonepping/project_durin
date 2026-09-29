#!/usr/bin/env bash
# scripts/verify-stack.sh
# ---------------------------------------------------------------------------
# INHERITED FROM ARCANIUM, NOT YET ADAPTED FOR FACTORY — kept as reference
# only, not renamed.
#
# Everything below this notice is arcanium's own application-specific
# smoke-test suite: its OIDC login flow, its persona list
# (demo-operator/demo-ciso/etc.), its auth/authorize.js authorization
# matrix, and routes for features Factory does not have (HSM, KMIP, PKI,
# document-signing, external-supplier, payments-api). A blind rename
# (arcanium -> factory) would produce a script that LOOKS like it verifies
# The Factory but actually checks for containers and routes that will
# never exist here — worse than leaving it clearly unadapted. See
# prompts/base_project/01_01_factory_stack.md's "Reused tooling" section:
# a careful, reviewed rename, not a blind regex, and some files turn out
# to be content, not naming.
#
# The STRUCTURE is worth reusing once Factory's own backend/agents/
# frontend exist (prompts/backend/01_01, prompts/agents/*, prompts/frontend/01_01):
# sectioned checks, colour output, exit 0 only if everything passes,
# warnings that don't fail the run. A real Factory verification script
# should check things like: /api/demo/mode, /api/tasks, /api/credentials,
# the /tools/* endpoints, each agent's health, and that Vault issues
# database/creds/factory-bad-role and factory-good-role successfully —
# not this file's arcanium-specific routes. Write that as its own script
# (and its own prompt) once those components exist; do not try to
# retrofit this one.
# ---------------------------------------------------------------------------
#
# Arcanium stack verification — exercises every exposed API route and workload
# health endpoint. Intended as a post-start smoke test and traceability check.
#
# Prompt 18, Deliverable 8: most Arcanium API routes require a valid session
# once ARCANIUM_AUTH_ENABLED=true (deny-by-default, Deliverable 5) — those
# checks correctly 401 without --user/--password. This script predates OIDC
# login; --user/--password perform the real Authorization Code + PKCE flow
# (the same pattern scenarios/11_security_foundation/test_negative_auth.sh
# and scenarios/13_fitness/test_architecture_invariants.sh already use) and
# thread the resulting session cookie through every API call this script
# makes. With no --user, behavior is unchanged (a lab running with
# ARCANIUM_AUTH_ENABLED=false needs no credentials; the Vault-cluster/
# container/workload-health sections never needed Arcanium API auth anyway).
#
# Exit code: 0 if all checks pass, 1 if any fail.
# ---------------------------------------------------------------------------
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-stack.sh [OPTIONS]

Smoke-tests every exposed Arcanium API route, workload health endpoint,
the Vault cluster, and container health. Exit 0 if all checks pass, 1 if
any fail (warnings never fail the run).

Options:
  --user <username>      OIDC username to authenticate as before running
                          checks (e.g. demo-operator — see docs/personas.md
                          for the full demo account list). Required once
                          the API has ARCANIUM_AUTH_ENABLED=true; without
                          it, session-requiring routes correctly 401 and
                          are reported as failures, not skipped.
  --password <password>  Password for --user. If --user is given without
                          --password, you will be prompted (input hidden).
  --no-vault              Skip Vault cluster checks (no Vault token needed).
  -h, --help              Show this help and exit.

Environment overrides:
  ARCANIUM_API   Arcanium API base URL           (default: http://localhost:3001)
  VAULT_ADDR     Main Vault cluster address       (default: https://127.0.0.1:18200)
  VAULT_CACERT   CA bundle for Vault TLS          (default: <repo>/vault-tls/ca-chain.pem)
  SECRETS_DIR    Where cluster-init.json lives    (default: <repo>/.secrets/vault)

The full check suite (sections 2-6) exercises create/update/delete on an
ephemeral test application. Authenticate as a persona with provisioning
rights (demo-operator or demo-architect) to exercise those checks for
real; a persona without them (demo-ciso, demo-auditor — see
auth/authorize.js's MATRIX) still exits 0 on a healthy stack — the
resulting 403s are reported as warnings ("lacks this action's rights,
not a stack defect"), not failures, since that's the authorization
matrix working as designed, not a problem to fix.

Examples:
  ./scripts/verify-stack.sh
  ./scripts/verify-stack.sh --user demo-operator --password 'Arcanium-ops-2026'
  ./scripts/verify-stack.sh --user demo-operator          # prompts for password
  ./scripts/verify-stack.sh --no-vault --user demo-auditor
EOF
}

# ── Colours ─────────────────────────────────────────────────────────────────
GRN='\033[0;32m'
RED='\033[0;31m'
YLW='\033[0;33m'
BLD='\033[1m'
RST='\033[0m'

# ── Config (override via env) ────────────────────────────────────────────────
API="${ARCANIUM_API:-http://localhost:3001}"
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18200}"
VAULT_CACERT="${VAULT_CACERT:-$(cd "$(dirname "$0")/.." && pwd)/vault-tls/ca-chain.pem}"
SECRETS_DIR="${SECRETS_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.secrets/vault}"
SKIP_VAULT=false
AUTH_USER=""
AUTH_PASSWORD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
  --no-vault)
    SKIP_VAULT=true
    shift
    ;;
  --user)
    AUTH_USER="${2:?--user requires a value}"
    shift 2
    ;;
  --password)
    AUTH_PASSWORD="${2:?--password requires a value}"
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown option: $1" >&2
    usage >&2
    exit 64
    ;;
  esac
done

if [[ -n "$AUTH_USER" && -z "$AUTH_PASSWORD" ]]; then
  read -rsp "Password for $AUTH_USER: " AUTH_PASSWORD
  echo >&2
fi

# ── Session auth (Prompt 18, Deliverable 8) ───────────────────────────────────
# Empty when --user wasn't given — every curl call below splices in
# "${AUTH_OPTS[@]}", which is a no-op (unchanged behavior) in that case.
JAR=""
AUTH_OPTS=()
UNAUTH_401=0

cleanup_jar() { [[ -n "$JAR" ]] && rm -f "$JAR"; }
trap cleanup_jar EXIT

# Authorization Code + PKCE login against Express (auth/index.js) — same
# pattern as scenarios/11_security_foundation/test_negative_auth.sh and
# scenarios/13_fitness/test_architecture_invariants.sh's oidc_login().
oidc_login() {
  local user="$1" pass="$2" jar="$3"
  : >"$jar"
  local login_headers auth_url form_html form_action cb_headers cb_url qs
  login_headers=$(curl -sD - -o /dev/null -c "$jar" "$API/api/v1/auth/login?next=/" 2>/dev/null)
  auth_url=$(echo "$login_headers" | grep -i '^location:' | awk '{print $2}' | tr -d '\r\n')
  if [[ -z "$auth_url" ]]; then
    echo "  Could not reach $API/api/v1/auth/login — is the API up?" >&2
    return 1
  fi
  form_html=$(curl -s -c "$jar" -b "$jar" "$auth_url")
  form_action=$(echo "$form_html" | grep -oE 'action="[^"]*"' | head -1 |
    sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
  if [[ -z "$form_action" ]]; then
    echo "  Could not find the Keycloak login form — is the identity stack up (make identity-up)?" >&2
    return 1
  fi
  cb_headers=$(curl -sD - -o /dev/null -c "$jar" -b "$jar" \
    --data-urlencode "username=$user" --data-urlencode "password=$pass" \
    "$form_action")
  cb_url=$(echo "$cb_headers" | grep -i '^location:' | awk '{print $2}' | tr -d '\r\n')
  if [[ -z "$cb_url" ]]; then
    echo "  Login form submission did not redirect — wrong username/password?" >&2
    return 1
  fi
  case "$cb_url" in
  *auth/callback*) ;;
  *)
    echo "  Unexpected redirect after login: $cb_url" >&2
    return 1
    ;;
  esac
  qs="${cb_url#*\?}"
  curl -s -o /dev/null -c "$jar" -b "$jar" "$API/api/v1/auth/callback?$qs"
  grep -q arc_session "$jar" 2>/dev/null
}

if [[ -n "$AUTH_USER" ]]; then
  JAR=$(mktemp)
  if oidc_login "$AUTH_USER" "$AUTH_PASSWORD" "$JAR"; then
    AUTH_OPTS=(-b "$JAR")
    echo "  Authenticated as $AUTH_USER"
  else
    echo "Login failed for $AUTH_USER — aborting (pass a valid --user/--password, or omit both to run unauthenticated)." >&2
    exit 1
  fi
fi
unset AUTH_PASSWORD

# ── State ────────────────────────────────────────────────────────────────────
PASS=0
FAIL=0
WARN=0
APP_ID=""
SUPPLIER_ID=""

# ── Helpers ──────────────────────────────────────────────────────────────────
pass() {
  echo -e "  ${GRN}✓${RST}  $*"
  ((PASS++))
}
fail() {
  echo -e "  ${RED}✗${RST}  $*"
  ((FAIL++))
}
warn() {
  echo -e "  ${YLW}~${RST}  $*"
  ((WARN++))
}
section() { echo -e "\n${BLD}▸ $*${RST}"; }
hr() { echo "  ──────────────────────────────────────────────"; }

# Check HTTP status + optional jq expression.
# check <label> <expected_status> <url> [method] [body] [jq_expr]
check() {
  local label="$1" expected="$2" url="$3"
  local method="${4:-GET}" body="${5:-}" jq_expr="${6:-}"
  # Use -s (silent) not -sf (-f exits non-zero on 4xx/5xx which we want to capture)
  local args=(-s -o /tmp/arc_verify_body -w "%{http_code}" --max-time 8 "${AUTH_OPTS[@]}")
  [[ "$method" != "GET" ]] && args+=(-X "$method")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")

  local status
  status=$(curl "${args[@]}" "$url" 2>/dev/null) || status="000"
  local body_text
  body_text=$(cat /tmp/arc_verify_body 2>/dev/null || echo "")

  if [[ "$status" != "$expected" ]]; then
    [[ "$status" == "401" && -z "$JAR" ]] && ((UNAUTH_401++))
    # A 403 from Arcanium's own deny-by-default authorize() (auth/authorize.js's
    # MATRIX) means the authenticated persona genuinely doesn't have this
    # action's rights (e.g. demo-ciso/demo-auditor have provision:false) —
    # that's the authorization matrix working correctly, not a stack defect.
    # Reported as a warning, not a failure, so a full run can exit 0 with a
    # read/approve-oriented persona instead of always showing provisioning
    # checks as broken.
    if [[ "$status" == "403" && "$body_text" == *'"reason":"no matching allow rule"'* ]]; then
      warn "$label  [expected $expected, got 403 — $AUTH_USER lacks this action's rights, not a stack defect]"
      return
    fi
    fail "$label  [expected $expected, got $status]  ${body_text:0:120}"
    return
  fi

  if [[ -n "$jq_expr" ]]; then
    local result
    result=$(echo "$body_text" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    # evaluate simple jq-like expressions
    expr = '''$jq_expr'''
    if expr.startswith('.'):
        parts = expr.lstrip('.').split('.')
        v = d
        for p in parts:
            if isinstance(v, list) and p.isdigit():
                v = v[int(p)]
            elif isinstance(v, dict):
                v = v.get(p)
            else:
                v = None
        print(str(v))
    else:
        print(str(d))
except Exception as e:
    print(f'jq_err: {e}')
" 2>/dev/null || echo "parse_err")
    pass "$label  ${YLW}→ ${result}${RST}"
  else
    pass "$label"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BLD}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}║        Arcanium Stack Verification                   ║${RST}"
echo -e "${BLD}╚══════════════════════════════════════════════════════╝${RST}"
echo -e "  API:        $API"
echo -e "  Vault:      $VAULT_ADDR"
echo -e "  Timestamp:  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# ── 1. Health endpoints ───────────────────────────────────────────────────────
section "1. Arcanium API — Health"
check "GET /health/live" 200 "$API/health/live" GET "" ".status"
check "GET /health/ready" 200 "$API/health/ready" GET "" ".status"
check "GET /health" 200 "$API/health" GET "" ".status"

# Extract version from health for display
VERSION=$(curl -sf --max-time 5 "${AUTH_OPTS[@]}" "$API/health" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
echo -e "     ${YLW}API version: $VERSION${RST}"

# ── 2. Applications ────────────────────────────────────────────────────────────
section "2. Applications"
check "GET  /api/v1/applications" 200 "$API/api/v1/applications" GET "" ".0.name"

# Pick an existing app_id for detail/patch tests
APP_ID=$(curl -sf --max-time 5 "${AUTH_OPTS[@]}" "$API/api/v1/applications" 2>/dev/null |
  python3 -c "import sys,json; apps=json.load(sys.stdin); print(apps[0]['id'] if apps else '')" 2>/dev/null || echo "")

if [[ -n "$APP_ID" ]]; then
  check "GET  /api/v1/applications/:id" 200 "$API/api/v1/applications/$APP_ID" GET "" ".name"
  check "GET  /api/v1/applications/:id (profiles)" 200 "$API/api/v1/applications/$APP_ID" GET "" ".crypto_profiles"
  check "PATCH /api/v1/applications/:id" 200 "$API/api/v1/applications/$APP_ID" \
    PATCH '{"description":"verified by verify-stack.sh"}' ".description"
else
  warn "No applications registered — skipping detail/patch checks"
fi

# POST + DELETE lifecycle (ephemeral test app), plus the duplicate-name
# check against that SAME ephemeral app while it still exists. Found live:
# this used to hardcode {"name":"payments-api"} for the duplicate check,
# assuming a real "payments-api" application was already registered (true
# after onboarding, false right after a clean-slate reset) — against an
# empty deployment there was nothing to collide with, so the POST didn't
# 409, it silently CREATED a real, permanent "payments-api" application as
# a side effect of running verification. Testing duplicate-detection
# against our own ephemeral app's name removes the dependency on any
# specific pre-existing application ever existing.
TEST_APP=$(curl -sf --max-time 5 "${AUTH_OPTS[@]}" -X POST "$API/api/v1/applications" \
  -H "Content-Type: application/json" \
  -d '{"name":"verify-stack-test-app","description":"ephemeral smoke test"}' 2>/dev/null |
  python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")

if [[ -n "$TEST_APP" ]]; then
  pass "POST /api/v1/applications  → $TEST_APP"

  # 409 on duplicate name (use -s not -sf so 4xx doesn't cause non-zero exit)
  DUPE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${AUTH_OPTS[@]}" \
    -X POST "$API/api/v1/applications" \
    -H "Content-Type: application/json" \
    -d '{"name":"verify-stack-test-app"}' 2>/dev/null || echo "000")
  [[ "$DUPE" == "409" ]] && pass "POST /api/v1/applications 409 on duplicate name" ||
    warn "POST duplicate name returned $DUPE (expected 409)"

  STATUS=$(curl -sf -o /dev/null -w "%{http_code}" --max-time 5 "${AUTH_OPTS[@]}" \
    -X DELETE "$API/api/v1/applications/$TEST_APP" 2>/dev/null || echo "000")
  if [[ "$STATUS" == "204" ]]; then pass "DELETE /api/v1/applications/:id"; else fail "DELETE /api/v1/applications/:id  [got $STATUS]"; fi
else
  warn "Could not create ephemeral test app (409 name conflict is OK, 401/403 means --user needs provisioning rights) — duplicate-name check skipped"
fi

# ── 3. Transit Keys ─────────────────────────────────────────────────────────
section "3. Transit Keys"
check "GET  /api/v1/keys" 200 "$API/api/v1/keys" GET "" ".0.name"
check "GET  /api/v1/keys/payments-api-key" 200 "$API/api/v1/keys/payments-api-key" GET "" ".name"
check "GET  /api/v1/keys/external-supplier-key" 200 "$API/api/v1/keys/external-supplier-key" GET "" ".type"
check "GET  /api/v1/keys/document-signing-key" 200 "$API/api/v1/keys/document-signing-key" GET "" ".name"
check "GET  /api/v1/keys/:name 404" 404 "$API/api/v1/keys/nonexistent-key-xyz" GET

# ── 4. PKI ──────────────────────────────────────────────────────────────────
section "4. PKI"
check "GET  /api/v1/pki/ca-chain" 200 "$API/api/v1/pki/ca-chain"
CA_BODY=$(cat /tmp/arc_verify_body 2>/dev/null || echo "")
[[ "$CA_BODY" == *"BEGIN CERTIFICATE"* ]] && pass "PKI ca-chain contains PEM certificate" ||
  fail "PKI ca-chain missing PEM content"
check "GET  /api/v1/pki/roles" 200 "$API/api/v1/pki/roles"

# ── 5. Suppliers ─────────────────────────────────────────────────────────────
section "5. Suppliers"
check "GET  /api/v1/suppliers" 200 "$API/api/v1/suppliers" GET "" ".0.name"

SUPPLIER_ID=$(curl -sf --max-time 5 "${AUTH_OPTS[@]}" "$API/api/v1/suppliers" 2>/dev/null |
  python3 -c "import sys,json; s=json.load(sys.stdin); print(s[0]['id'] if s else '')" 2>/dev/null || echo "")

if [[ -n "$SUPPLIER_ID" ]]; then
  check "GET  /api/v1/suppliers/:id" 200 "$API/api/v1/suppliers/$SUPPLIER_ID" GET "" ".name"
  check "GET  /api/v1/suppliers/:id/applications" 200 "$API/api/v1/suppliers/$SUPPLIER_ID/applications" GET "" ""
  check "GET  /api/v1/suppliers/:id/keys" 200 "$API/api/v1/suppliers/$SUPPLIER_ID/keys" GET "" ""
else
  warn "No suppliers registered — skipping supplier detail checks"
fi

# ── 6. Approvals ─────────────────────────────────────────────────────────────
section "6. Approvals"
check "GET  /api/v1/approvals (pending)" 200 "$API/api/v1/approvals" GET "" ""
check "GET  /api/v1/approvals?all=true" 200 "$API/api/v1/approvals?all=true" GET "" ""

# Count pending / approved / rejected
APPROVAL_SUMMARY=$(curl -sf --max-time 5 "${AUTH_OPTS[@]}" "$API/api/v1/approvals?all=true" 2>/dev/null |
  python3 -c "
import sys,json
rows=json.load(sys.stdin)
by_status={}
for r in rows:
    s=r['status']; by_status[s]=by_status.get(s,0)+1
parts=[f\"{s}={n}\" for s,n in sorted(by_status.items())]
print(', '.join(parts) or 'empty')
" 2>/dev/null || echo "parse error")
echo -e "     ${YLW}Approval breakdown: $APPROVAL_SUMMARY${RST}"

# Fetch the newest pending approval for traceability
NEWEST_PENDING=$(curl -sf --max-time 5 "${AUTH_OPTS[@]}" "$API/api/v1/approvals" 2>/dev/null |
  python3 -c "
import sys,json
rows=sorted(json.load(sys.stdin), key=lambda r: r['created_at'], reverse=True)
if rows: print(rows[0]['id']+' acc='+str(rows[0].get('accessor','none'))[:28])
else: print('none')
" 2>/dev/null || echo "none")
echo -e "     ${YLW}Newest pending: $NEWEST_PENDING${RST}"

# ── 7. Workload health endpoints ──────────────────────────────────────────────
section "7. Workload Health Endpoints"
check "payments-api    :3002/health" 200 "http://localhost:3002/health" GET "" ".status"
check "pki-client      :3003/health" 200 "http://localhost:3003/health" GET "" ".status"
check "kmip-client     :3007/health" 200 "http://localhost:3007/health" GET "" ".status"
check "external-supplier :3005/health" 200 "http://localhost:3005/health" GET "" ".status"
DOC_STATUS=$(curl -sf -o /tmp/arc_verify_body -w "%{http_code}" --max-time 5 "http://localhost:3006/health" 2>/dev/null || echo "000")
if [[ "$DOC_STATUS" == "200" ]]; then
  pass "document-signing  :3006/health"
else
  warn "document-signing :3006 not reachable (port not published — ok if no host mapping)"
fi

# pki-client cert detail
CERT_INFO=$(curl -sf --max-time 5 "http://localhost:3003/cert" 2>/dev/null |
  python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"serial={str(d.get('serial','?'))[:20]} expires={d.get('expiresAt','?')[:19]}\")" \
    2>/dev/null || echo "unavailable")
echo -e "     ${YLW}pki-client cert: $CERT_INFO${RST}"

# payments-api key version
PAYMENTS_INFO=$(curl -sf --max-time 5 "http://localhost:3002/health" 2>/dev/null |
  python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"key={d.get('transitKey','?')} v{d.get('keyVersion','?')}\")" \
    2>/dev/null || echo "unavailable")
echo -e "     ${YLW}payments-api:    $PAYMENTS_INFO${RST}"

# ── 8. Vault cluster ──────────────────────────────────────────────────────────
section "8. Vault Cluster"

if $SKIP_VAULT; then
  warn "Vault checks skipped (--no-vault)"
else
  for node_port in "vault-s:18190" "vault-1:18200" "vault-2:18201" "vault-3:18202"; do
    node="${node_port%%:*}"
    port="${node_port##*:}"
    STATUS_JSON=$(curl -sk --max-time 5 \
      "https://127.0.0.1:${port}/v1/sys/health?standbyok=true&sealedok=true&uninitok=false" \
      2>/dev/null || echo "{}")
    VERSION=$(echo "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
    SEALED=$(echo "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed','?'))" 2>/dev/null || echo "?")
    STANDBY=$(echo "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('standby','?'))" 2>/dev/null || echo "?")
    HA=$(echo "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ha_enabled','?'))" 2>/dev/null || echo "?")

    if [[ "$VERSION" == "?" ]]; then
      fail "$node  :$port  unreachable"
    elif [[ "$SEALED" == "True" ]] || [[ "$SEALED" == "true" ]]; then
      fail "$node  :$port  SEALED  version=$VERSION"
    else
      ROLE="active"
      [[ "$STANDBY" == "True" || "$STANDBY" == "true" ]] && ROLE="standby"
      pass "$node  :$port  $ROLE  version=$VERSION  ha=$HA"
    fi
  done

  # vault-hsm (seal provider)
  HSM_JSON=$(curl -sk --max-time 5 \
    "https://127.0.0.1:18300/v1/sys/health?standbyok=true&sealedok=true&uninitok=false" \
    2>/dev/null || echo "{}")
  HSM_VER=$(echo "$HSM_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
  HSM_SEALED=$(echo "$HSM_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sealed','?'))" 2>/dev/null || echo "?")
  if [[ "$HSM_VER" == "?" ]]; then
    fail "vault-hsm :18300  unreachable"
  elif [[ "$HSM_SEALED" == "True" || "$HSM_SEALED" == "true" ]]; then
    fail "vault-hsm :18300  SEALED"
  else
    pass "vault-hsm :18300  version=$HSM_VER  (transit auto-unseal provider)"
  fi

  # Vault license
  TOKEN_FILE="$SECRETS_DIR/cluster-init.json"
  if [[ -f "$TOKEN_FILE" ]]; then
    VAULT_TOKEN_VAL=$(python3 -c "import json; print(json.load(open('$TOKEN_FILE'))['root_token'])" 2>/dev/null || echo "")
    if [[ -n "$VAULT_TOKEN_VAL" ]]; then
      LIC_JSON=$(curl -sk --max-time 5 \
        -H "X-Vault-Token: $VAULT_TOKEN_VAL" \
        "https://127.0.0.1:18200/v1/sys/license/status" \
        --cacert "$VAULT_CACERT" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
ld=d.get('data',{}).get('autoloaded',d.get('data',{}))
print(ld.get('expiration_time','?')[:10])
" 2>/dev/null || echo "?")
      CG=$(curl -sk --max-time 5 \
        -H "X-Vault-Token: $VAULT_TOKEN_VAL" \
        "https://127.0.0.1:18200/v1/sys/license/status" \
        --cacert "$VAULT_CACERT" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
feat=str(d)
print('YES' if 'Control Groups' in feat else 'NO')
" 2>/dev/null || echo "?")
      pass "Vault license  expiry=$LIC_JSON  control_groups=$CG"
    else
      warn "Could not read root token from $TOKEN_FILE"
    fi
  else
    warn "No cluster-init.json found — skipping license check"
  fi

  # Cluster membership
  if [[ -n "${VAULT_TOKEN_VAL:-}" ]]; then
    MEMBERS=$(curl -sk --max-time 5 \
      -H "X-Vault-Token: $VAULT_TOKEN_VAL" \
      "https://127.0.0.1:18200/v1/sys/storage/raft/autopilot/state" \
      --cacert "$VAULT_CACERT" 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
servers=d.get('data',{}).get('servers',{})
lines=[]
for name,info in servers.items():
    lines.append(f'{name} status={info.get(\"status\",\"?\")} leader={info.get(\"leader\",False)}')
print(' | '.join(lines) or 'unavailable')
" 2>/dev/null || echo "unavailable")
    echo -e "     ${YLW}Raft members: $MEMBERS${RST}"
  fi
fi

# ── 9. Container health (Podman) ───────────────────────────────────────────────
section "9. Container Status (podman ps)"
CONTAINERS=(
  "arcanium-postgres"
  "arcanium-softhsm_server"
  "arcanium-vault_hsm"
  "arcanium-vault_s"
  "arcanium-vault_1"
  "arcanium-vault_2"
  "arcanium-vault_3"
  "arcanium-api"
  "arcanium-payments-api"
  "arcanium-pki-client"
  "arcanium-kmip-client"
  "arcanium-document-signing"
  "arcanium-external-supplier"
)
for cname in "${CONTAINERS[@]}"; do
  STATUS=$(podman inspect "$cname" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  HEALTH=$(podman inspect "$cname" --format '{{.State.Health.Status}}' 2>/dev/null || echo "")
  if [[ "$STATUS" == "running" ]]; then
    DETAIL="running"
    [[ -n "$HEALTH" && "$HEALTH" != "<no value>" ]] && DETAIL="$STATUS ($HEALTH)"
    if [[ "$HEALTH" == "unhealthy" ]]; then
      fail "$cname  $DETAIL"
    else
      pass "$cname  $DETAIL"
    fi
  else
    fail "$cname  status=$STATUS"
  fi
done

# Prompt 29, Deliverable 7 — the hand-maintained CONTAINERS list above is
# "the containers that matter," curated by memory. It missed arcanium-
# ldap-admin entirely: compose/identity/compose.yaml defines it with no
# profiles: restriction, so `make identity-up`'s bare `up -d` should start
# it — but after a full `make rehydrate` it was not running at all (not
# even stopped), and nothing here would have said so. This block derives
# the expected set programmatically from every compose/*/compose.yaml
# instead of trusting a curated list.
#
# One documented exclusion: arcanium-api-dev (compose/arcanium/
# compose.yaml) carries no profiles: tag either, but `make arcanium-up`
# deliberately starts only `arcanium-ui arcanium-api arcanium-worker` —
# api-dev is an explicit opt-in (`make arcanium-api-dev-up`), not part of
# the default bring-up, so its absence is not a gap. Checked against every
# other compose file's own actual `up -d` invocation in the Makefile: none
# of them name an explicit subset, so every other non-profiled service is
# expected to be running.
EXPECTED_SERVICES=$(
  for f in compose/*/compose.yaml; do
    awk '
      /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
        if (svc != "" && cname != "" && !profiled) print cname
        svc = $1; cname = ""; profiled = 0; next
      }
      /^    container_name:/ { cname = $2; gsub(/^[ \t]+|[ \t]+$/, "", cname); next }
      /^    profiles:/ { profiled = 1; next }
      END { if (svc != "" && cname != "" && !profiled) print cname }
    ' "$f" 2>/dev/null
  done | grep -v '^arcanium-api-dev$' | sort -u
)
MISSING_SERVICES=""
while IFS= read -r cname; do
  [ -z "$cname" ] && continue
  STATUS=$(podman inspect "$cname" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
  [ "$STATUS" != "running" ] && MISSING_SERVICES="${MISSING_SERVICES}${cname} "
done <<<"$EXPECTED_SERVICES"
if [ -z "$MISSING_SERVICES" ]; then
  pass "every non-profile-gated compose service is running (full inventory, not the curated list above)"
else
  fail "compose-defined services not running: ${MISSING_SERVICES}"
fi

# ── 10. 4xx / error contract spot-checks ──────────────────────────────────────
section "10. Error Contract"
check "GET  /api/v1/applications/bad-uuid  → 400" 400 "$API/api/v1/applications/not-a-uuid"
check "GET  /api/v1/applications/unknown   → 404" 404 "$API/api/v1/applications/00000000-0000-0000-0000-000000000000"
check "GET  /api/v1/keys/nonexistent       → 404" 404 "$API/api/v1/keys/no-such-key"
check "GET  /unknown-route                 → 404" 404 "$API/totally-unknown-route"
check "POST /api/v1/applications (no name) → 400" 400 "$API/api/v1/applications" POST '{}'

# ── Summary ───────────────────────────────────────────────────────────────────
hr
TOTAL=$((PASS + FAIL + WARN))
echo ""
if [[ $FAIL -eq 0 ]]; then
  echo -e "${GRN}${BLD}  ✓ All checks passed${RST}  (${PASS} pass, ${WARN} warn, ${FAIL} fail / ${TOTAL} total)"
else
  echo -e "${RED}${BLD}  ✗ Some checks failed${RST}  (${PASS} pass, ${WARN} warn, ${FAIL} fail / ${TOTAL} total)"
fi
if [[ -z "$JAR" && $UNAUTH_401 -gt 0 ]]; then
  echo -e "  ${YLW}$UNAUTH_401 check(s) failed with 401 — this deployment has ARCANIUM_AUTH_ENABLED=true.${RST}"
  echo -e "  ${YLW}Re-run with --user <username> --password <password> (see --help).${RST}"
fi
echo ""

[[ $FAIL -eq 0 ]]
