// The bearer the scripts send. In order: --token-file, DL_API_TOKEN, or an
// access token fetched with an OAuth client's credentials
// (DL_OAUTH_CLIENT_ID and DL_OAUTH_CLIENT_SECRET, scope DL_OAUTH_SCOPE,
// default "admin runs:trigger", then "admin"). OAuth clients are the product's way forward; API
// tokens still work while any is active.

import { readFileSync } from 'node:fs';

export async function resolveToken({ tokenFile, baseUrl, env = process.env }) {
  if (tokenFile) return { token: readFileSync(tokenFile, 'utf8').trim(), how: 'token file' };
  if (env.DL_API_TOKEN) return { token: env.DL_API_TOKEN, how: 'DL_API_TOKEN' };
  if (env.DL_OAUTH_CLIENT_ID && env.DL_OAUTH_CLIENT_SECRET && baseUrl) {
    const ask = async (scope) => {
      const res = await fetch(String(baseUrl).replace(/\/$/, '') + '/api/v1/oauth/token', {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
        body: new URLSearchParams({
          grant_type: 'client_credentials',
          client_id: env.DL_OAUTH_CLIENT_ID,
          client_secret: env.DL_OAUTH_CLIENT_SECRET,
          scope,
        }),
        signal: AbortSignal.timeout(30_000),
      });
      return { res, j: await res.json().catch(() => ({})) };
    };
    // The admin scope does not cover starting runs, so ask for both. A client
    // registered without runs:trigger still gets an admin token.
    let { res, j } = await ask(env.DL_OAUTH_SCOPE || 'admin runs:trigger');
    if (!env.DL_OAUTH_SCOPE && j.error === 'invalid_scope') ({ res, j } = await ask('admin'));
    if (!res.ok || !j.access_token) throw new Error(`the OAuth client could not get a token (${res.status} ${j.error || ''})`.trim());
    return { token: j.access_token, how: 'OAuth client', secret: env.DL_OAUTH_CLIENT_SECRET };
  }
  return { token: '', how: 'none' };
}
