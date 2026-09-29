# Break Glass

Emergency access to RESTRICTED data, built on **Vault Control Groups**. Vault
enforces the approval and releases the answer; the application only
orchestrates.

## Why normal access is denied

RESTRICTED documents are encrypted under `durin-<tenant>-restricted`. The
operator's tenant policy (`durin-transit-<tenant>`) can encrypt and rewrap
with that key but can't decrypt with it. Opening a RESTRICTED document returns
Vault's own verdict:

```text
GET /api/v1/documents/<id>/content
403 vault_denied — "NORMAL ACCESS DENIED — Vault refused decrypt on the restricted key."
    breakGlassRequired: true      authority: { role: tenant-acme, user: raymon, source: auth/jwt }
```

## Lifecycle

```text
 requester (viewer|operator)        security-admin                  Vault
 ───────────────────────────        ──────────────                  ─────
 POST /break-glass/request
   backend logs the REQUESTER in ─────────────────────────────────► auth/jwt role breakglass-requester-<t>
   transit/decrypt restricted ────────────────────────────────────► control_group: 1 approval from
                                                                     group durin-security-admins
                                                     ◄──────────── wrapping token (NOT plaintext)
   backend keeps the wrapping token in memory; stores its accessor
                                    POST /:id/approve
                                      backend logs the APPROVER in ► auth/jwt role breakglass-approver
                                      sys/control-group/authorize ─► entity ∈ durin-security-admins? ✓
 GET /documents/:id/content
   x-break-glass-request: <id>  (same identity as the requester)
   sys/wrapping/unwrap ───────────────────────────────────────────► released ONCE
 ◄── plaintext, status: used, normalAccessRestored: true
```

| State | Entered by | In Vault |
| --- | --- | --- |
| `pending` | `POST /break-glass/request` | control-group request awaiting authorisation |
| `approved` | `POST /:id/approve` (security-admin) | authorised by an entity in `durin-security-admins` |
| `used` | first redemption by the requester | wrapping token consumed |
| `denied` | `POST /:id/deny` | never authorised: the answer can never be released |
| `revoked` | `POST /:id/revoke` | wrapping token discarded; expires with the control-group TTL |
| `expired` | 15 minutes after the request | wrapping token expired |

## Controls

| Abuse | Refused by |
| --- | --- |
| Normal access to RESTRICTED data | **Vault**: operator policy has no decrypt on the restricted key |
| Release without approval | **Vault**: "Request needs further authorization" |
| Approval by a non-security-admin | **Vault**: not in `durin-security-admins`; backend RBAC |
| Security-admin requesting (to self-approve) | **Vault**: `breakglass-requester-*` bound claims admit only viewers and operators |
| Requester approving own request | Backend (`separation_of_duties`) and backend RBAC |
| Second release | **Vault**: single-use unwrap; backend `status = used` |
| Someone else redeeming | Backend: redemption requires the requester's identity (`break_glass_not_requester`) |
| Other tenant | **Vault**: requester role bound to the tenant; backend tenant checks |
| Late use | **Vault**: 15-minute control-group TTL |

The Vault wrapping token never leaves the backend. The lead prompt forbids
Vault credentials in the frontend. If the backend restarts, pending answers
are lost and redemption fails with `break_glass_authority_lost` (fail closed:
request again).

The wrapping token is a child of the requester's Vault token, so that token
lives for the full 15-minute window (verified live). It can only ever *ask*
for decrypts that always need approval.

## Evidence

- App audit: `BREAK_GLASS_REQUEST` (requester, reason, wrapping accessor,
  requester entity), `BREAK_GLASS_APPROVED` (approver, Vault authorisations),
  `BREAK_GLASS_RECOVER` (source `vault`), `BREAK_GLASS_DENIED`,
  `BREAK_GLASS_REVOKED`, `BREAK_GLASS_EXPIRED`.
- Vault audit: the requester's login and decrypt request, the approver's
  login and `sys/control-group/authorize`, and the unwrap, each with its
  `auth.metadata.username`.
- Vault state at any time (admin): `vault write sys/control-group/request accessor=<wrapping accessor>`.

## Demo walkthrough

```bash
source scripts/lib/durin-auth.sh
B=http://localhost:3001/api/v1
VIEWER=$(durin_token viewer); SEC=$(durin_token security-admin)
DOC=$(curl -s -H "Authorization: Bearer $VIEWER" -H 'x-tenant: acme' $B/documents | jq -r '[.data[]|select(.name|test("#1842"))][0].id')

BG=$(curl -s -X POST $B/break-glass/request -H "Authorization: Bearer $VIEWER" -H 'x-tenant: acme' \
  -H 'content-type: application/json' -d "{\"resource_id\":\"$DOC\",\"reason\":\"Production incident investigation\"}" | jq -r .data.id)

curl -s -H "Authorization: Bearer $VIEWER" -H 'x-tenant: acme' -H "x-break-glass-request: $BG" $B/documents/$DOC/content | jq .error  # "break_glass_pending"
curl -s -X POST -H "Authorization: Bearer $SEC" $B/break-glass/$BG/approve | jq .data.vault                                             # approved in Vault
curl -s -H "Authorization: Bearer $VIEWER" -H 'x-tenant: acme' -H "x-break-glass-request: $BG" $B/documents/$DOC/content | jq .meta.breakGlass
curl -s -H "Authorization: Bearer $VIEWER" -H 'x-tenant: acme' -H "x-break-glass-request: $BG" $B/documents/$DOC/content | jq .error  # "break_glass_used"
```
