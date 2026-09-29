// routes/scenarios.js — the four Durin scenarios + deterministic demo state.
//
//   PROTECT     plaintext → gateway (tenant token) → Transit → ciphertext → PostgreSQL
//   RECOVER     PostgreSQL ciphertext → gateway (tenant token) → Transit → plaintext
//   COMPROMISE  snapshot the database as an attacker would; replay it against
//               Vault with no token (attacker) or with the app's own authority
//   SHIELD      rotate → rewrap → raise min_decryption_version → re-issue
//               authority → verify, all enforced by Vault
//
// Plus the isolation probe (tenant A authority vs tenant B key → Vault decides),
// seed and reset. Every outcome reported here is Vault's actual verdict.
import { Router }   from 'express';
import { query }    from '../db.js';
import { emitAudit } from '../audit.js';
import * as gateway from '../gateway/index.js';
import { vaultGetKeyInfo } from '../vault.js';
import { describeTenantAuthority, revokeTenantAuthority, revokeAllAuthority } from '../gateway/authority.js';
import { resolveTenant } from '../middleware/tenant.js';
import { actorOf } from '../middleware/auth.js';
import { rewrapKey } from './transit.js';
import { PROTECTED_FIELDS } from './customers.js';
import { customerSeed, documentSeed } from '../seed-data.js';

const router = Router();

async function keyStates(slug) {
  const out = {};
  for (const keyType of gateway.KEY_TYPES) {
    const keyName = gateway.resolveKeyName(slug, keyType);
    try {
      const k = await vaultGetKeyInfo(keyName);
      out[keyName] = { currentVersion: k.currentVersion, minDecryptionVersion: k.minDecryptionVersion };
    } catch (err) {
      out[keyName] = { error: err.code ?? 'unavailable' };
    }
  }
  return out;
}

async function defaultCustomer(tenant, customerId) {
  const { rows } = customerId
    ? await query(`SELECT id, name FROM customers WHERE id=$1 AND tenant_id=$2 AND status <> 'deleted'`, [customerId, tenant.id])
    : await query(`SELECT id, name FROM customers WHERE tenant_id=$1 AND status <> 'deleted' ORDER BY name LIMIT 1`, [tenant.id]);
  if (!rows.length) throw Object.assign(new Error('Customer not found — seed demo data first'), { status: 404, code: 'not_found' });
  return rows[0];
}

// ── GET /state ────────────────────────────────────────────────────────────────

router.get('/state', async (_req, res, next) => {
  try {
    const [tenantsRes, pvCountRes, docsRes, demoRes, snapRes] = await Promise.all([
      query(`SELECT t.slug, t.fortified_at,
                    (SELECT COUNT(*)::int FROM customers c WHERE c.tenant_id = t.id AND c.status <> 'deleted') AS customers
             FROM tenants t ORDER BY t.name`),
      query('SELECT COUNT(*)::int AS count FROM protected_values'),
      query('SELECT COUNT(*)::int AS count FROM documents'),
      query('SELECT * FROM demo_state WHERE id = 1'),
      query('SELECT COUNT(*)::int AS count, MIN(captured_at) AS captured_at FROM compromise_snapshots'),
    ]);
    const state = demoRes.rows[0] ?? { active_tenant: 'acme', compromise_mode: false, fortified: false };

    const keyVersions = {};
    const keys = {};
    for (const t of tenantsRes.rows) {
      Object.assign(keys, await keyStates(t.slug));
    }
    for (const [k, v] of Object.entries(keys)) keyVersions[k] = v.currentVersion ?? null;

    const fortifiedTenants = tenantsRes.rows.filter(t => t.fortified_at).map(t => t.slug);
    res.json({
      data: {
        activeTenant: state.active_tenant,
        tenants: tenantsRes.rows.map(r => r.slug),
        customersPerTenant: Object.fromEntries(tenantsRes.rows.map(r => [r.slug, r.customers])),
        protectedValuesCount: pvCountRes.rows[0].count,
        documentsCount: docsRes.rows[0].count,
        keyVersions,
        keys,
        compromiseMode: state.compromise_mode,
        compromiseSnapshot: { records: snapRes.rows[0].count, capturedAt: snapRes.rows[0].captured_at },
        fortified: fortifiedTenants.length > 0,
        fortifiedTenants,
        lastResetAt: state.last_reset_at ?? null,
        authority: describeTenantAuthority(),
      },
    });
  } catch (err) { next(err); }
});

// ── POST /protect ─────────────────────────────────────────────────────────────
// Body: { tenant, field='iban', value, customerId? }. The ciphertext is written
// to protected_values and read back from PostgreSQL to prove what is stored.

router.post('/protect', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { field = 'iban', value, customerId } = req.body ?? {};
    if (typeof value !== 'string' || !value) {
      return res.status(400).json({ error: 'validation', message: 'value (string) is required' });
    }
    if (!PROTECTED_FIELDS.includes(field)) {
      return res.status(400).json({ error: 'validation', message: `field must be one of ${PROTECTED_FIELDS.join(', ')}` });
    }
    const customer = await defaultCustomer(tenant, customerId);
    const result = await gateway.protect({
      tenantId: tenant.id, tenantSlug: tenant.slug, keyType: 'customer-data',
      resourceType: 'customer', resourceId: customer.id, fieldName: field, actor: actorOf(req),
    }, value);

    const { rows } = await query(
      `INSERT INTO protected_values (tenant_id, resource_type, resource_id, field_name, ciphertext, key_name, key_version)
       VALUES ($1,'customer',$2,$3,$4,$5,$6)
       ON CONFLICT (tenant_id, resource_type, resource_id, field_name)
       DO UPDATE SET ciphertext=$4, key_name=$5, key_version=$6, updated_at=NOW()
       RETURNING id, field_name, ciphertext, key_name, key_version, updated_at`,
      [tenant.id, customer.id, field, result.ciphertext, result.keyName, result.keyVersion],
    );

    res.json({
      data: {
        operation:    'protect',
        tenant:       tenant.slug,
        customerId:   customer.id,
        customerName: customer.name,
        field,
        ciphertext:   result.ciphertext,
        keyName:      result.keyName,
        keyVersion:   result.keyVersion,
        storedAt:     rows[0].updated_at,
        auditEventId: result.auditEventId,
        authority:    result.authority,
        database: { table: 'protected_values', row: rows[0], containsPlaintext: rows[0].ciphertext.includes(value) },
      },
      meta: { tenant: tenant.slug },
    });
  } catch (err) { next(err); }
});

// ── POST /recover ─────────────────────────────────────────────────────────────
// Body: { tenant, field='iban', customerId? } reads the stored ciphertext, or
// { tenant, ciphertext, keyType? } recovers a supplied value.

router.post('/recover', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { field = 'iban', customerId, ciphertext: supplied, keyType = 'customer-data' } = req.body ?? {};
    let ciphertext = supplied;
    let customer = null;
    let resolvedKeyType = keyType;

    if (!ciphertext) {
      customer = await defaultCustomer(tenant, customerId);
      const { rows } = await query(
        `SELECT ciphertext, key_name FROM protected_values
         WHERE tenant_id=$1 AND resource_type='customer' AND resource_id=$2 AND field_name=$3`,
        [tenant.id, customer.id, field],
      );
      if (!rows.length) return res.status(404).json({ error: 'not_found', message: `No protected ${field} for this customer` });
      ciphertext = rows[0].ciphertext;
      resolvedKeyType = gateway.keyTypeFromKeyName(tenant.slug, rows[0].key_name);
    }

    const result = await gateway.recover({
      tenantId: tenant.id, tenantSlug: tenant.slug, keyType: resolvedKeyType,
      resourceType: customer ? 'customer' : 'demo', resourceId: customer?.id ?? null,
      fieldName: field, actor: actorOf(req),
    }, ciphertext);

    res.json({
      data: {
        operation:    'recover',
        tenant:       tenant.slug,
        customerId:   customer?.id ?? null,
        field,
        ciphertext,
        plaintext:    result.plaintext,
        keyName:      result.keyName,
        keyVersion:   result.keyVersion,
        auditEventId: result.auditEventId,
        authority:    result.authority,
        flow: ['user', 'application', 'data-trust-gateway', 'vault-transit', 'plaintext', 'authorised-ui'],
      },
      meta: { tenant: tenant.slug },
    });
  } catch (err) { next(err); }
});

// ── POST /compromise — simulate a database breach ────────────────────────────
// Copies every protected value (ciphertext + metadata, exactly what a dump
// holds) into compromise_snapshots. Nothing in Vault changes.

router.post('/compromise', async (req, res, next) => {
  try {
    await query('DELETE FROM compromise_snapshots');
    await query(
      `INSERT INTO compromise_snapshots
         (tenant_id, protected_value_id, resource_type, resource_id, field_name, ciphertext, key_name, key_version)
       SELECT tenant_id, id, resource_type, resource_id, field_name, ciphertext, key_name, key_version
       FROM protected_values`,
    );
    await query(
      `INSERT INTO demo_state (id, compromise_mode, updated_at) VALUES (1, TRUE, NOW())
       ON CONFLICT (id) DO UPDATE SET compromise_mode=TRUE, updated_at=NOW()`,
    );
    const { rows: counts } = await query(`
      SELECT (SELECT COUNT(*)::int FROM tenants)              AS tenants,
             (SELECT COUNT(*)::int FROM customers)            AS customers,
             (SELECT COUNT(*)::int FROM documents)            AS documents,
             (SELECT COUNT(*)::int FROM compromise_snapshots) AS ciphertexts,
             (SELECT COUNT(*)::int FROM compromise_snapshots WHERE ciphertext NOT LIKE 'vault:v%') AS non_ciphertext`);
    const c = counts[0];

    const auditEventId = await emitAudit({
      operation: 'DATABASE_COMPROMISE', actor: actorOf(req), result: 'SIMULATED',
      metadata: { stolen: c },
    });

    res.json({
      data: {
        operation: 'compromise',
        compromiseMode: true,
        attackerHas: {
          postgresqlAccess: true,
          customerRecords: c.customers,
          documentMetadata: c.documents,
          ciphertexts: c.ciphertexts,
          plaintextSensitiveValues: c.non_ciphertext,
        },
        attackerLacks: {
          transitKeys: 'never stored in PostgreSQL; keys are exportable=false in Vault',
          vaultAuthorization: 'no Vault token — the database holds none',
          decryptionAuthority: 'only tenant or break-glass tokens may decrypt',
        },
        next: 'POST /api/v1/scenarios/compromise/decrypt-attempt to replay stolen ciphertext against Vault',
        auditEventId,
      },
    });
  } catch (err) { next(err); }
});

router.delete('/compromise', async (req, res, next) => {
  try {
    await query(
      `INSERT INTO demo_state (id, compromise_mode, updated_at) VALUES (1, FALSE, NOW())
       ON CONFLICT (id) DO UPDATE SET compromise_mode=FALSE, updated_at=NOW()`,
    );
    await emitAudit({ operation: 'DATABASE_COMPROMISE_CLEARED', actor: actorOf(req), result: 'ALLOWED' });
    res.json({
      data: {
        operation: 'compromise_cleared',
        compromiseMode: false,
        message: 'Compromise mode deactivated. The stolen snapshot is kept so Shield/Fortify can be proven against it; reset clears it.',
      },
    });
  } catch (err) { next(err); }
});

// ── GET /compromise/snapshot — the attacker's view ───────────────────────────

router.get('/compromise/snapshot', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { rows } = await query(
      `SELECT s.id, s.resource_type, s.resource_id, s.field_name, s.ciphertext, s.key_name, s.key_version,
              s.captured_at, c.name AS customer_name, c.company, d.name AS document_name, d.classification
       FROM compromise_snapshots s
       LEFT JOIN customers c ON s.resource_type = 'customer' AND c.id = s.resource_id
       LEFT JOIN documents d ON s.resource_type = 'document' AND d.id = s.resource_id
       WHERE s.tenant_id = $1 ORDER BY s.resource_type, customer_name, document_name, s.field_name`,
      [tenant.id],
    );
    res.json({ data: rows, meta: { tenant: tenant.slug, count: rows.length, representation: 'stolen ciphertext + metadata' } });
  } catch (err) { next(err); }
});

// ── POST /compromise/decrypt-attempt ─────────────────────────────────────────
// Body: { tenant, actor='attacker'|'application', snapshotId?, ciphertext?, keyType? }
//   attacker     → Vault decrypt with NO token (all the database gives you)
//   application  → Vault decrypt under the app's own tenant authority — shows
//                  that stolen ciphertext is recoverable by a compromised app
//                  before Shield, and refused by Vault after it
// Always 200: the verdict is the payload.

router.post('/compromise/decrypt-attempt', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { actor = 'attacker', snapshotId, ciphertext: supplied, keyType = 'customer-data' } = req.body ?? {};
    if (!['attacker', 'application'].includes(actor)) {
      return res.status(400).json({ error: 'validation', message: "actor must be 'attacker' or 'application'" });
    }

    let target;
    if (supplied) {
      target = { ciphertext: supplied, key_name: gateway.resolveKeyName(tenant.slug, keyType),
        resource_type: 'demo', resource_id: null, field_name: null, id: null };
    } else {
      const { rows } = snapshotId
        ? await query('SELECT * FROM compromise_snapshots WHERE id=$1 AND tenant_id=$2', [snapshotId, tenant.id])
        : await query(
          `SELECT * FROM compromise_snapshots WHERE tenant_id=$1 AND resource_type='customer'
           ORDER BY field_name, resource_id LIMIT 1`, [tenant.id]);
      if (!rows.length) {
        return res.status(409).json({ error: 'no_compromise_snapshot', message: 'Activate the compromise scenario first (POST /scenarios/compromise)' });
      }
      target = rows[0];
    }

    const tKeyType = gateway.keyTypeFromKeyName(tenant.slug, target.key_name);
    const ctx = { tenantId: tenant.id, tenantSlug: tenant.slug, keyType: tKeyType,
      resourceType: target.resource_type, resourceId: target.resource_id, fieldName: target.field_name };

    let outcome;
    if (actor === 'attacker') {
      const r = await gateway.attackerDecrypt(ctx, target.key_name, target.ciphertext);
      outcome = { result: r.result, vault: r.vault, auditEventId: r.auditEventId, reason: r.result === 'DENIED' ? 'no_vault_token' : null,
        explanation: 'The attacker holds ciphertext but no Vault token. Vault refuses to decrypt.' };
    } else {
      try {
        const r = await gateway.recover({ ...ctx, actor: 'compromised-application' }, target.ciphertext,
          { operation: 'COMPROMISE_REPLAY', auditMetadata: { snapshot_id: target.id } });
        outcome = { result: 'ALLOWED', auditEventId: r.auditEventId, authority: r.authority, vault: { status: 200 },
          recovered: true, plaintextReturned: false,
          explanation: 'The application\'s own tenant authority can still decrypt this stolen ciphertext. Run SHIELD to retire the key versions it was encrypted under.' };
      } catch (err) {
        if (err.status === 503) throw err;
        outcome = { result: 'DENIED', reason: err.code, vault: err.vault ?? null, authority: err.authority ?? null,
          auditEventId: err.auditEventId ?? null,
          explanation: err.code === 'ciphertext_version_retired'
            ? 'Vault refuses: this ciphertext predates the minimum decryption version set by SHIELD. The stolen copy is worthless even to the application.'
            : 'Vault refused the decrypt under the application\'s tenant authority.' };
      }
    }

    res.json({
      data: {
        actor,
        tenant: tenant.slug,
        snapshotId: target.id,
        keyName: target.key_name,
        keyVersion: gateway.ciphertextVersion(target.ciphertext),
        ciphertext: target.ciphertext,
        ...outcome,
      },
      meta: { tenant: tenant.slug },
    });
  } catch (err) { next(err); }
});

// ── POST /isolation-probe ─────────────────────────────────────────────────────
// Body: { tenant, targetTenant, operation='encrypt'|'decrypt' }

router.post('/isolation-probe', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const { targetTenant, operation = 'encrypt' } = req.body ?? {};
    if (!['encrypt', 'decrypt'].includes(operation)) {
      return res.status(400).json({ error: 'validation', message: "operation must be 'encrypt' or 'decrypt'" });
    }
    const { rows } = await query('SELECT slug FROM tenants WHERE slug=$1', [targetTenant ?? '']);
    if (!rows.length) return res.status(404).json({ error: 'not_found', message: 'targetTenant not found' });
    if (rows[0].slug === tenant.slug) {
      return res.status(400).json({ error: 'validation', message: 'targetTenant must differ from tenant' });
    }
    const result = await gateway.probeIsolation(
      { tenantId: tenant.id, tenantSlug: tenant.slug, actor: actorOf(req) }, rows[0].slug, operation);
    res.json({ data: result, meta: { tenant: tenant.slug } });
  } catch (err) { next(err); }
});

// ── POST /fortify — SHIELD ────────────────────────────────────────────────────

router.post('/fortify', async (req, res, next) => {
  try {
    const tenant = await resolveTenant(req);
    const actor = actorOf(req);
    const before = await keyStates(tenant.slug);
    const steps = [];

    // A pre-Shield ciphertext to prove the result against: the attacker's
    // snapshot if there is one, otherwise the current stored value.
    const { rows: probeRows } = await query(
      `SELECT ciphertext, key_name, 'snapshot' AS origin FROM compromise_snapshots
         WHERE tenant_id=$1 AND resource_type='customer'
       UNION ALL
       SELECT ciphertext, key_name, 'pre-shield' AS origin FROM protected_values
         WHERE tenant_id=$1 AND resource_type='customer'
       ORDER BY origin DESC
       LIMIT 1`, [tenant.id]);
    const preShield = probeRows[0] ?? null;

    // 1. Rotate every tenant key
    const rotations = [];
    for (const keyType of gateway.KEY_TYPES) {
      rotations.push(await gateway.rotate({ tenantId: tenant.id, tenantSlug: tenant.slug, keyType, actor }));
    }
    steps.push({ control: 'rotate', enforcedBy: 'vault',
      detail: rotations.map(r => `${r.keyName}: v${r.fromVersion} → v${r.currentVersion}`) });

    // 2. Rewrap all stored ciphertext inside Vault
    const rewraps = [];
    for (const keyType of gateway.KEY_TYPES) rewraps.push(await rewrapKey(tenant, keyType, actor));
    steps.push({ control: 'rewrap', enforcedBy: 'vault', plaintextExposedToApplication: false,
      detail: rewraps.map(r => `${r.keyName}: ${r.rewrapped} value(s) → v${r.currentVersion}`) });

    // 3. Raise the decryption floor — only after every stored value is current
    const floors = [];
    for (const r of rewraps) {
      const { rows } = await query(
        'SELECT COUNT(*)::int AS c FROM protected_values WHERE key_name=$1 AND tenant_id=$2 AND key_version < $3',
        [r.keyName, tenant.id, r.currentVersion]);
      if (rows[0].c > 0) throw Object.assign(new Error(`${rows[0].c} value(s) under ${r.keyName} not rewrapped`), { status: 500, code: 'fortify_incomplete' });
      floors.push(await gateway.setMinDecryptionVersion(
        { tenantId: tenant.id, tenantSlug: tenant.slug, keyType: gateway.keyTypeFromKeyName(tenant.slug, r.keyName), actor },
        r.currentVersion));
    }
    steps.push({ control: 'min_decryption_version', enforcedBy: 'vault',
      detail: floors.map(f => `${f.keyName}: floor v${f.previousMinDecryptionVersion} → v${f.minDecryptionVersion}`) });

    // 4. Re-issue authority: revoke every outstanding user-derived tenant token
    const revokedAccessors = await revokeTenantAuthority(tenant.slug);
    steps.push({ control: 'reissue_authority', enforcedBy: 'vault',
      detail: [`revoked ${revokedAccessors.length} outstanding Vault token(s) for tenant-${tenant.slug}; `
        + 'the next operation logs the operator in again (auth/jwt, 5-minute token)'] });

    // 5. Verify, live, against Vault
    const verification = {};
    const { rows: currentRows } = await query(
      `SELECT resource_type, resource_id, field_name, ciphertext, key_name FROM protected_values
       WHERE tenant_id=$1 AND resource_type='customer' LIMIT 1`, [tenant.id]);
    if (currentRows[0]) {
      const cr = currentRows[0];
      try {
        await gateway.recover({ tenantId: tenant.id, tenantSlug: tenant.slug, keyType: 'customer-data',
          resourceType: cr.resource_type, resourceId: cr.resource_id, fieldName: cr.field_name, actor },
        cr.ciphertext, { operation: 'FORTIFY_VERIFY' });
        verification.legitimateRecovery = { expected: 'ALLOWED', result: 'ALLOWED' };
      } catch (err) {
        verification.legitimateRecovery = { expected: 'ALLOWED', result: 'DENIED', reason: err.code };
      }
    }
    if (preShield) {
      try {
        await gateway.recover({ tenantId: tenant.id, tenantSlug: tenant.slug,
          keyType: gateway.keyTypeFromKeyName(tenant.slug, preShield.key_name), resourceType: 'demo',
          resourceId: null, fieldName: null, actor: 'compromised-application' },
        preShield.ciphertext, { operation: 'FORTIFY_VERIFY', auditMetadata: { origin: preShield.origin } });
        verification.preShieldCiphertext = { origin: preShield.origin, expected: 'DENIED', result: 'ALLOWED' };
      } catch (err) {
        verification.preShieldCiphertext = { origin: preShield.origin, expected: 'DENIED', result: 'DENIED',
          reason: err.code, vault: err.vault ?? null };
      }
    }
    const { rows: others } = await query('SELECT slug FROM tenants WHERE slug <> $1 ORDER BY slug LIMIT 1', [tenant.slug]);
    if (others[0]) {
      const p = await gateway.probeIsolation({ tenantId: tenant.id, tenantSlug: tenant.slug, actor }, others[0].slug);
      verification.crossTenant = { target: others[0].slug, expected: 'DENIED', result: p.result };
    }
    verification.passed = Object.values(verification).every(v => v.result === v.expected);

    await query('UPDATE tenants SET fortified_at = NOW() WHERE id = $1', [tenant.id]);
    await query(
      `INSERT INTO demo_state (id, fortified, updated_at) VALUES (1, TRUE, NOW())
       ON CONFLICT (id) DO UPDATE SET fortified=TRUE, updated_at=NOW()`,
    );
    const after = await keyStates(tenant.slug);
    const auditEventId = await emitAudit({
      operation: 'FORTIFY', tenantId: tenant.id, resourceType: 'tenant', actor,
      result: verification.passed ? 'ALLOWED' : 'FAILED', source: 'vault',
      metadata: { before, after, steps: steps.map(s => s.control), verification },
    });

    res.json({
      data: {
        operation: 'fortify',
        tenant: tenant.slug,
        before,
        after,
        steps,
        verification,
        rewrapped: rewraps.reduce((n, r) => n + r.rewrapped, 0),
        auditEventId,
        message: 'Keys rotated, ciphertext rewrapped inside Vault, older key versions retired for decryption, tenant authority re-issued.',
      },
      meta: { tenant: tenant.slug },
    });
  } catch (err) { next(err); }
});

// ── POST /seed ────────────────────────────────────────────────────────────────

router.post('/seed', async (req, res, next) => {
  try {
    await query(`
      INSERT INTO tenants (name, slug, vault_namespace) VALUES
        ('ACME Corporation', 'acme',    'acme'),
        ('Globex Inc.',      'globex',  'globex'),
        ('Initech Ltd.',     'initech', 'initech')
      ON CONFLICT (slug) DO NOTHING`);
    const { rows: existing } = await query('SELECT COUNT(*)::int AS c FROM customers');
    if (existing[0].c > 0) return res.json({ data: { message: 'Already seeded', customers: existing[0].c } });

    const { rows: tenants } = await query('SELECT * FROM tenants');
    const tenantMap = Object.fromEntries(tenants.map(t => [t.slug, t]));
    const customerIds = {};
    let totalCustomers = 0;
    let totalProtected = 0;
    let totalDocs = 0;

    for (const { slug, customers } of customerSeed) {
      const tenant = tenantMap[slug];
      for (const { name, company, country, ...sensitive } of customers) {
        const { rows } = await query(
          'INSERT INTO customers (tenant_id, name, company, country) VALUES ($1,$2,$3,$4) RETURNING id',
          [tenant.id, name, company, country]);
        const id = rows[0].id;
        customerIds[`${slug}:${name}`] = id;
        totalCustomers++;
        for (const [field, value] of Object.entries(sensitive)) {
          const { ciphertext, keyName, keyVersion } = await gateway.protect({
            tenantId: tenant.id, tenantSlug: slug, keyType: 'customer-data',
            resourceType: 'customer', resourceId: id, fieldName: field, actor: 'seed' }, value);
          await query(
            `INSERT INTO protected_values (tenant_id, resource_type, resource_id, field_name, ciphertext, key_name, key_version)
             VALUES ($1,'customer',$2,$3,$4,$5,$6)`,
            [tenant.id, id, field, ciphertext, keyName, keyVersion]);
          totalProtected++;
        }
      }
    }

    for (const { slug, docs } of documentSeed) {
      const tenant = tenantMap[slug];
      for (const { name, content_type, classification, customer, created_by, payload } of docs) {
        const { rows } = await query(
          `INSERT INTO documents (tenant_id, customer_id, name, content_type, classification, size_bytes, checksum, created_by)
           VALUES ($1,$2,$3,$4,$5,$6,encode(digest($7,'sha256'),'hex'),$8) RETURNING id`,
          [tenant.id, customer ? customerIds[`${slug}:${customer}`] ?? null : null, name, content_type,
           classification, Buffer.byteLength(payload), payload, created_by]);
        const id = rows[0].id;
        totalDocs++;
        const { ciphertext, keyName, keyVersion } = await gateway.protect({
          tenantId: tenant.id, tenantSlug: slug, keyType: gateway.keyTypeForClassification(classification),
          resourceType: 'document', resourceId: id, fieldName: 'payload', actor: 'seed' }, payload);
        await query(
          `INSERT INTO protected_values (tenant_id, resource_type, resource_id, field_name, ciphertext, key_name, key_version)
           VALUES ($1,'document',$2,'payload',$3,$4,$5)`,
          [tenant.id, id, ciphertext, keyName, keyVersion]);
        totalProtected++;
      }
    }

    await query(`
      INSERT INTO demo_state (id, active_tenant, compromise_mode, fortified)
      VALUES (1, 'acme', FALSE, FALSE) ON CONFLICT (id) DO NOTHING`);
    await emitAudit({ operation: 'DEMO_SEED', actor: actorOf(req), result: 'ALLOWED',
      metadata: { customers: totalCustomers, documents: totalDocs, protectedValues: totalProtected } });

    res.json({ data: { message: 'Seeded', customers: totalCustomers, documents: totalDocs, protectedValues: totalProtected } });
  } catch (err) { next(err); }
});

// ── DELETE /reset ─────────────────────────────────────────────────────────────
// Wipes demo data (customers, documents, protected values, break-glass
// requests, compromise snapshot) and revokes all outstanding scoped Vault
// authority. Tenants and the append-only audit trail are kept — a DEMO_RESET
// event marks the boundary (filter the audit log with ?since=lastResetAt).
// Key versions only move forward; min_decryption_version is left as set, which
// is safe because re-seeded data is always encrypted with the latest version.
// ?rotate=true additionally rotates every tenant key.

router.delete('/reset', async (req, res, next) => {
  try {
    const actor = actorOf(req);
    const { rows: tenants } = await query('SELECT id, slug FROM tenants');

    let rotatedKeys = null;
    if (req.query.rotate === 'true') {
      rotatedKeys = [];
      for (const t of tenants) {
        for (const keyType of gateway.KEY_TYPES) {
          const r = await gateway.rotate({ tenantId: t.id, tenantSlug: t.slug, keyType, actor });
          rotatedKeys.push(`${r.keyName}:v${r.currentVersion}`);
        }
      }
    }

    const revoked = await revokeAllAuthority();

    await query('DELETE FROM compromise_snapshots');
    await query('DELETE FROM break_glass_requests');
    await query('DELETE FROM protected_values');
    await query('DELETE FROM documents');
    await query('DELETE FROM customers');
    await query('UPDATE tenants SET fortified_at = NULL');
    await query(
      `INSERT INTO demo_state (id, active_tenant, compromise_mode, fortified, last_reset_at, updated_at)
       VALUES (1, 'acme', FALSE, FALSE, NOW(), NOW())
       ON CONFLICT (id) DO UPDATE SET compromise_mode=FALSE, fortified=FALSE, last_reset_at=NOW(), updated_at=NOW()`,
    );
    const auditEventId = await emitAudit({ operation: 'DEMO_RESET', actor, result: 'ALLOWED',
      metadata: { rotatedKeys, revokedTenantTokens: revoked.tenants, revokedBreakGlassTokens: revoked.breakGlass } });

    res.json({
      data: {
        message: 'Reset complete — run POST /seed to restore demo data',
        revokedAuthority: revoked,
        auditEventId,
        ...(rotatedKeys && { rotatedKeys }),
      },
    });
  } catch (err) { next(err); }
});

export default router;
