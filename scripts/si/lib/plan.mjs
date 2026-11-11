// Reads the client acceptance plan: one `<!-- cat: {...} -->` marker per
// case, directly under the case heading. The plan's "Conventions for
// dl-verify" section defines the marker keys and check kinds.

export const MARKER_RE = /^<!-- cat: (.*) -->$/;
const CASE_HEADING_RE = /^#{2,4}\s+(CAT-[A-Z0-9]+-\d+)\s+(.*)$/;
const SECTION_RE = /^##\s+(\d+\.\s+.*)$/;

export const CHECK_KINDS = ['http', 'cli', 'sql', 'ui'];
const KNOWN_KEYS = ['id', 'mode', 'check', 'look_for', 'requires', 'depends_on', 'destructive', 'known_issue'];

// Parse the plan text. Returns { cases, errors }. Each case is the marker
// object plus `title`, `section` and `line` (1-based).
export function parsePlan(text) {
  const lines = text.split(/\r?\n/);
  const cases = [];
  const errors = [];
  let heading = null;
  let section = null;
  lines.forEach((line, i) => {
    const sec = SECTION_RE.exec(line);
    if (sec) section = sec[1].trim();
    const h = CASE_HEADING_RE.exec(line);
    if (h) heading = { id: h[1], title: h[2].trim() };
    const m = MARKER_RE.exec(line);
    if (!m) return;
    let marker;
    try {
      marker = JSON.parse(m[1]);
    } catch (e) {
      errors.push(`line ${i + 1}: marker is not valid JSON (${e.message})`);
      return;
    }
    const title = heading && heading.id === marker.id ? heading.title : '';
    cases.push({ ...marker, title, section, line: i + 1 });
  });
  errors.push(...validateCases(cases));
  return { cases, errors };
}

export function checksOf(c) {
  if (!c.check) return [];
  return Array.isArray(c.check) ? c.check : [c.check];
}

export function validateCases(cases) {
  const errors = [];
  const ids = new Set();
  for (const c of cases) {
    const at = `line ${c.line} (${c.id || 'no id'})`;
    if (!c.id || !/^CAT-[A-Z0-9]+-\d+$/.test(c.id)) errors.push(`${at}: id must look like CAT-AREA-NN`);
    if (ids.has(c.id)) errors.push(`${at}: duplicate id`);
    ids.add(c.id);
    for (const k of Object.keys(c)) {
      if (!KNOWN_KEYS.includes(k) && !['title', 'section', 'line'].includes(k)) errors.push(`${at}: unknown key ${k}`);
    }
    if (c.mode === 'automatable') {
      const checks = checksOf(c);
      if (checks.length === 0) errors.push(`${at}: automatable case has no check`);
      checks.forEach((ch, n) => {
        if (!CHECK_KINDS.includes(ch.kind)) errors.push(`${at}: check ${n + 1} has unknown kind ${ch.kind}`);
        if (ch.kind === 'http' && (!ch.method || !ch.path)) errors.push(`${at}: http check ${n + 1} needs method and path`);
        if (ch.kind === 'cli' && !ch.run) errors.push(`${at}: cli check ${n + 1} needs run`);
        if (ch.kind === 'sql' && (!ch.target || !ch.query)) errors.push(`${at}: sql check ${n + 1} needs target and query`);
        if (ch.kind === 'ui' && !ch.path) errors.push(`${at}: ui check ${n + 1} needs path`);
      });
    } else if (c.mode === 'visual') {
      if (!Array.isArray(c.look_for) || c.look_for.length === 0) errors.push(`${at}: visual case needs look_for`);
    } else {
      errors.push(`${at}: mode must be automatable or visual`);
    }
    for (const k of ['requires', 'depends_on']) {
      if (c[k] !== undefined && !Array.isArray(c[k])) errors.push(`${at}: ${k} must be an array`);
    }
  }
  for (const c of cases) {
    for (const d of c.depends_on || []) {
      if (!ids.has(d)) errors.push(`line ${c.line} (${c.id}): depends_on names unknown case ${d}`);
    }
  }
  return errors;
}

// Cases in plan order, except that a case never runs before the cases it
// depends on. The plan groups cases by topic, so a case such as CAT-LIC-01
// sits in an early section while the sign-in it needs (CAT-AUTH-03) is in a
// later one. Stable: a case moves only as far as its dependencies require.
export function orderByDependencies(cases) {
  const byId = new Map(cases.map((c) => [c.id, c]));
  const done = new Set();
  const visiting = new Set();
  const out = [];
  const visit = (c) => {
    if (done.has(c.id) || visiting.has(c.id)) return;
    visiting.add(c.id);
    for (const d of c.depends_on || []) if (byId.has(d)) visit(byId.get(d));
    visiting.delete(c.id);
    done.add(c.id);
    out.push(c);
  };
  for (const c of cases) visit(c);
  return out;
}

// Match an id against a comma list of patterns with `*` wildcards.
export function idMatches(id, patterns) {
  if (!patterns || patterns.length === 0) return true;
  return patterns.some((p) => new RegExp('^' + p.split('*').map(escapeRe).join('.*') + '$').test(id));
}

function escapeRe(s) {
  return s.replace(/[.+?^${}()|[\]\\]/g, '\\$&');
}
