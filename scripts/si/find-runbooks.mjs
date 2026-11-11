#!/usr/bin/env node
// Prints the docs/runbooks directory the skills read, or explains how to
// point at one.
//
//   node find-runbooks.mjs [DIR]

import { join } from 'node:path';
import { findRunbooks, RUNBOOK_FILES } from './lib/runbooks.mjs';

const dir = findRunbooks(process.argv[2]);
if (!dir) {
  process.stderr.write(
    'No DataLoader runbooks found. Clone the DataLoader repository at the release tag you install, then either\n' +
      'run Claude Code inside the checkout or set DL_RUNBOOKS_DIR to its docs/runbooks directory.\n',
  );
  process.exit(1);
}
process.stdout.write(dir + '\n');
for (const [key, file] of Object.entries(RUNBOOK_FILES)) process.stdout.write(`${key}: ${join(dir, file)}\n`);
