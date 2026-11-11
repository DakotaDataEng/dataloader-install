// Writes the dl-verify report an SI hands to the client.

const REASONS = {
  na: 'N/A for this install',
  visual: 'Visual, walk on screen',
  needs_ui: 'Browser check not recorded yet',
  destructive: 'Destructive, not approved for this run',
  dependency: 'Blocked by a failed case',
};

export function summarize(results) {
  const counts = { total: results.length, pass: 0, fail: 0, expected_fail: 0, not_run: 0, by_reason: {} };
  for (const r of results) {
    counts[r.result] = (counts[r.result] || 0) + 1;
    if (r.result === 'not_run') counts.by_reason[r.reason] = (counts.by_reason[r.reason] || 0) + 1;
  }
  return counts;
}

function cell(s) {
  return String(s ?? '').replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
}

function resultText(r) {
  if (r.result === 'pass') return 'Pass';
  if (r.result === 'fail') return 'Fail';
  if (r.result === 'expected_fail') return `Fail (known issue ${r.known_issue})`;
  return `Not run: ${REASONS[r.reason] || r.reason}`;
}

export function renderReport(results, meta) {
  const c = summarize(results);
  const lines = [];
  lines.push('# DataLoader acceptance report', '');
  lines.push('| | |', '|---|---|');
  lines.push(`| Install | ${cell(meta.base_url)} |`);
  if (meta.public_url) lines.push(`| Public URL | ${cell(meta.public_url)} |`);
  if (meta.version) lines.push(`| Version reported | ${cell(meta.version)} |`);
  if (meta.image_tag) lines.push(`| Image tag under test | ${cell(meta.image_tag)} |`);
  lines.push(`| Plan | ${cell(meta.plan_file)} (sha256 ${cell((meta.plan_sha256 || '').slice(0, 12))}, ${meta.plan_cases} cases) |`);
  lines.push(`| Tags enabled | ${cell((meta.tags || []).join(', ') || 'none')} |`);
  lines.push(`| Last run | ${cell(meta.finished_at)} |`);
  lines.push(`| Produced by | dl-verify ${cell(meta.tool_version)} |`);
  lines.push('');
  lines.push('## Summary', '');
  lines.push('| Result | Cases |', '|---|---|');
  lines.push(`| Pass | ${c.pass} |`);
  lines.push(`| Fail | ${c.fail} |`);
  if (c.expected_fail) lines.push(`| Fail on a known issue | ${c.expected_fail} |`);
  for (const [reason, n] of Object.entries(c.by_reason)) lines.push(`| Not run: ${REASONS[reason] || reason} | ${n} |`);
  lines.push(`| Total | ${c.total} |`, '');

  const failed = results.filter((r) => r.result === 'fail');
  if (failed.length) {
    lines.push('## Failures', '');
    for (const r of failed) lines.push(`- **${r.id}** ${r.title}: ${r.note}`);
    lines.push('');
  }

  lines.push('## Cases', '');
  lines.push('| Case | Title | Result | Note |', '|---|---|---|---|');
  for (const r of results) lines.push(`| ${r.id} | ${cell(r.title)} | ${resultText(r)} | ${cell(r.note)} |`);
  lines.push('');

  const visual = results.filter((r) => r.reason === 'visual' || r.reason === 'needs_ui');
  if (visual.length) {
    lines.push('## Left for a person or dl-ui-review', '');
    lines.push('Walk each on screen and record the result with `dl-verify record`.', '');
    for (const r of visual) {
      lines.push(`### ${r.id} ${r.title}`, '');
      for (const l of r.look_for || []) lines.push(`- [ ] ${l}`);
      for (const u of r.pending_ui || []) {
        const want = [u.expect_selector && `selector \`${u.expect_selector}\` visible`, u.expect_text && `text "${u.expect_text}"`, u.expect_no_console_errors && 'no console errors'].filter(Boolean).join(', ');
        lines.push(`- [ ] ${u.url}${u.login ? ' (signed in as admin)' : ''}: ${want}`);
      }
      lines.push('');
    }
  }

  lines.push('## Evidence', '');
  for (const r of results) {
    if (!r.evidence || r.evidence.length === 0) continue;
    lines.push(`### ${r.id} ${resultText(r)}`, '');
    for (const e of r.evidence) {
      lines.push(`${e.check}. ${e.ok ? 'ok' : 'not ok'}: ${e.summary}`);
      if (e.detail) lines.push('', '```', e.detail, '```');
      if (e.screenshot) lines.push('', `Screenshot: ${e.screenshot}`);
    }
    lines.push('');
  }

  lines.push('## Sign-off', '');
  lines.push('| Role | Name | Date | Signature |', '|---|---|---|---|');
  lines.push('| SI | | | |', '| Client IT | | | |', '');
  return lines.join('\n');
}
