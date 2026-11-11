// Failure signatures dl-diagnose looks for in a collected bundle. Each one
// names the runbook section that holds the fix, so the advice follows the
// runbook when it changes.

const AZ = 'client-azure-identity-vault-sso-databricks.md';
const SF = 'client-snowflake.md';
const INSTALL = 'install-linux-host.md';

export const SIGNATURES = [
  {
    id: 'docker-not-running',
    title: "Docker isn't running",
    patterns: [/Cannot connect to the Docker daemon/i, /Is the docker daemon running\?/i, /error during connect: .*docker/i, /dockerDesktopLinuxEngine.*(cannot find|not exist)/i, /docker: command not found/i],
    fix: 'Start Docker (`sudo systemctl start docker`, then `systemctl is-active docker`). On a Docker Desktop dev machine, start Docker Desktop and accept its admin prompt. Then re-run the check.',
    runbook: `${INSTALL}#before-you-start`,
  },
  {
    id: 'no-managed-identity',
    title: 'DataLoader has no managed identity on this host',
    patterns: [/no managed identity on this host/i],
    // A host with no vault and no Azure destination has nothing that needs one.
    when: (sources) => usesAzureIdentity(sources),
    fix: 'On an Azure VM, turn on the VM identity and re-run `install.sh --managed-identity` (it keeps `.env` and adds `DL_AZURE_MANAGED_IDENTITY=imds`). Check: the Register vault dialog shows the identity\'s object ID.',
    runbook: `${AZ}#2-install-dataloader-with---managed-identity`,
  },
  {
    id: 'aadsts700016',
    title: 'Entra does not know the client ID (AADSTS700016)',
    patterns: [/AADSTS700016/],
    fix: "The SSO client ID is not the app registration's Application (client) ID. Copy the GUID from the app's Overview page into Admin, Sign-in, Client ID. A browser can autofill an email address there.",
    runbook: `${AZ}#6-register-the-sso-app-in-entra`,
  },
  {
    id: 'session-check-missing-permission',
    title: 'The Entra session check is failing: the app lacks User.Read.All',
    patterns: [/"failure"\s*:\s*"missing_permission"/, /Entra session check is failing/i, /Authorization_RequestDenied/],
    fix: 'Grant Microsoft Graph `User.Read.All` as an application permission with admin consent, then confirm it with `az rest --method GET --url https://graph.microsoft.com/v1.0/servicePrincipals/<sp-object-id>/appRoleAssignments`. Consent can report success without granting the role; the runbook has the POST that grants it.',
    runbook: `${AZ}#9-grant-microsoft-graph-userreadall-and-admin-consent`,
  },
  {
    id: 'session-check-unauthorized',
    title: 'The Entra session check cannot sign in',
    patterns: [/"failure"\s*:\s*"unauthorized"/, /AADSTS7000215|AADSTS700213|AADSTS70021\b/],
    fix: 'The app could not get a Graph token: check the federated credential (issuer, subject, audience) or the client secret in Admin, Sign-in.',
    runbook: `${AZ}#7-let-dataloader-sign-in-as-the-app-without-a-secret`,
  },
  {
    id: 'vault-cannot-list',
    title: 'The vault can be read but not listed',
    patterns: [/cannot list secrets in this vault/i, /lacks secrets\/list permission/i],
    fix: 'Key Vault Secrets User on single secrets lets DataLoader read them but not list them. Either grant the role on the whole vault, or type `kv://<vault>/<secret>` references by hand.',
    runbook: `${AZ}#3-create-the-key-vaults-and-grant-the-identity`,
  },
  {
    id: 'vault-cannot-read',
    title: 'The vault lists but a secret read is refused',
    patterns: [/Key Vault read failed for vault '[^']+': .*(403|Forbidden|lacks)/i],
    fix: "The identity can list the vault but has no Secrets User role on that secret (or the secret is disabled). Grant Key Vault Secrets User on the secret or the vault, then test the connection again.",
    runbook: `${AZ}#3-create-the-key-vaults-and-grant-the-identity`,
  },
  {
    id: 'vault-token-rejected',
    title: 'Key Vault refused the identity\'s token',
    patterns: [/Key Vault did not accept the token/i],
    fix: 'The vault is in another tenant than the identity, or the identity was just created. Check the vault\'s tenant, wait a few minutes, and test again.',
    runbook: `${AZ}#3-create-the-key-vaults-and-grant-the-identity`,
  },
  {
    id: 'vault-firewall',
    title: "The vault's firewall refused DataLoader's network",
    patterns: [/vault's firewall refused/i],
    fix: "Allow the host's network (or its private endpoint) in the vault's networking settings. A role does not fix this.",
    runbook: `${AZ}#5-allow-the-network-paths`,
  },
  {
    id: 'prod-counterpart-missing',
    title: 'A vault names a PROD counterpart that is not registered',
    patterns: [/names a prod counterpart that is not registered/i],
    fix: 'Register the PROD vault and set it as the TEST vault\'s PROD reads in Admin, Key vaults.',
    runbook: `${AZ}#4-register-the-vaults-in-dataloader`,
  },
  {
    id: 'databricks-grant-missing',
    title: 'A Databricks grant is missing',
    patterns: [/PERMISSION_DENIED/, /does not have (USE CATALOG|USE SCHEMA|CREATE TABLE|MODIFY|SELECT|READ VOLUME|WRITE VOLUME|CAN_USE)/i, /User does not have permission/i, /staging volume .* (is not writable|not writable|denied)/i],
    fix: "Give the identity's service principal CAN_USE on the warehouse, USE CATALOG, USE SCHEMA, CREATE TABLE, SELECT and MODIFY on the target schemas, and READ VOLUME and WRITE VOLUME on the staging volume. Check: the destination's Test says the staging volume is writable.",
    runbook: `${AZ}#11-give-the-identity-access-to-databricks`,
  },
  {
    id: 'azure-sql-redirect',
    title: 'Azure SQL redirect ports are blocked',
    patterns: [/database\.windows\.net.*(timed out|timeout|connection refused)/i, /:11\d{3}.*(timed out|refused)/i],
    fix: 'From inside Azure, Azure SQL redirects the login to ports 11000 to 11999. Allow outbound TCP on that range, or set the server\'s connection policy to Proxy.',
    runbook: `${AZ}#5-allow-the-network-paths`,
  },
  {
    id: 'snowflake-privileges',
    title: 'Snowflake refused an object for lack of privileges',
    patterns: [/Insufficient privileges to operate on/i, /does not exist or not authorized/i],
    fix: 'Grant the DataLoader role what the runbook lists (DL_READER for a source, DL_LOADER for a destination) and make it the user\'s default role.',
    runbook: `${SF}#3-create-the-roles-and-grant-least-privilege`,
  },
  {
    id: 'snowflake-warehouse',
    title: 'Snowflake has no usable warehouse',
    patterns: [/No active warehouse selected/i, /Warehouse '[^']+' (cannot be resumed|is suspended)/i, /resource monitor .* (exceeded|suspended)/i],
    fix: 'Set the warehouse in the connection, grant USAGE on it to the DataLoader role, and check its credit cap.',
    runbook: `${SF}#2-create-the-warehouse-with-a-credit-cap`,
  },
  {
    id: 'snowflake-key-pair',
    title: 'Snowflake rejected the key pair sign-in',
    patterns: [/JWT token is invalid/i, /390144/],
    fix: "The public key on the Snowflake user does not match the private key DataLoader holds, or the account identifier is wrong. Set RSA_PUBLIC_KEY again and check `DESC USER`.",
    runbook: `${SF}#1-pick-the-sign-in-and-make-the-key-pair-if-you-need-one`,
  },
  {
    id: 'apparmor-userns',
    title: 'The plugin sandbox cannot start (AppArmor user namespaces)',
    patterns: [/setting up uid map: Permission denied/i, /Can't mount proc/i],
    fix: 'Run `sudo bash <install dir>/install.sh --repair`, then `docker compose -f <install dir>/docker-compose.deploy.yml exec dataloader plugin-selftest`.',
    runbook: `${INSTALL}#ubuntu-2310-hosts-apparmor`,
  },
  {
    id: 'master-key-mismatch',
    title: 'Stored secrets cannot be decrypted',
    patterns: [/cannot decrypt `[^`]+`/i, /is the master key the one that wrote it/i],
    fix: 'The state volume lost or replaced `master.key`. Restore the volume backup, or re-enter the SSO and vault secrets.',
    runbook: `${INSTALL}#state-and-backups`,
  },
  {
    id: 'migration-failed',
    title: 'A database migration failed at boot',
    patterns: [/Migration error/i, /refinery.*(error|failed)/i, /abort_missing|missing migration/i],
    fix: 'Read the log lines around the error. A downgrade is not supported: restore the volume backup taken before the upgrade and start the old tag.',
    runbook: `${INSTALL}#re-run-verify-and-upgrade`,
  },
  {
    id: 'license-expired',
    title: 'The license or trial has expired',
    patterns: [/"category"\s*:\s*"license_expired"/, /"status"\s*:\s*"expired"/],
    in: /license|logs/,
    fix: 'Apply a current license in Admin, License (or set DL_LICENSE_KEY).',
    runbook: 'client-acceptance-test-plan.md#2-licensing',
  },
  {
    id: 'port-in-use',
    title: 'The host port is already in use',
    patterns: [/address already in use/i, /port is already allocated/i],
    fix: 'Stop what holds the port, or re-run `install.sh --port <free port>`.',
    runbook: `${INSTALL}#preflight-checks`,
  },
  {
    id: 'disk-full',
    title: 'The disk is full',
    patterns: [/No space left on device/i],
    fix: 'Free space on the Docker data root and the install dir (the preflight wants 20 GB). `docker system df` shows what Docker holds.',
    runbook: `${INSTALL}#preflight-checks`,
  },
  {
    id: 'image-pull',
    title: 'The image could not be pulled',
    patterns: [/manifest unknown/i, /pull access denied/i, /failed to resolve reference/i],
    fix: 'Check the tag exists and the host has outbound HTTPS to the registry (the install preflight tests it).',
    runbook: `${INSTALL}#preflight-checks`,
  },
  {
    id: 'health-degraded',
    title: 'Health reports a problem',
    patterns: [/"status"\s*:\s*"degraded"/, /"database"\s*:\s*false/],
    fix: 'The app is up but its database check fails. Read the logs for the database error; with an external Postgres, check `DL_DATABASE_URL` and the network path.',
    runbook: `${INSTALL}#troubleshooting`,
  },
];

// The items of a collected list answer ("GET path -> 200" then JSON), or
// undefined when the file is missing or not a list.
function listOf(sources, file) {
  const src = sources.find((s) => s.source === file);
  if (!src) return undefined;
  try {
    const j = JSON.parse(String(src.text).split('\n').slice(1).join('\n'));
    return Array.isArray(j) ? j : Array.isArray(j?.items) ? j.items : Array.isArray(j?.vaults) ? j.vaults : undefined;
  } catch {
    return undefined;
  }
}

// The vault probe prints the no-identity line on every host without one, so
// on its own it is noise. The finding stays when the line shows up anywhere
// else (a real sign-in failure), when a vault exists, when a destination is
// Azure, or when a destination's fields name the managed identity (for
// example Databricks signed in with it). A bundle without the vault list
// (pasted logs, no API access) cannot prove any of that is absent, so the
// finding stays.
const IDENTITY_LINE = /no managed identity on this host/i;
const IDENTITY_FIELD = /managed[_ -]?identity|\bmsi\b|imds/i;

function usesAzureIdentity(sources) {
  if (sources.some((s) => s.source !== 'http-vaults-managed-identity.txt' && IDENTITY_LINE.test(String(s.text)))) return true;
  const vaults = listOf(sources, 'http-vaults.txt');
  if (vaults === undefined || vaults.length > 0) return true;
  const destinations = listOf(sources, 'http-destinations.txt') || [];
  return destinations.some((d) => /azure|adls|abfs/i.test(String(d?.dest_type)) || IDENTITY_FIELD.test(JSON.stringify(d)));
}

// Match a bundle: an array of { source, text }. Returns one finding per
// signature with the first matching line from each source. A signature
// with `in` only reads the sources whose name it matches.
export function matchSignatures(sources, signatures = SIGNATURES) {
  const findings = [];
  for (const sig of signatures) {
    if (sig.when && !sig.when(sources)) continue;
    const hits = [];
    for (const { source, text } of sources) {
      if (!text || (sig.in && !sig.in.test(source))) continue;
      const lines = String(text).split(/\r?\n/);
      const line = lines.find((l) => sig.patterns.some((p) => p.test(l)));
      if (line !== undefined) hits.push({ source, line: line.length > 300 ? line.slice(0, 297) + '...' : line });
    }
    if (hits.length) findings.push({ id: sig.id, title: sig.title, fix: sig.fix, runbook: sig.runbook, hits });
  }
  return findings;
}

// Checks on structured answers that a text match would miss.
export function structuredFindings(bundle) {
  const out = [];
  const health = bundle.health;
  if (bundle.healthError) {
    out.push({ id: 'unreachable', title: 'DataLoader did not answer', fix: 'Check the container is running (`docker compose ps`) and that BASE_URL points at the bound address and port.', runbook: `${INSTALL}#troubleshooting`, hits: [{ source: 'GET /api/v1/health', line: bundle.healthError }] });
  } else if (health && health.dev_mode === true) {
    out.push({ id: 'dev-mode', title: 'The install runs in dev mode', fix: 'DL_DEV_MODE skips license and sign-in checks. Remove it from `.env` on a client install and restart.', runbook: `${INSTALL}#the-env-file`, hits: [{ source: 'GET /api/v1/health', line: 'dev_mode: true' }] });
  }
  const pub = bundle.publicUrl;
  if (pub && /^http:\/\//i.test(pub) && !/^http:\/\/(localhost|127\.0\.0\.1)(:|\/|$)/i.test(pub)) {
    out.push({ id: 'plain-http', title: 'Users reach DataLoader over plain HTTP', fix: 'Session cookies are Secure, so sign-in only holds over HTTPS or on localhost. Put a TLS reverse proxy in front.', runbook: `${INSTALL}#after-the-install`, hits: [{ source: 'PUBLIC_URL', line: pub }] });
  }
  return out;
}
