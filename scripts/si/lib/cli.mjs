// Shared command-line behavior for the dl-* scripts.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// The script's own header comment (the leading // lines after the shebang),
// without the comment markers.
export function headerHelp(scriptUrl) {
  const lines = readFileSync(fileURLToPath(scriptUrl), 'utf8').split(/\r?\n/);
  const out = [];
  for (const line of lines.slice(lines[0]?.startsWith('#!') ? 1 : 0)) {
    if (!line.startsWith('//')) break;
    out.push(line.replace(/^\/\/ ?/, ''));
  }
  return out.join('\n');
}

// Prints the header and returns true when the arguments ask for help, so the
// caller can stop before it parses options it would reject.
export function helpRequested(scriptUrl, args = process.argv.slice(2)) {
  if (!args.some((a) => a === '--help' || a === '-h')) return false;
  process.stdout.write(`${headerHelp(scriptUrl)}\n`);
  return true;
}

// A reader that closes the pipe early (`| head`) is not an error: stop
// quietly instead of printing a stack trace.
export function exitQuietlyOnEpipe() {
  for (const stream of [process.stdout, process.stderr]) {
    stream.on('error', (e) => {
      if (e.code === 'EPIPE') process.exit(0);
      throw e;
    });
  }
}
