// What dl-diagnose may copy out of an install's configuration. A bundle
// may be sent to Dakota for support, and redaction by pattern misses
// things (a password inside a URL, a key name nobody has seen yet). So
// config is copied by allowlist: the names of what is set, and a value
// only for a key known to be safe, in a shape that cannot hide a secret.

// The `.env` keys whose values are copied, from the install runbook's
// ".env file" section and the compose file. Each value must also match
// its shape, or it is withheld.
export const ENV_ALLOWLIST = {
  COMPOSE_PROJECT_NAME: /^[a-z0-9][a-z0-9_-]{0,62}$/,
  DATALOADER_TAG: /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/,
  DATALOADER_BIND_ADDR: /^[0-9a-fA-F.:]{2,45}$/,
  DATALOADER_PORT: /^\d{1,5}$/,
  DATALOADER_AUTO_UPDATE: /^(on|off)$/,
  DATALOADER_APPARMOR_PROFILE: /^[A-Za-z0-9_.-]{1,64}$/,
  DL_AZURE_MANAGED_IDENTITY: /^[a-z_]{1,32}$/,
  DL_PORT: /^\d{1,5}$/,
  DL_DEV_MODE: /^(true|false|1|0)$/,
};

const KEY_RE = /^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$/;

// Summarize a `.env` text: every key that is set, and the allowlisted
// values. Comments and every other value are dropped.
export function summarizeEnv(text) {
  const keys = [];
  const values = {};
  for (const line of String(text).split(/\r?\n/)) {
    // A bare name is what envSummaryCommand prints for each key.
    const bare = /^\s*([A-Za-z_][A-Za-z0-9_]*)\s*$/.exec(line);
    if (bare) {
      if (!keys.includes(bare[1])) keys.push(bare[1]);
      continue;
    }
    const m = KEY_RE.exec(line);
    if (!m) continue;
    const [, key, rawValue] = m;
    let v = rawValue.trim();
    if (v.length >= 2 && ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'")))) v = v.slice(1, -1);
    if (!keys.includes(key)) keys.push(key);
    const shape = ENV_ALLOWLIST[key];
    if (shape) values[key] = shape.test(v) ? v : '[value withheld: unexpected shape]';
  }
  const lines = ['Keys set in .env. Values are shown only for the allowlisted keys:'];
  for (const k of keys) lines.push(k in values ? `${k}=${values[k]}` : `${k} (set, value not collected)`);
  return lines.join('\n');
}

// A host command that prints only key names and the allowlisted lines, so
// the other values never leave the host. summarizeEnv runs on its output
// as well.
export function envSummaryCommand(file) {
  const q = `'${file.replace(/'/g, `'\\''`)}'`;
  const allowed = Object.keys(ENV_ALLOWLIST).join('|');
  const read = `(cat ${q} 2>/dev/null || sudo -n cat ${q})`;
  return `${read} | sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*$/\\2/p' | sort -u; ` +
    `${read} | grep -E '^[[:space:]]*(${allowed})='`;
}

// Field allowlists for the API answers dl-diagnose reads. A listed field
// keeps its value (and an object or array under it is filtered the same
// way); `name.*` keeps the whole subtree; `name:keys` keeps only the names
// of the fields under it. Every other field is named, not copied.
export const ROUTE_ALLOWLISTS = {
  '/api/v1/auth/me': ['role', 'auth_method'],
  '/api/v1/settings/sso': ['provider', 'issuer_url', 'redirect_url', 'allowed_email_domains', 'client_secret_set', 'client_auth', 'configured', 'sso_enforced', 'session_recheck.*'],
  '/api/v1/settings/license': ['status', 'plan', 'expires_at', 'features.*', 'max_connections', 'trial_days_remaining'],
  '/api/v1/vaults': ['id', 'name', 'uri', 'env_tag', 'auth_method', 'is_bootstrap', 'last_probed_at', 'secret_count', 'last_probe_status', 'prod_counterpart_id'],
  '/api/v1/vaults/managed-identity': ['available', 'source', 'role', 'message'],
  '/api/v1/connections': ['id', 'connection_key', 'db_type', 'is_active', 'health_status', 'health_message', 'last_health_check', 'plugin_name', 'plugin_version', 'config_json:keys', 'items', 'total'],
  '/api/v1/destinations': ['id', 'destination_key', 'dest_type', 'is_active', 'is_default', 'config_json:keys', 'items', 'total'],
  '/api/v1/dashboard/needs-attention': ['env', 'computed_at', 'thresholds.*', 'entries', 'kind', 'signal', 'signals', 'since', 'severity', 'workspace', 'failure', 'error'],
};

export function allowlistFor(path) {
  return ROUTE_ALLOWLISTS[path.split('?')[0]];
}

// Keep only the allowlisted fields of a parsed JSON answer.
export function project(value, allow) {
  const rules = new Map();
  for (const a of allow) {
    if (a.endsWith('.*')) rules.set(a.slice(0, -2), 'tree');
    else if (a.endsWith(':keys')) rules.set(a.slice(0, -5), 'keys');
    else rules.set(a, 'field');
  }
  const walk = (v) => {
    if (Array.isArray(v)) return v.map(walk);
    if (v === null || typeof v !== 'object') return v;
    const out = {};
    const skipped = [];
    for (const [k, child] of Object.entries(v)) {
      const rule = rules.get(k);
      if (rule === 'tree') out[k] = child;
      else if (rule === 'keys') out[k] = child && typeof child === 'object' ? { _keys: Object.keys(child) } : '[not collected]';
      else if (rule === 'field') out[k] = walk(child);
      else skipped.push(k);
    }
    if (skipped.length) out._not_collected = skipped;
    return out;
  };
  return walk(value);
}
