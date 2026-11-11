#!/usr/bin/env node
// dl-verify: runs the client acceptance plan's automatable cases against
// one DataLoader install and writes a report per run.
//
//   node dl-verify.mjs list   [--plan FILE]
//   node dl-verify.mjs run    --out DIR [--plan FILE] [--vars FILE] [--tags a,b]
//                             [--only CAT-AUTH-*,CAT-HEALTH-04] [--allow CAT-HEALTH-14]
//                             [--allow-destructive] [--token-file FILE]
//   node dl-verify.mjs record --out DIR --id CAT-X --result pass|fail|not_run
//                             [--note TEXT] [--screenshot FILE]
//   node dl-verify.mjs report --out DIR
//
// The bearer comes from --token-file, DL_API_TOKEN, or an OAuth client
// (DL_OAUTH_CLIENT_ID and DL_OAUTH_CLIENT_SECRET), never from the command
// line, and is never written to the run directory.

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { parseVars, textOf } from './lib/expect.mjs';
import { exitQuietlyOnEpipe, helpRequested } from './lib/cli.mjs';
import { checksOf, parsePlan } from './lib/plan.mjs';
import { isSecretName, Redactor } from './lib/redact.mjs';
import { renderReport, summarize } from './lib/report.mjs';
import { findRunbooks, RUNBOOK_FILES } from './lib/runbooks.mjs';
import { label, Runner } from './lib/runner.mjs';
import { resolveToken } from './lib/token.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));

exitQuietlyOnEpipe();
if (helpRequested(import.meta.url)) process.exit(0);

function toolVersion() {
  try {
    const version = readFileSync(join(HERE, 'VERSION'), 'utf8').trim();
    if (version) return version;
  } catch {}
  try {
    return JSON.parse(readFileSync(join(HERE, '..', '.claude-plugin', 'plugin.json'), 'utf8')).version;
  } catch {
    return 'unknown';
  }
}

function list(v) {
  return v ? String(v).split(',').map((s) => s.trim()).filter(Boolean) : [];
}

class UsageError extends Error {}

function fail(msg) {
  throw new UsageError(msg);
}

function planPath(explicit) {
  if (explicit) return resolve(explicit);
  const dir = findRunbooks();
  if (!dir) fail('cannot find docs/runbooks/client-acceptance-test-plan.md; pass --plan or set DL_RUNBOOKS_DIR');
  return join(dir, RUNBOOK_FILES.plan);
}

function loadPlan(file) {
  const text = readFileSync(file, 'utf8');
  return { ...parsePlan(text), sha256: createHash('sha256').update(text).digest('hex') };
}

// A run directory holds credentials-free evidence only, and never sits at
// the root of a repository.
function runDir(out) {
  if (!out) fail('--out DIR is required');
  const dir = resolve(out);
  if (existsSync(join(dir, '.git'))) fail(`${dir} is a repository root; pick a run directory outside it`);
  mkdirSync(dir, { recursive: true });
  return dir;
}

function readJson(file, fallback) {
  try {
    return JSON.parse(readFileSync(file, 'utf8'));
  } catch {
    return fallback;
  }
}

function writeOutputs(dir, results, meta) {
  const ordered = meta.order ? [...results].sort((a, b) => meta.order.indexOf(a.id) - meta.order.indexOf(b.id)) : results;
  writeFileSync(join(dir, 'results.json'), JSON.stringify({ meta, results: ordered }, null, 2) + '\n');
  writeFileSync(join(dir, 'report.md'), renderReport(ordered, meta));
  const pending = ordered.filter((r) => r.reason === 'needs_ui').map((r) => ({ id: r.id, title: r.title, checks: r.pending_ui }));
  writeFileSync(join(dir, 'ui-pending.json'), JSON.stringify(pending, null, 2) + '\n');
}

async function healthVersion(baseUrl) {
  try {
    const res = await fetch(textOf(baseUrl).replace(/\/$/, '') + '/api/v1/health', { signal: AbortSignal.timeout(10_000) });
    const j = await res.json();
    return j.version;
  } catch {
    return undefined;
  }
}

async function cmdRun(opts) {
  const dir = runDir(opts.out);
  const file = planPath(opts.plan);
  const plan = loadPlan(file);
  if (plan.errors.length) fail(`the plan has marker errors:\n  ${plan.errors.join('\n  ')}`);
  const vars = opts.vars ? parseVars(readFileSync(opts.vars, 'utf8')) : {};
  let token;
  let oauthSecret;
  try {
    ({ token, secret: oauthSecret } = await resolveToken({ tokenFile: opts['token-file'], baseUrl: vars.BASE_URL }));
  } catch (e) {
    fail(e.message);
  }

  const prior = readJson(join(dir, 'results.json'), { results: [] });
  const previous = Object.fromEntries((prior.results || []).map((r) => [r.id, r]));
  const saved = readJson(join(dir, 'saved.json'), {});
  const redactor = new Redactor();
  if (oauthSecret) redactor.add('DL_OAUTH_CLIENT_SECRET', oauthSecret);
  const runner = new Runner({
    vars, token, saved, previous, redactor,
    tags: list(opts.tags || vars.TAGS),
    only: list(opts.only),
    allow: list(opts.allow),
    allowDestructive: !!opts['allow-destructive'],
    log: (line) => process.stderr.write(line + '\n'),
  });
  const started = new Date().toISOString();
  const ran = await runner.runAll(plan.cases);
  const merged = { ...previous };
  for (const r of ran) merged[r.id] = r;

  // Keep saved IDs for a later --only run; secrets stay in memory only.
  const keep = Object.fromEntries(Object.entries(runner.saved).filter(([k]) => !isSecretName(k)));
  writeFileSync(join(dir, 'saved.json'), JSON.stringify(keep, null, 2) + '\n');

  const meta = {
    ...(prior.meta || {}),
    base_url: vars.BASE_URL ? textOf(vars.BASE_URL) : '',
    public_url: vars.PUBLIC_URL ? textOf(vars.PUBLIC_URL) : '',
    image_tag: vars.IMAGE_TAG ? textOf(vars.IMAGE_TAG) : '',
    version: (vars.BASE_URL && (await healthVersion(vars.BASE_URL))) || prior.meta?.version || '',
    plan_file: RUNBOOK_FILES.plan,
    plan_sha256: plan.sha256,
    plan_cases: plan.cases.length,
    tags: list(opts.tags || vars.TAGS),
    started_at: prior.meta?.started_at || started,
    finished_at: new Date().toISOString(),
    tool_version: toolVersion(),
    order: plan.cases.map((c) => c.id),
  };
  const results = Object.values(merged);
  writeOutputs(dir, results, meta);
  const c = summarize(ran);
  process.stderr.write(`\nThis run: ${c.pass} pass, ${c.fail} fail, ${c.expected_fail} known-issue fail, ${c.not_run} not run.\nReport: ${join(dir, 'report.md')}\n`);
  // exitCode rather than exit(): exiting with fetch handles still closing
  // trips a libuv assertion on Windows.
  process.exitCode = c.fail > 0 ? 1 : 0;
}

function cmdRecord(opts) {
  const dir = runDir(opts.out);
  const data = readJson(join(dir, 'results.json'), null);
  if (!data) fail(`no results.json in ${dir}; run dl-verify run first`);
  const r = data.results.find((x) => x.id === opts.id);
  if (!r) fail(`no case ${opts.id} in this run`);
  if (!['pass', 'fail', 'not_run'].includes(opts.result)) fail('--result must be pass, fail or not_run');
  const redactor = new Redactor();
  r.result = opts.result === 'fail' && r.known_issue ? 'expected_fail' : opts.result;
  r.reason = opts.result === 'not_run' ? 'na' : undefined;
  r.note = redactor.redact(opts.note || '');
  r.recorded_by = 'person or dl-ui-review';
  r.ran_at = new Date().toISOString();
  r.evidence = r.evidence || [];
  r.evidence.push({ check: r.evidence.length + 1, kind: 'recorded', ok: opts.result === 'pass', summary: r.note || opts.result, screenshot: opts.screenshot || undefined });
  delete r.pending_ui;
  data.meta.finished_at = r.ran_at;
  writeOutputs(dir, data.results, data.meta);
  process.stderr.write(`${r.id} ${label(r)}\n`);
}

function cmdReport(opts) {
  const dir = runDir(opts.out);
  const data = readJson(join(dir, 'results.json'), null);
  if (!data) fail(`no results.json in ${dir}`);
  writeOutputs(dir, data.results, data.meta);
  process.stdout.write(join(dir, 'report.md') + '\n');
}

function cmdList(opts) {
  const file = planPath(opts.plan);
  const plan = loadPlan(file);
  const modes = {};
  const kinds = {};
  for (const c of plan.cases) {
    modes[c.mode] = (modes[c.mode] || 0) + 1;
    for (const ch of checksOf(c)) kinds[ch.kind] = (kinds[ch.kind] || 0) + 1;
  }
  const tags = [...new Set(plan.cases.flatMap((c) => c.requires || []))].sort();
  process.stdout.write(`${file}\n${plan.cases.length} cases: ${Object.entries(modes).map(([k, v]) => `${v} ${k}`).join(', ')}\n`);
  process.stdout.write(`checks: ${Object.entries(kinds).map(([k, v]) => `${v} ${k}`).join(', ')}\n`);
  process.stdout.write(`tags: ${tags.join(', ')}\n`);
  process.stdout.write(`destructive: ${plan.cases.filter((c) => c.destructive).map((c) => c.id).join(', ')}\n`);
  if (plan.errors.length) {
    process.stdout.write(`errors:\n  ${plan.errors.join('\n  ')}\n`);
    process.exitCode = 1;
  }
}

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    plan: { type: 'string' }, vars: { type: 'string' }, out: { type: 'string' }, tags: { type: 'string' },
    only: { type: 'string' }, allow: { type: 'string' }, 'allow-destructive': { type: 'boolean' },
    'token-file': { type: 'string' }, id: { type: 'string' }, result: { type: 'string' },
    note: { type: 'string' }, screenshot: { type: 'string' },
  },
});

const cmd = positionals[0];
try {
  if (cmd === 'run') await cmdRun(values);
  else if (cmd === 'record') cmdRecord(values);
  else if (cmd === 'report') cmdReport(values);
  else if (cmd === 'list') cmdList(values);
  else fail('usage: dl-verify.mjs list|run|record|report (see the header of this file)');
} catch (e) {
  if (!(e instanceof UsageError)) throw e;
  process.stderr.write(`dl-verify: ${e.message}\n`);
  process.exitCode = 2;
}
