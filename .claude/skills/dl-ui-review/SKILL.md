---
name: dl-ui-review
description: Walk a DataLoader install's UI in a browser with the Playwright MCP tools and judge each screen for "does this make sense" and "does this work", with a screenshot per screen in a run directory. Use when the user asks to review, walk or check the UI of a DataLoader install, or to judge the acceptance plan's visual cases.
argument-hint: "[base URL] [verify run directory]"
---

# dl-ui-review: judge every screen

You walk the install as the client's users will, and for each screen answer two questions:

- **Does this make sense?** A new admin or analyst can tell what the page is for, what its numbers and labels mean, and what to do next. Copy is plain, with no internal notes, ticket numbers, raw error codes or developer words. Empty, loading and error states say what happened and offer a way on.
- **Does this work?** The page loads without console errors or failed requests (other than the ones you cause on purpose), buttons do what they say, forms validate inline, saved values read back, and links go where they claim.

This builds on the persona walk the DataLoader team uses internally, cut down for a client install: no ticket filing, findings go to the SI.

## 1. Before the walk

- The Playwright MCP tools (`browser_navigate`, `browser_snapshot`, `browser_take_screenshot`, `browser_console_messages`, `browser_network_requests`, `browser_click`, `browser_type`) must be available. If they are not, tell the SI to add the Playwright MCP server to Claude Code and restart, and stop.
- Run directory: `$DL_SI_RUNS_DIR` (or `~/dataloader-si-runs`), with `ui-review-<YYYY-MM-DD-HHMM>/` inside it. Never the repository root. Screenshots go in its `shots/` folder as `NN-<screen>.png` (`01-login.png`, `02-overview.png`). Pass the full path to `browser_take_screenshot`; if the tool saves elsewhere, move the file into `shots/`.
- The URL users open (`$ARGUMENTS`, or ask). Sign-in: the SI types their own password or completes Entra sign-in in the browser window. Never take a password in chat and never type one you were given.
- If a `dl-verify` run directory is given, read its `report.md`: walk its visual cases and pending browser checks too, and record each result there with `dl-verify.mjs record` (see the dl-verify skill).

Read the acceptance plan's "UI walk" section and its visual cases (`find-runbooks.mjs` prints where the plan is). Their `look_for` lists are the client-facing bar for each screen.

## 2. The walk

Cover the sign-in page, then every item in the sidebar, then the Admin pages. The sidebar reads Overview, Tables, Assets, Jobs, Automation, Runs, Connections and Admin; take the names from the page, since they change between releases. At least: Login, Overview, Tables (list, one table's page, its Edit page, Bulk edit), Runs (list, one run, its log), Connections (the Sources and Destinations tabs, one connection, the new connection form), Jobs, Automation (Schedule, Sensors, Tick log), Assets, the notification bell, and each Admin page the sidebar lists. Open one object of each kind that has data. Find a page's address from the sidebar links in `browser_snapshot` (for example Automation is `/automation/schedule`), not by guessing.

For each screen:

1. Navigate, wait for it to settle, take the screenshot.
2. Read the console messages and the failed network requests.
3. Try the one or two actions a user would try first (open, filter, save with no change, cancel). Do not run loads, delete anything, or change settings unless the SI says to; on a client install those are real.
4. Write the verdict.

Switch to dark mode (the moon button, "Toggle theme", in the top bar) and to the PROD environment (the TEST and PROD pill, which asks you to confirm) once each and look at two or three screens again. A signed-out first load logs one 401 from `/api/v1/auth/me`; that is expected and is not a finding.

## 3. Write the findings

Write `review.md` in the run directory: one section per screen with the screenshot path, **Makes sense:** yes or no and why, **Works:** yes or no and why, and console or network evidence. Then a list of findings, worst first, each with:

- the screen and the screenshot,
- what a user would see and expect,
- severity 1 to 5 (5 blocks the client's work),
- whether it repeats on other screens.

No bikeshedding: if a screen is fine, say so in one line. Do not propose redesigns; describe what goes wrong for the user. Summarize for the SI at the end: how many screens, how many findings at severity 3 or more, and which visual cases you recorded.
