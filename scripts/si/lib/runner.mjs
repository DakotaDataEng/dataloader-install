// Runs the plan's automatable cases against one install.

import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { basename } from 'node:path';
import { checksOf, idMatches, orderByDependencies } from './plan.mjs';
import {
  asList, checkContains, checkJson, checkJsonContains, checkNotContains, checkStatus,
  getPath, looseEqual, substText, substValue, textOf, varsIn,
} from './expect.mjs';
import { isSecretName } from './redact.mjs';

const EXCERPT = 800;
const HTTP_TIMEOUT_MS = 60_000;
const CLI_TIMEOUT_MS = 300_000;
// A vars value that is exactly "${NAME}" names another variable.
const NAMED_REF_RE = /^\$\{([A-Z][A-Z0-9_]*)\}$/;
// Variables the plan's Variables tables say default to another name, so an SI
// who leaves them out gets the documented behavior.
const DEFAULT_REFS = { LOAD_SRC_ID: 'CONN_POSTGRES_ID', DEST_DEFAULT_ID: 'DEST_POSTGRES_ID' };

export class Runner {
  // opts: { vars, token, tags, only, allowDestructive, allow, redactor,
  //         saved, previous, log, sleep }
  constructor(opts) {
    this.vars = { ...(opts.vars || {}) };
    for (const [name, ref] of Object.entries(DEFAULT_REFS)) {
      if (this.vars[name] === undefined) this.vars[name] = '${' + ref + '}';
    }
    this.token = opts.token || '';
    this.tags = new Set(opts.tags || []);
    this.only = opts.only || [];
    this.allowDestructive = !!opts.allowDestructive;
    this.allow = new Set(opts.allow || []);
    this.redactor = opts.redactor;
    this.saved = { ...(opts.saved || {}) };
    this.previous = opts.previous || {};
    this.log = opts.log || (() => {});
    this.sleep = opts.sleep || ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.now = opts.now || Date.now;
    this.results = new Map();
    if (this.token) this.redactor.add('DL_API_TOKEN', this.token);
    this.redactor.addVars(this.vars);
    for (const [k, v] of Object.entries(this.saved)) if (isSecretName(k)) this.redactor.add(k, v);
  }

  // A saved value wins. A vars value that names another variable, such as
  // LOAD_SRC_ID=${CONN_POSTGRES_ID}, resolves one level: to that name's saved
  // value, or its plain vars value. A name that resolves to nothing stays unset.
  lookup = (name) => {
    if (this.saved[name] !== undefined) return this.saved[name];
    const ref = this.refOf(name);
    if (ref === null) return this.vars[name];
    return this.saved[ref] !== undefined ? this.saved[ref] : this.plainVar(ref);
  };

  // The name a vars value points at, or null when the value is plain.
  refOf(name) {
    const v = this.vars[name];
    const m = typeof v === 'string' ? NAMED_REF_RE.exec(v) : null;
    return m ? m[1] : null;
  }

  plainVar(name) {
    return this.refOf(name) === null ? this.vars[name] : undefined;
  }

  // Variables the case uses that point at a name no earlier case has saved.
  // The case fails on these with a note that names the missing save.
  danglingRefs(c) {
    const out = new Set();
    const savedHere = new Set();
    for (const ch of checksOf(c)) {
      for (const n of varsIn(ch)) {
        const ref = this.refOf(n);
        if (ref !== null && this.lookup(n) === undefined && !savedHere.has(ref)) {
          out.add(`${n} is set to \${${ref}}, which no earlier case saved`);
        }
      }
      for (const k of Object.keys(ch.save || {})) savedHere.add(k);
    }
    return [...out];
  }

  async runAll(cases) {
    for (const c of orderByDependencies(cases)) {
      if (!idMatches(c.id, this.only)) continue;
      const started = Date.now();
      const r = await this.runCase(c);
      r.duration_ms = Date.now() - started;
      r.ran_at = new Date(started).toISOString();
      this.results.set(c.id, r);
      this.log(`${c.id} ${label(r)}${r.note ? ': ' + r.note : ''}`);
    }
    return [...this.results.values()];
  }

  base(c) {
    return { id: c.id, title: c.title, section: c.section, mode: c.mode, known_issue: c.known_issue || null, evidence: [] };
  }

  notRun(c, reason, note, extra = {}) {
    return { ...this.base(c), result: 'not_run', reason, note, ...extra };
  }

  statusOf(id) {
    const r = this.results.get(id) || this.previous[id];
    return r ? r.result : undefined;
  }

  // Names a case needs that nobody has set. Values a check saves count as
  // set for the checks after it.
  missingVars(c) {
    const missing = new Set();
    const savedHere = new Set();
    for (const ch of checksOf(c)) {
      const need = varsIn(ch);
      if (ch.kind === 'http') {
        need.add('BASE_URL');
        const auth = ch.auth || 'session';
        if (auth === 'session') {
          // The admin session, or the SI's API token in its place.
          if (!this.token) need.add('SESSION');
        } else if (auth.startsWith('session:') || auth.startsWith('bearer:')) {
          need.add(auth.split(':')[1]);
        }
      }
      if (ch.kind === 'ui') need.add('PUBLIC_URL');
      if (ch.kind === 'sql') {
        need.add(ch.target);
        const dsn = this.lookup(ch.target);
        if (dsn !== undefined && this.lookup(ch.target + '_CMD') === undefined && !/^postgres(ql)?:\/\//.test(textOf(dsn))) {
          need.add(ch.target + '_CMD');
        }
      }
      for (const n of need) {
        // A dangling reference fails the case in runCase, with its own note.
        if (this.lookup(n) === undefined && !savedHere.has(n) && this.refOf(n) === null) missing.add(n);
      }
      for (const k of Object.keys(ch.save || {})) savedHere.add(k);
    }
    return [...missing];
  }

  async runCase(c) {
    if (c.mode === 'visual') return this.notRun(c, 'visual', 'a person checks this on screen', { look_for: c.look_for });
    const offTags = (c.requires || []).filter((t) => !this.tags.has(t));
    if (offTags.length) return this.notRun(c, 'na', `needs ${offTags.join(', ')} enabled for this run`);
    const failedDeps = (c.depends_on || []).filter((d) => ['fail', 'expected_fail'].includes(this.statusOf(d)));
    if (failedDeps.length) return this.notRun(c, 'dependency', `depends on ${failedDeps.join(', ')}, which failed`);
    const dangling = this.danglingRefs(c);
    if (dangling.length) return { ...this.base(c), result: 'fail', note: dangling.join('; ') };
    const missing = this.missingVars(c);
    if (missing.length) return this.notRun(c, 'na', `needs ${missing.join(', ')}`);
    if (c.destructive && !this.allowDestructive && !this.allow.has(c.id)) {
      return this.notRun(c, 'destructive', 'changes or restarts the install; run it with --allow ' + c.id);
    }

    const r = { ...this.base(c), result: 'pass', note: '' };
    const pendingUi = [];
    const checks = checksOf(c);
    for (let i = 0; i < checks.length; i++) {
      const ch = checks[i];
      if (ch.kind === 'ui') {
        pendingUi.push({ check: i + 1, ...this.uiDetail(ch) });
        continue;
      }
      const out = await this.runWithRetry(ch);
      r.evidence.push({ check: i + 1, kind: ch.kind, ok: out.problems.length === 0, summary: this.redactor.redact(out.summary), detail: this.redactor.redact(out.detail || '') });
      if (out.skip) {
        return { ...r, result: 'not_run', reason: 'na', note: out.skip };
      }
      if (out.problems.length) {
        const rest = checks.length - i - 1;
        r.result = c.known_issue ? 'expected_fail' : 'fail';
        r.note = this.redactor.redact(out.problems.join('; ')) + (rest ? ` (${rest} later check${rest > 1 ? 's' : ''} not run)` : '');
        return r;
      }
      this.save(ch, out);
    }
    if (pendingUi.length) {
      return { ...r, result: 'not_run', reason: 'needs_ui', note: 'browser checks for dl-ui-review or a person to record', pending_ui: pendingUi };
    }
    if (c.known_issue) r.note = `passed although known issue ${c.known_issue} is open; check whether it is fixed`;
    return r;
  }

  uiDetail(ch) {
    const url = textOf(this.lookup('PUBLIC_URL')).replace(/\/$/, '') + substText(ch.path, this.lookup);
    const d = { url, login: !!ch.login };
    for (const k of ['expect_selector', 'expect_text', 'expect_no_console_errors']) if (ch[k] !== undefined) d[k] = substValue(ch[k], this.lookup);
    return d;
  }

  save(ch, out) {
    for (const [name, path] of Object.entries(ch.save || {})) {
      let v;
      if (path === '@cookie') v = out.cookies;
      else if (path === '@body') v = out.raw;
      else v = getPath(out.json, path);
      if (v === undefined || v === null) continue;
      v = textOf(v);
      this.saved[name] = v;
      if (isSecretName(name) || path === '@cookie') this.redactor.add(name, v);
    }
  }

  async runWithRetry(ch) {
    const retry = ch.retry;
    const deadline = retry ? this.now() + Number(retry.for_s) * 1000 : 0;
    let attempts = 0;
    for (;;) {
      attempts++;
      const out = await this.runCheck(ch);
      if (out.skip || out.problems.length === 0 || !retry || this.now() >= deadline) {
        if (retry && attempts > 1) out.summary += ` (after ${attempts} tries)`;
        return out;
      }
      await this.sleep(Number(retry.every_s) * 1000);
    }
  }

  async runCheck(ch) {
    try {
      if (ch.kind === 'http') return await this.http(ch);
      if (ch.kind === 'cli') return await this.cli(ch);
      if (ch.kind === 'sql') return await this.sql(ch);
    } catch (e) {
      return { problems: [`${ch.kind} check could not run: ${e.message}`], summary: `${ch.kind} error`, detail: String(e.stack || e) };
    }
    return { problems: [`unknown check kind ${ch.kind}`], summary: ch.kind };
  }

  async http(ch) {
    const path = substText(ch.path, this.lookup);
    const url = textOf(this.lookup('BASE_URL')).replace(/\/$/, '') + path;
    const headers = { accept: 'application/json', ...substValue(ch.headers || {}, this.lookup) };
    const auth = ch.auth || 'session';
    if (auth === 'session') {
      if (this.lookup('SESSION') !== undefined) headers.cookie = textOf(this.lookup('SESSION'));
      else if (this.token) headers.authorization = `Bearer ${this.token}`;
    } else if (auth.startsWith('session:')) {
      headers.cookie = textOf(this.lookup(auth.slice(8)));
    } else if (auth.startsWith('bearer:')) {
      headers.authorization = `Bearer ${textOf(this.lookup(auth.slice(7)))}`;
    }
    let body;
    let sent = '';
    if (ch.body !== undefined) {
      body = JSON.stringify(substValue(ch.body, this.lookup));
      headers['content-type'] = 'application/json';
      sent = body;
    } else if (ch.form !== undefined) {
      const form = substValue(ch.form, this.lookup);
      body = new URLSearchParams(Object.entries(form).map(([k, v]) => [k, textOf(v)])).toString();
      headers['content-type'] = 'application/x-www-form-urlencoded';
      sent = body;
    } else if (ch.multipart !== undefined) {
      body = new FormData();
      for (const [k, v] of Object.entries(substValue(ch.multipart, this.lookup))) {
        const s = textOf(v);
        if (s.startsWith('@')) body.append(k, new Blob([readFileSync(s.slice(1))]), basename(s.slice(1)));
        else body.append(k, s);
      }
      sent = '[multipart]';
    }
    const res = await fetch(url, { method: ch.method, headers, body, redirect: 'manual', signal: AbortSignal.timeout(HTTP_TIMEOUT_MS) });
    const raw = await res.text();
    let json;
    try {
      json = raw ? JSON.parse(raw) : undefined;
    } catch {
      json = undefined;
    }
    const problems = [
      ...checkStatus(res.status, ch.expect_status),
      ...checkJson(json, substValue(ch.expect_json, this.lookup)),
      ...checkJsonContains(json, raw, substValue(ch.expect_json_contains, this.lookup)),
      ...checkNotContains(raw, substValue(ch.expect_body_not_contains, this.lookup), 'body'),
    ];
    const setCookies = typeof res.headers.getSetCookie === 'function' ? res.headers.getSetCookie() : asList(res.headers.get('set-cookie'));
    const cookies = setCookies.map((c) => c.split(';')[0]).filter(Boolean).join('; ');
    return {
      problems,
      summary: `${ch.method} ${path} answered ${res.status}`,
      detail: (sent ? `sent: ${excerpt(sent)}\n` : '') + `body: ${excerpt(raw)}`,
      json,
      raw,
      cookies: cookies || undefined,
    };
  }

  async cli(ch) {
    const cmd = substText(ch.run, this.lookup);
    const hostShell = this.lookup('HOST_SHELL');
    const full = hostShell ? `${textOf(hostShell)} ${shQuote(cmd)}` : cmd;
    // Git Bash on Windows rewrites an argument such as /var/lib/x into a
    // Windows path before docker sees it.
    const out = await runProcess('bash', ['-c', full], undefined, { ...process.env, MSYS_NO_PATHCONV: '1' });
    if (out.notFound) return { skip: 'bash is not installed on this machine; run dl-verify where bash is', problems: [], summary: 'cli not run' };
    const problems = [];
    const wantExit = ch.expect_exit === undefined ? 0 : Number(ch.expect_exit);
    if (out.code !== wantExit) problems.push(`exit ${out.code}, expected ${wantExit}`);
    problems.push(...checkContains(out.stdout, substValue(ch.expect_stdout_contains, this.lookup), 'stdout'));
    problems.push(...checkNotContains(out.stdout, substValue(ch.expect_stdout_not_contains, this.lookup), 'stdout'));
    return {
      problems,
      summary: `\`${excerpt(cmd, 200)}\` exited ${out.code}`,
      detail: `stdout: ${excerpt(out.stdout, EXCERPT, true)}` + (out.stderr ? `\nstderr: ${excerpt(out.stderr, 400, true)}` : ''),
    };
  }

  async sql(ch) {
    const query = substText(ch.query, this.lookup);
    const dsn = textOf(this.lookup(ch.target));
    const custom = this.lookup(ch.target + '_CMD');
    const out = custom !== undefined
      ? await runProcess('bash', ['-c', textOf(custom)], query)
      : await runProcess('psql', [dsn, '-At', '-v', 'ON_ERROR_STOP=1', '-c', query], undefined);
    if (out.notFound) return { skip: `no SQL client for ${ch.target}: install psql or set ${ch.target}_CMD`, problems: [], summary: 'sql not run' };
    const problems = [];
    if (out.code !== 0) problems.push(`SQL client exited ${out.code}`);
    const first = (out.stdout.split(/\r?\n/).find((l) => l.trim() !== '') || '').split(/[|\t,]/)[0].trim();
    if (out.code === 0) {
      if (ch.expect_scalar !== undefined) {
        const want = substValue(ch.expect_scalar, this.lookup);
        if (!looseEqual(first, want)) problems.push(`first value is ${first || 'empty'}, expected ${textOf(want)}`);
      }
      if (ch.expect_min !== undefined) {
        const min = Number(substValue(ch.expect_min, this.lookup));
        if (!(Number(first) >= min)) problems.push(`first value is ${first || 'empty'}, expected at least ${min}`);
      }
    }
    return {
      problems,
      summary: `${ch.target}: ${excerpt(query, 200)} returned ${first || 'nothing'}`,
      detail: out.stderr ? `stderr: ${excerpt(out.stderr, 400, true)}` : '',
    };
  }
}

export function label(r) {
  if (r.result === 'not_run') return `not run (${r.reason})`;
  return r.result.replace('_', ' ');
}

function excerpt(s, n = EXCERPT, tail = false) {
  const t = String(s ?? '');
  if (t.length <= n) return t;
  return tail ? '...' + t.slice(t.length - n) : t.slice(0, n) + '...';
}

export function shQuote(s) {
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

export function runProcess(cmd, args, input, env) {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    let child;
    try {
      child = spawn(cmd, args, { timeout: CLI_TIMEOUT_MS, windowsHide: true, env });
    } catch (e) {
      resolve({ notFound: e.code === 'ENOENT', code: -1, stdout, stderr: String(e) });
      return;
    }
    child.stdout.on('data', (d) => (stdout += d));
    child.stderr.on('data', (d) => (stderr += d));
    child.on('error', (e) => resolve({ notFound: e.code === 'ENOENT', code: -1, stdout, stderr: String(e.message) }));
    child.on('close', (code) => resolve({ code: code ?? -1, stdout, stderr }));
    child.stdin.on('error', () => {});
    if (input !== undefined) child.stdin.end(input);
    else child.stdin.end();
  });
}
