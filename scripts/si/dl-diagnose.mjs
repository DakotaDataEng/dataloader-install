#!/usr/bin/env node
// dl-diagnose: collects health, version, logs and config from one install,
// matches known failure signatures, and writes the findings with the
// runbook section for each fix. Config is copied by allowlist
// (lib/allowlist.mjs): `.env` key names and a few known-safe values, and
// listed API fields only. Logs are redacted by pattern.
//
//   node dl-diagnose.mjs collect --out DIR [--base-url URL] [--public-url URL]
//                                [--install-dir DIR] [--compose CMD] [--host-shell CMD]
//                                [--log-lines N] [--probe] [--token-file FILE]
//   node dl-diagnose.mjs match   --out DIR          # match an existing bundle again
//   node dl-diagnose.mjs match   FILE [FILE...]     # match pasted logs or output
//
// The bearer comes from --token-file, DL_API_TOKEN, or an OAuth client
// (DL_OAUTH_CLIENT_ID and DL_OAUTH_CLIENT_SECRET). Without one, only
// the routes that need no sign-in are read. --probe also runs the Test of
// every vault, connection and destination (reads only, nothing changes).

import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';
import { parseArgs } from 'node:util';
import { allowlistFor, envSummaryCommand, project, summarizeEnv } from './lib/allowlist.mjs';
import { exitQuietlyOnEpipe, helpRequested } from './lib/cli.mjs';
import { Redactor } from './lib/redact.mjs';
import { runProcess, shQuote } from './lib/runner.mjs';
import { matchSignatures, structuredFindings } from './lib/signatures.mjs';
import { resolveToken } from './lib/token.mjs';

// Only called before any request is made; after one, exit() can trip a
// libuv assertion on Windows.
function fail(msg) {
  process.stderr.write(`dl-diagnose: ${msg}\n`);
  process.exit(2);
}

const OPEN_ROUTES = ['/api/v1/health', '/api/v1/health/ready', '/api/v1/setup/status', '/api/v1/auth/sso/status', '/api/v1/runtime/deployment-target'];
const TOKEN_ROUTES = [
  '/api/v1/auth/me', '/api/v1/settings/sso', '/api/v1/settings/license', '/api/v1/vaults',
  '/api/v1/vaults/managed-identity', '/api/v1/connections', '/api/v1/destinations',
  '/api/v1/dashboard/needs-attention?env=test', '/api/v1/dashboard/needs-attention?env=prod',
];

// The fields of a vault, connection or destination Test answer worth keeping.
const PROBE_ALLOWLIST = ['ok', 'is_healthy', 'status', 'message', 'error', 'code', 'category', 'secret_count'];

// An answer reduced to its allowlisted fields. A non-JSON answer from a
// signed-in route is not copied.
function allowedBody(r, allow) {
  if (r.json === undefined) return r.text ? `[non-JSON answer of ${r.text.length} bytes not collected]` : '';
  return allow ? JSON.stringify(project(r.json, allow)) : '[no field allowlist for this route: not collected]';
}

function fileName(prefix, path) {
  return `${prefix}-${path.replace(/^\/api\/v1\//, '').replace(/[^A-Za-z0-9]+/g, '-').replace(/-+$/, '')}.txt`;
}

async function get(baseUrl, path, token, method = 'GET') {
  const headers = { accept: 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  try {
    const res = await fetch(baseUrl + path, { method, headers, redirect: 'manual', signal: AbortSignal.timeout(30_000) });
    const text = await res.text();
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      json = undefined;
    }
    return { status: res.status, text, json };
  } catch (e) {
    return { error: e.cause?.code || e.message };
  }
}

async function collect(opts) {
  if (!opts.out) fail('--out DIR is required');
  const dir = resolve(opts.out);
  if (existsSync(join(dir, '.git'))) fail(`${dir} is a repository root; pick a run directory outside it`);
  mkdirSync(dir, { recursive: true });
  const baseUrl = (opts['base-url'] || 'http://127.0.0.1:8080').replace(/\/$/, '');
  const redactor = new Redactor();
  let token = '';
  let tokenNote;
  try {
    const t = await resolveToken({ tokenFile: opts['token-file'], baseUrl });
    token = t.token;
    if (t.secret) redactor.add('DL_OAUTH_CLIENT_SECRET', t.secret);
  } catch (e) {
    tokenNote = `No API access: ${e.message}.`;
  }
  if (token) redactor.add('DL_API_TOKEN', token);
  const write = (name, text) => writeFileSync(join(dir, name), redactor.redact(String(text ?? '')) + '\n');
  const bundle = { collected_at: new Date().toISOString(), files: [] };
  const note = (name, text) => {
    write(name, text);
    bundle.files.push(name);
  };

  bundle.base_url = baseUrl;
  if (tokenNote) bundle.notes = [tokenNote];
  bundle.public_url = opts['public-url'] || '';
  const health = await get(baseUrl, '/api/v1/health');
  if (health.error) bundle.health_error = health.error;
  else bundle.version = health.json?.version;
  for (const path of OPEN_ROUTES) {
    const r = path === '/api/v1/health' ? health : await get(baseUrl, path);
    note(fileName('http', path), r.error ? `GET ${path}: no answer (${r.error})` : `GET ${path} -> ${r.status}\n${r.text}`);
  }
  if (token && !health.error) {
    const answers = {};
    for (const path of TOKEN_ROUTES) {
      const r = await get(baseUrl, path, token);
      answers[path] = r;
      note(fileName('http', path), r.error ? `GET ${path}: no answer (${r.error})` : `GET ${path} -> ${r.status}\n${allowedBody(r, allowlistFor(path))}`);
    }
    if (opts.probe) {
      const lines = [];
      const items = (path) => {
        const j = answers[path]?.json;
        return Array.isArray(j) ? j : Array.isArray(j?.items) ? j.items : Array.isArray(j?.vaults) ? j.vaults : [];
      };
      for (const [path, kind] of [['/api/v1/vaults', 'vaults'], ['/api/v1/connections', 'connections'], ['/api/v1/destinations', 'destinations']]) {
        for (const it of items(path)) {
          if (!it.id) continue;
          const r = await get(baseUrl, `/api/v1/${kind}/${it.id}/test`, token, 'POST');
          lines.push(`POST /api/v1/${kind}/${it.id}/test (${it.name || it.connection_key || it.destination_key || ''}) -> ${r.status ?? r.error}\n${r.error ? '' : allowedBody(r, PROBE_ALLOWLIST)}`);
        }
      }
      note('probe-tests.txt', lines.join('\n\n') || 'nothing to test');
    }
  } else if (!token) {
    bundle.notes = [...(bundle.notes || []), 'No API token: only the routes that need no sign-in were read.'];
  }

  const hostShell = opts['host-shell'];
  const sh = (cmd) => runProcess('bash', ['-c', hostShell ? `${hostShell} ${shQuote(cmd)}` : cmd]);
  const installDir = opts['install-dir'] || '/opt/dataloader';
  const compose = opts.compose || `docker compose -f ${installDir}/docker-compose.deploy.yml`;
  const lines = Number(opts['log-lines'] || 2000);
  const cliSteps = [
    ['cli-docker-version.txt', 'docker version'],
    ['cli-compose-ps.txt', `${compose} ps`],
    ['cli-compose-logs.txt', `${compose} logs --no-color --tail ${lines} dataloader`],
    // Key names and allowlisted values only; nothing else leaves the host.
    ['cli-env-keys.txt', envSummaryCommand(`${installDir}/.env`)],
    ['cli-host.txt', 'uname -a; cat /etc/os-release 2>/dev/null | head -3; df -h / /var/lib/docker 2>/dev/null; docker system df 2>/dev/null'],
  ];
  if (opts['skip-cli']) bundle.notes = [...(bundle.notes || []), 'Host commands skipped.'];
  for (const [name, cmd] of opts['skip-cli'] ? [] : cliSteps) {
    const out = await sh(cmd);
    if (out.notFound) {
      bundle.notes = [...(bundle.notes || []), 'bash is not installed here, so no host commands ran. Run dl-diagnose on the host or pass --host-shell.'];
      break;
    }
    if (name === 'cli-env-keys.txt') {
      // The summary again on this side, in case the host printed more than
      // the command asked for. No stderr: it is not needed and not filtered.
      note(name, `${installDir}/.env\n${out.stdout.trim() ? summarizeEnv(out.stdout) : 'could not read the file (exit ' + out.code + ')'}`);
      continue;
    }
    note(name, `$ ${cmd}\nexit ${out.code}\n${out.stdout}${out.stderr ? '\nstderr:\n' + out.stderr : ''}`);
  }
  writeFileSync(join(dir, 'bundle.json'), JSON.stringify(bundle, null, 2) + '\n');
  return analyze(dir, bundle);
}

function analyze(dir, bundle) {
  const sources = bundle.files.map((f) => ({ source: f, text: readFileSync(join(dir, f), 'utf8') }));
  let health;
  try {
    health = JSON.parse(readFileSync(join(dir, 'http-health.txt'), 'utf8').split('\n').slice(1).join('\n'));
  } catch {
    health = undefined;
  }
  const findings = [...structuredFindings({ health, healthError: bundle.health_error, publicUrl: bundle.public_url }), ...matchSignatures(sources)];
  writeFileSync(join(dir, 'findings.json'), JSON.stringify(findings, null, 2) + '\n');
  writeFileSync(join(dir, 'findings.md'), renderFindings(findings, bundle));
  process.stdout.write(renderFindings(findings, bundle));
  return findings;
}

function renderFindings(findings, bundle) {
  const out = ['# DataLoader diagnosis', ''];
  if (bundle.base_url) out.push(`Install: ${bundle.base_url}${bundle.version ? `, version ${bundle.version}` : ''}. Collected ${bundle.collected_at}.`, '');
  for (const n of bundle.notes || []) out.push(`- ${n}`);
  if ((bundle.notes || []).length) out.push('');
  if (findings.length === 0) {
    out.push('No known failure signature matched. Read the collected files, starting with the logs.', '');
  }
  for (const f of findings) {
    out.push(`## ${f.title}`, '', f.fix, '', `Runbook: docs/runbooks/${f.runbook}`, '', 'Seen in:');
    for (const h of f.hits) out.push(`- ${h.source}: \`${h.line.replace(/`/g, "'")}\``);
    out.push('');
  }
  out.push('Files in this bundle (secrets redacted):', ...bundle.files.map((f) => `- ${f}`), '');
  return out.join('\n');
}

exitQuietlyOnEpipe();
if (helpRequested(import.meta.url)) process.exit(0);

const { positionals, values } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: 'string' }, 'base-url': { type: 'string' }, 'public-url': { type: 'string' },
    'install-dir': { type: 'string' }, compose: { type: 'string' }, 'host-shell': { type: 'string' },
    'log-lines': { type: 'string' }, probe: { type: 'boolean' }, 'token-file': { type: 'string' },
    'skip-cli': { type: 'boolean' },
  },
});

const cmd = positionals[0];
if (cmd === 'collect') {
  await collect(values);
} else if (cmd === 'match') {
  if (values.out) {
    const dir = resolve(values.out);
    const bundle = JSON.parse(readFileSync(join(dir, 'bundle.json'), 'utf8'));
    analyze(dir, bundle);
  } else {
    const files = positionals.slice(1);
    if (files.length === 0) fail('match needs --out DIR or one or more files');
    const redactor = new Redactor();
    const sources = files.flatMap((f) => (existsSync(f) && !f.endsWith('/') && readdirSafe(f) === null ? [{ source: basename(f), text: redactor.redact(readFileSync(f, 'utf8')) }] : []));
    const findings = matchSignatures(sources);
    process.stdout.write(renderFindings(findings, { files: sources.map((s) => s.source) }));
  }
} else {
  fail('usage: dl-diagnose.mjs collect|match (see the header of this file)');
}

function readdirSafe(p) {
  try {
    return readdirSync(p);
  } catch {
    return null;
  }
}
