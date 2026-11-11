#!/usr/bin/env node
// dl-api: one call to the DataLoader API for dl-configure.
//
//   node dl-api.mjs METHOD PATH [--base-url URL] [--body-file FILE] [--token-file FILE]
//
// The bearer comes from --token-file, DL_API_TOKEN, or an OAuth client
// (DL_OAUTH_CLIENT_ID and DL_OAUTH_CLIENT_SECRET). In the body file,
// ${NAME} is replaced from the environment, so a password can stay in an
// environment variable instead of the file. Prefer kv://vault/secret
// references, which DataLoader resolves itself. The answer is printed
// with secrets redacted; the exit code is 0 for a 2xx answer, 1 for any
// other answer, 2 when the call could not be made.

import { readFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { exitQuietlyOnEpipe, helpRequested } from './lib/cli.mjs';
import { substValue } from './lib/expect.mjs';
import { Redactor } from './lib/redact.mjs';
import { resolveToken } from './lib/token.mjs';

// Git Bash on Windows turns an argument that starts with / into a Windows path
// (C:/Program Files/Git/api/v1/...) before node sees it. Take the API path
// back out of it.
export function unmangledPath(arg) {
  if (!arg) return arg;
  const i = arg.indexOf('/api/v1/');
  return i > 0 ? arg.slice(i) : arg;
}

async function main() {
  if (helpRequested(import.meta.url)) return 0;
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: { 'base-url': { type: 'string' }, 'body-file': { type: 'string' }, 'token-file': { type: 'string' } },
  });
  const [method] = positionals;
  const path = unmangledPath(positionals[1]);
  if (!method || !path || !path.startsWith('/api/v1/')) {
    process.stderr.write('usage: dl-api.mjs METHOD /api/v1/... [--base-url URL] [--body-file FILE]\n');
    return 2;
  }
  const base = (values['base-url'] || process.env.DL_BASE_URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
  const redactor = new Redactor();
  let token = '';
  try {
    const t = await resolveToken({ tokenFile: values['token-file'], baseUrl: base });
    token = t.token;
    if (t.secret) redactor.add('DL_OAUTH_CLIENT_SECRET', t.secret);
  } catch (e) {
    process.stderr.write(`dl-api: ${e.message}\n`);
    return 2;
  }
  if (token) redactor.add('DL_API_TOKEN', token);
  const headers = { accept: 'application/json' };
  if (token) headers.authorization = `Bearer ${token}`;
  let body;
  if (values['body-file']) {
    const raw = JSON.parse(readFileSync(values['body-file'], 'utf8'));
    const missing = [];
    const filled = substValue(raw, (name) => {
      if (process.env[name] === undefined) missing.push(name);
      else redactor.add(name, process.env[name]);
      return process.env[name];
    });
    if (missing.length) {
      process.stderr.write(`dl-api: set ${[...new Set(missing)].join(', ')} in the environment first\n`);
      return 2;
    }
    body = JSON.stringify(filled);
    headers['content-type'] = 'application/json';
  }

  try {
    const res = await fetch(base + path, { method: method.toUpperCase(), headers, body, signal: AbortSignal.timeout(120_000) });
    const text = await res.text();
    let shown = text;
    try {
      shown = JSON.stringify(JSON.parse(text), null, 2);
    } catch {
      // not JSON, print as is
    }
    process.stdout.write(`${method.toUpperCase()} ${path} -> ${res.status}\n${redactor.redact(shown)}\n`);
    return res.ok ? 0 : 1;
  } catch (e) {
    process.stderr.write(`dl-api: no answer from ${base} (${e.cause?.code || e.message})\n`);
    return 2;
  }
}

// exitCode rather than exit(): exiting with fetch handles still closing
// trips a libuv assertion on Windows.
exitQuietlyOnEpipe();
process.exitCode = await main();
