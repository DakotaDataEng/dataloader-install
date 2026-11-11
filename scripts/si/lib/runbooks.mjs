// Finds the DataLoader runbooks the skills follow. They live in the
// DataLoader repository under docs/runbooks/; the skills read them at run
// time so a runbook change reaches every SI without a plugin release.

import { existsSync, statSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const RUNBOOK_FILES = {
  index: 'README.md',
  install: 'install-linux-host.md',
  azure: 'client-azure-identity-vault-sso-databricks.md',
  snowflake: 'client-snowflake.md',
  plan: 'client-acceptance-test-plan.md',
};

function isRunbookDir(dir) {
  return existsSync(join(dir, RUNBOOK_FILES.install)) && existsSync(join(dir, RUNBOOK_FILES.plan));
}

function walkUp(start) {
  let dir = resolve(start);
  for (;;) {
    const candidate = join(dir, 'docs', 'runbooks');
    if (isRunbookDir(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

// Order: an explicit directory, DL_RUNBOOKS_DIR, the checkout this plugin
// sits in, then the current directory and its parents.
export function findRunbooks(explicit, env = process.env, cwd = process.cwd()) {
  for (const d of [explicit, env.DL_RUNBOOKS_DIR]) {
    if (!d) continue;
    const dir = resolve(d);
    if (isRunbookDir(dir)) return dir;
    if (isRunbookDir(join(dir, 'docs', 'runbooks'))) return join(dir, 'docs', 'runbooks');
  }
  const here = dirname(fileURLToPath(import.meta.url));
  return walkUp(here) || walkUp(cwd);
}

export function isDir(p) {
  try {
    return statSync(p).isDirectory();
  } catch {
    return false;
  }
}
