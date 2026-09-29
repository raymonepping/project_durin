# Screenshots — provenance

Every image here is a Playwright capture of the live Durin Web Console
against the running stack, with real Keycloak users and real Vault answers.
None is edited, mocked or generated.

| Folder | User | Viewport |
| --- | --- | --- |
| `desktop/` | raymon (operator, all tenants) | 1440×900, full page |
| `phone/` | raymon | 390×844, full page |
| `viewer/` | viewer (acme, globex) | 1440×900, full page |

Produced by [ui/tests/screens.spec.ts](../../ui/tests/screens.spec.ts):

```bash
make reset
cd ui && npx playwright test screens --grep @screens
```

Captures are taken after `make reset`, so story screens (Protect, Recover,
Compromise, Shield, Isolation) show their start state. Key versions and
timestamps depend on how many times the demo has run.
