// routes/vault.js — Vault cluster status for the Web Console "Vault" page.
// prompts/api/01_02_vault_status_endpoint.md
//
// Built only from UNAUTHENTICATED Vault endpoints (per-node sys/health,
// sys/seal-status, sys/leader) and HAProxy's read-only stats — the backend
// needs no extra Vault authority to show cluster state. Key metadata comes
// from the broker's existing read-only policy, filtered to the caller's tenants.
import { Router } from 'express';
import { config } from '../config.js';
import { vaultGetKeyInfo, vaultHealthCheck } from '../vault.js';
import { KEY_TYPES, resolveKeyName } from '../gateway/index.js';
import { mayAccessTenant } from '../middleware/tenant.js';
import { query } from '../db.js';

const router = Router();

const NODES = (process.env.DURIN_VAULT_NODES ?? 'vault-s:unseal,vault-1:cluster,vault-2:cluster,vault-3:cluster')
  .split(',').map(s => { const [name, role] = s.trim().split(':'); return { name, role: role ?? 'cluster' }; });
const LB_STATS_URL = process.env.DURIN_VAULT_LB_STATS_URL ?? 'http://vault-lb:8404/stats;csv';
const CACHE_MS = 3_000;
let cache = { at: 0, data: null };

async function getJson(url) {
  try {
    const res = await fetch(url, { signal: AbortSignal.timeout(3_000) });
    const text = await res.text();
    return { httpStatus: res.status, body: text ? JSON.parse(text) : null };
  } catch (err) {
    return { httpStatus: 0, error: err.cause?.code ?? err.name ?? 'unreachable' };
  }
}

// sys/health status codes (with standbyok/perfstandbyok/sealedok/uninitok so
// Vault always answers with a body): translate to a single mode.
function modeOf(h) {
  if (!h?.body) return 'unreachable';
  const b = h.body;
  if (!b.initialized) return 'uninitialized';
  if (b.sealed) return 'sealed';
  if (b.performance_standby) return 'performance-standby';
  if (b.standby) return 'standby';
  return 'active';
}

async function nodeStatus({ name, role }) {
  const base = `https://${name}:8200/v1`;
  const [health, seal, leader] = await Promise.all([
    getJson(`${base}/sys/health?standbyok=true&perfstandbyok=true&sealedok=true&uninitok=true`),
    getJson(`${base}/sys/seal-status`),
    role === 'cluster' ? getJson(`${base}/sys/leader`) : Promise.resolve(null),
  ]);
  const h = health.body ?? {};
  const s = seal.body ?? {};
  return {
    name,
    role,                                  // cluster | unseal
    reachable: Boolean(health.body),
    mode: modeOf(health),
    sealed: h.sealed ?? s.sealed ?? null,
    initialized: h.initialized ?? s.initialized ?? null,
    version: h.version ?? s.version ?? null,
    clusterName: h.cluster_name ?? s.cluster_name ?? null,
    sealType: s.type ?? null,              // transit (auto-unseal via vault-s) | shamir
    storageType: s.storage_type ?? null,
    serverTimeUtc: h.server_time_utc ?? null,
    isLeader: leader?.body ? Boolean(leader.body.is_self) : null,
    leaderAddress: leader?.body?.leader_address ?? null,
    ...(health.error && { error: health.error }),
  };
}

async function lbStatus() {
  try {
    const res = await fetch(LB_STATS_URL, { signal: AbortSignal.timeout(3_000) });
    if (!res.ok) return { reachable: false, error: `HTTP ${res.status}` };
    const lines = (await res.text()).split('\n');
    const header = lines[0].replace(/^# /, '').split(',');
    const idx = k => header.indexOf(k);
    const servers = lines.slice(1).map(l => l.split(','))
      .filter(c => c[idx('pxname')] === 'vault_active' && !['FRONTEND', 'BACKEND'].includes(c[idx('svname')]))
      .map(c => ({
        node: c[idx('svname')],
        state: c[idx('status')],             // UP = receiving traffic (the active node); DOWN = standby / unavailable
        check: c[idx('check_status')],
        lastChange: Number(c[idx('lastchg')]) || null,
      }));
    const active = servers.filter(s => s.state === 'UP').map(s => s.node);
    return {
      reachable: true,
      endpoint: 'vault-lb:8200 (TLS passthrough)',
      routing: 'active node only — standbys report DOWN by design (health 429/473)',
      activeNode: active[0] ?? null,
      servers,
    };
  } catch (err) {
    return { reachable: false, error: err.cause?.code ?? err.message };
  }
}

async function tenantKeys(user) {
  const { rows } = await query('SELECT slug FROM tenants ORDER BY name');
  const out = {};
  for (const { slug } of rows) {
    if (!mayAccessTenant(user, slug)) continue;
    out[slug] = [];
    for (const keyType of KEY_TYPES) {
      const name = resolveKeyName(slug, keyType);
      try {
        const k = await vaultGetKeyInfo(name);
        out[slug].push({ name, keyType, type: k.type, currentVersion: k.currentVersion,
          minDecryptionVersion: k.minDecryptionVersion, exportable: k.exportable, deletionAllowed: k.deletionAllowed });
      } catch (err) {
        out[slug].push({ name, keyType, error: err.code ?? 'unavailable' });
      }
    }
  }
  return out;
}

// ── GET /status ───────────────────────────────────────────────────────────────

router.get('/status', async (req, res, next) => {
  try {
    if (!cache.data || Date.now() - cache.at > CACHE_MS) {
      const [nodes, loadBalancer, broker] = await Promise.all([
        Promise.all(NODES.map(nodeStatus)), lbStatus(), vaultHealthCheck(),
      ]);
      const clusterNodes = nodes.filter(n => n.role === 'cluster');
      const leader = clusterNodes.find(n => n.isLeader) ?? null;
      const unsealed = clusterNodes.filter(n => n.reachable && n.sealed === false).length;
      cache = {
        at: Date.now(),
        data: {
          summary: {
            status: !leader ? 'unavailable' : unsealed === clusterNodes.length ? 'healthy' : 'degraded',
            leader: leader?.name ?? null,
            nodesUnsealed: unsealed,
            nodesTotal: clusterNodes.length,
            haQuorum: unsealed >= Math.floor(clusterNodes.length / 2) + 1,
            version: leader?.version ?? clusterNodes.find(n => n.version)?.version ?? null,
            loadBalancerAgrees: Boolean(leader && loadBalancer.activeNode === leader.name),
          },
          nodes,
          loadBalancer,
          backend: {
            vaultAddr: config.vault.addr,
            status: broker.ok ? 'connected' : broker.tokenStale ? 'token_stale' : 'unavailable',
            policies: broker.policies ?? [],
            note: 'Broker token: key metadata only. Data authority is issued by Vault to the logged-in user (auth/jwt).',
          },
          authMethods: [
            { path: 'auth/jwt', purpose: 'Durin users (Keycloak) — tenant, break-glass requester and approver roles' },
            { path: 'auth/approle', purpose: 'Workloads — backend broker (via Vault Agent), vault-rotator, identity-secrets-init' },
          ],
        },
      };
    }
    res.json({
      data: { ...cache.data, transitKeys: await tenantKeys(req.user) },
      meta: { cachedForMs: CACHE_MS },
    });
  } catch (err) { next(err); }
});

export default router;
