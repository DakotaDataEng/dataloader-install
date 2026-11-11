// Variable substitution and the expectation matchers the plan's check
// kinds use.

const VAR_RE = /\$\{([A-Z][A-Z0-9_]*)\}/g;
const WHOLE_VAR_RE = /^\$\{([A-Z][A-Z0-9_]*)\}$/;

// Read a vars file: a JSON object, or KEY=VALUE lines (# comments allowed).
export function parseVars(text) {
  const t = text.trim();
  if (t.startsWith('{')) {
    return Object.fromEntries(Object.entries(JSON.parse(t)).filter(([, v]) => v !== '' && v !== null));
  }
  const vars = {};
  for (const line of t.split(/\r?\n/)) {
    const m = /^\s*([A-Z][A-Z0-9_]*)\s*=(.*)$/.exec(line);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"') && v.length >= 2) || (v.startsWith("'") && v.endsWith("'") && v.length >= 2)) v = v.slice(1, -1);
    // An empty value is unset, so its cases are N/A rather than run blank.
    if (v !== '') vars[m[1]] = v;
  }
  return vars;
}

export function textOf(v) {
  return typeof v === 'string' ? v : JSON.stringify(v);
}

function valueOf(v) {
  if (typeof v !== 'string') return v;
  try {
    return JSON.parse(v);
  } catch {
    return v;
  }
}

// Every ${NAME} a value references.
export function varsIn(value, out = new Set()) {
  if (typeof value === 'string') {
    for (const m of value.matchAll(VAR_RE)) out.add(m[1]);
  } else if (Array.isArray(value)) {
    value.forEach((v) => varsIn(v, out));
  } else if (value && typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      varsIn(k, out);
      varsIn(v, out);
    }
  }
  return out;
}

// Substitute into a string: ${NAME} becomes the variable's text.
export function substText(s, lookup) {
  return s.replace(VAR_RE, (m, name) => {
    const v = lookup(name);
    return v === undefined ? m : textOf(v);
  });
}

// Substitute into a JSON value. A string that is exactly "${NAME}" takes
// the variable's value parsed as JSON; any other string gets text
// substitution.
export function substValue(value, lookup) {
  if (typeof value === 'string') {
    const whole = WHOLE_VAR_RE.exec(value);
    if (whole) {
      const v = lookup(whole[1]);
      return v === undefined ? value : valueOf(v);
    }
    return substText(value, lookup);
  }
  if (Array.isArray(value)) return value.map((v) => substValue(v, lookup));
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[substText(k, lookup)] = substValue(v, lookup);
    return out;
  }
  return value;
}

// Walk a dotted path (`items.0.status`) into parsed JSON.
export function getPath(obj, path) {
  if (path === '' || path === undefined) return obj;
  let cur = obj;
  for (const part of String(path).split('.')) {
    if (cur === null || cur === undefined) return undefined;
    if (Array.isArray(cur) && /^\d+$/.test(part)) cur = cur[Number(part)];
    else if (typeof cur === 'object') cur = cur[part];
    else return undefined;
  }
  return cur;
}

// Loose equality: numbers and their strings match, so "250" equals 250.
export function looseEqual(actual, expected) {
  if (actual === expected) return true;
  if (actual === null || actual === undefined || expected === null || expected === undefined) return false;
  if (typeof actual === 'object' || typeof expected === 'object') return JSON.stringify(actual) === JSON.stringify(expected);
  return String(actual) === String(expected);
}

function short(v) {
  const s = v === undefined ? 'missing' : JSON.stringify(v);
  return s.length > 120 ? s.slice(0, 117) + '...' : s;
}

export function checkStatus(status, expected) {
  if (expected === undefined) return [];
  const ok = Array.isArray(expected) ? expected.map(Number).includes(status) : Number(expected) === status;
  return ok ? [] : [`status ${status}, expected ${Array.isArray(expected) ? expected.join(' or ') : expected}`];
}

export function checkJson(body, expected) {
  if (!expected) return [];
  const problems = [];
  for (const [path, want] of Object.entries(expected)) {
    const got = getPath(body, path);
    if (want === '*') {
      if (got === undefined || got === null) problems.push(`${path} is missing`);
    } else if (!looseEqual(got, want)) {
      problems.push(`${path} is ${short(got)}, expected ${short(want)}`);
    }
  }
  return problems;
}

export function checkJsonContains(body, rawText, expected) {
  if (!expected) return [];
  const problems = [];
  for (const [path, want] of Object.entries(expected)) {
    const got = path === '@body' ? rawText : getPath(body, path);
    let ok = false;
    if (Array.isArray(got)) ok = got.some((g) => looseEqual(g, want) || (typeof g === 'string' && g.includes(textOf(want))));
    else if (typeof got === 'string') ok = got.includes(textOf(want));
    else if (got !== undefined && got !== null) ok = JSON.stringify(got).includes(textOf(want));
    if (!ok) problems.push(`${path} does not contain ${short(want)}`);
  }
  return problems;
}

export function asList(v) {
  if (v === undefined || v === null) return [];
  return Array.isArray(v) ? v : [v];
}

export function checkContains(text, wanted, label) {
  return asList(wanted)
    .filter((w) => !text.includes(textOf(w)))
    .map((w) => `${label} does not contain ${short(w)}`);
}

export function checkNotContains(text, unwanted, label) {
  return asList(unwanted)
    .filter((w) => textOf(w) !== '' && text.includes(textOf(w)))
    .map((w) => `${label} contains ${short(w)}`);
}
