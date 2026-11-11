// Keeps secrets out of evidence, reports and diagnostic bundles.

// Variables the acceptance plan marks secret, plus the ones captured at
// run time. Any name matching SECRET_NAME_RE is treated as secret too.
export const SECRET_NAMES = new Set([
  'LICENSE_JSON', 'ADMIN_PASSWORD', 'ADMIN2_PASSWORD', 'EDITOR_PASSWORD', 'VIEWER_PASSWORD',
  'SSO_CLIENT_SECRET', 'SECRET_PROBE', 'LOAD_SRC_DSN', 'WEBHOOK_SECRET', 'NOTIFY_CHANNEL_CONFIG',
  'EMAIL_TRANSPORT_JSON', 'DBT_PROJECT_BODY', 'AZ_SP_CLIENT_SECRET', 'AZ_KV_PROBE_VALUE',
  'SVC_TOKEN', 'OAUTH_CLIENT_SECRET', 'EXPORT_ENVELOPE', 'DL_API_TOKEN',
]);
const SECRET_NAME_RE = /(PASSWORD|SECRET|TOKEN|_CONFIG$|_DSN$|^SESSION|LICENSE|_KEY$|_CMD$)/;
const SECRET_FIELD_RE = /(password|secret|token|private_key|api_key|license_key|access_key|sas|pat|authorization|cookie)/i;

export function isSecretName(name) {
  return SECRET_NAMES.has(name) || SECRET_NAME_RE.test(name);
}

// Pull every string worth hiding out of a value: the whole text, plus the
// leaves of a JSON object (a config object's password, for example).
function secretStrings(value) {
  const out = [];
  const text = typeof value === 'string' ? value : JSON.stringify(value);
  if (text) out.push(text);
  let obj = value;
  if (typeof value === 'string') {
    try {
      obj = JSON.parse(value);
    } catch {
      obj = null;
    }
  }
  const walk = (v, key) => {
    if (v === null || v === undefined) return;
    if (typeof v === 'string') {
      if (v.length >= 4 && (key === null || SECRET_FIELD_RE.test(key))) out.push(v);
      // A cookie header: hide each value.
      for (const part of v.split(/;\s*/)) {
        const eq = part.indexOf('=');
        if (eq > 0 && part.length - eq > 8) out.push(part.slice(eq + 1));
      }
      return;
    }
    if (typeof v !== 'object') return;
    for (const [k, child] of Object.entries(v)) walk(child, Array.isArray(v) ? key : k);
  };
  if (obj && typeof obj === 'object') walk(obj, null);
  else if (typeof value === 'string') walk(value, null);
  return out.filter((s) => s && s.length >= 4);
}

export class Redactor {
  constructor() {
    this.secrets = new Map(); // text -> label
  }

  add(name, value) {
    if (value === undefined || value === null || value === '') return;
    for (const s of secretStrings(value)) {
      if (!this.secrets.has(s) || this.secrets.get(s).length > name.length) this.secrets.set(s, name);
    }
  }

  // Register every secret-named variable of a vars object.
  addVars(vars) {
    for (const [k, v] of Object.entries(vars)) if (isSecretName(k)) this.add(k, v);
  }

  redact(text) {
    if (text === undefined || text === null) return text;
    let out = typeof text === 'string' ? text : JSON.stringify(text);
    // Longest first, so a config object goes before the password inside it.
    const items = [...this.secrets.entries()].sort((a, b) => b[0].length - a[0].length);
    for (const [s, name] of items) out = out.split(s).join(`[redacted:${name}]`);
    return redactPatterns(out);
  }
}

// Patterns that look secret whatever their source.
export function redactPatterns(text) {
  return text
    .replace(/eyJ[\w-]{8,}\.[\w-]{8,}\.[\w-]{8,}/g, '[redacted:jwt]')
    .replace(/\b(dl_(?:pat|tok|api)_?[A-Za-z0-9_-]{12,})/g, '[redacted:token]')
    .replace(/((?:"|')?(?:password|client_secret|secret|token|api_key|private_key|license_key|access_key)(?:"|')?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s,}&]+)/gi, (m, k, v) => {
      if (v === 'true' || v === 'false') return m;
      return /^["']?(\[redacted|kv:\/\/|\*\*\*|["']$)/.test(v) ? m : `${k}"[redacted]"`;
    })
    .replace(/(Authorization:\s*Bearer\s+)\S+/gi, '$1[redacted]')
    .replace(/(Cookie:\s*)[^\r\n]+/gi, '$1[redacted]')
    .replace(/(AccountKey=)[^;\s]+/g, '$1[redacted]')
    .replace(/([?&]sig=)[^&\s"]+/g, '$1[redacted]');
}
