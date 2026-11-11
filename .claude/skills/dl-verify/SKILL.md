---
name: dl-verify
description: Run the DataLoader client acceptance plan against an install, execute its automatable cases, and write a report with pass, fail and not run per case and the evidence, for the SI to hand to the client. Use when the user asks to verify, accept, test or sign off a DataLoader install.
argument-hint: "[run directory to continue]"
---

# dl-verify: run the client acceptance plan

The plan is `docs/runbooks/client-acceptance-test-plan.md` in the DataLoader repository. Each case carries a one-line `<!-- cat: {...} -->` marker that says how to check it; its "Conventions for dl-verify" section defines the markers. `dl-verify.mjs` reads those markers at run time, so a case added to the plan is run without a plugin change.

## 1. Find the plan and check it parses

```bash
node "scripts/si/find-runbooks.mjs"
node "scripts/si/dl-verify.mjs" list
```

`list` prints the case count, the check kinds, the tags and the destructive cases. Use the plan from the same release tag as the install. Stop if `list` reports marker errors.

## 2. The run directory

Continue the run directory in `$ARGUMENTS` if one is given. Otherwise use `$DL_SI_RUNS_DIR` (or `~/dataloader-si-runs`) and create `verify-<YYYY-MM-DD-HHMM>/` in it. The script refuses a repository root. Everything the run writes goes there: `report.md` (for the client), `results.json`, `saved.json` (IDs the cases saved, no secrets), `ui-pending.json`, and the screenshots you take.

## 3. The vars file and the bearer

The plan's "Variables" tables list every input. Help the SI write a vars file **outside the repository and outside the run directory**, for example `~/dataloader-si-vars/<client>.env` (KEY=VALUE lines) or a JSON object. It holds credentials, so it is never copied into the report, a ticket or chat. Ask the SI to fill in the secret values themselves; offer to write the file with every key and placeholder values, and the non-secret values you know.

Always set `BASE_URL`, `PUBLIC_URL`, `IMAGE_TAG`, `EXPECTED_VERSION`, `COMPOSE` and `INSTALL_DIR`. Set `TAGS` (or pass `--tags`) to what the install has: `src:postgres`, `dest:databricks`, `sso`, `license`, `azure`, `https`, `notify`, `dbt`, `upgrade`, `hostunit`, `lockout` and the rest the plan lists. A case whose tag is off, or whose variables are unset, is recorded as N/A with the reason.

The `cli` checks run on the DataLoader host. Run the script on the host, or set `HOST_SHELL` in the vars file (for example `ssh si@dl-host.client.example`) so each command runs there. The `sql` checks use `psql` for a `postgres://` target; for any other target set `<TARGET>_CMD` to a command that reads the SQL on stdin and prints the first value (for example `DEST_SNOWFLAKE_DSN_CMD=snowsql -c acceptance -o output_format=plain -o header=false -o friendly=false`).

The bearer, set by the SI in their shell, never typed into chat:

- an admin login in the vars file (`ADMIN_EMAIL`, `ADMIN_PASSWORD`): CAT-AUTH-03 signs in and later cases use that session; and, or instead,
- `DL_API_TOKEN`, or an OAuth client with the `admin` and `runs:trigger` scopes and the `admin` role in `DL_OAUTH_CLIENT_ID` and `DL_OAUTH_CLIENT_SECRET`, used wherever the plan expects the admin session until CAT-AUTH-03 has signed in.

## 4. Run

```bash
node "scripts/si/dl-verify.mjs" run --vars <vars file> --out <run dir>
```

It prints one line per case. Destructive cases (they restart the service, change the image, delete something or restore data) are not run unless named. Before you name one, read its **Warning** line in the plan to the SI, and run it only when they say yes, with the client's IT contact aware:

```bash
node "scripts/si/dl-verify.mjs" run --vars <vars file> --out <run dir> --only CAT-HEALTH-14 --allow CAT-HEALTH-14
```

`--only` takes IDs and `*` patterns (`CAT-AUTH-*`). A rerun into the same directory keeps the earlier results and saved IDs and replaces only the cases it ran. Sessions are not kept between runs, so add `CAT-AUTH-03` to `--only`, or set a bearer. Cases that use the editor and viewer sessions need a full run. Long cases (loads, sensors, fan-out) poll for minutes; let them finish.

## 5. Browser and visual cases

`ui-pending.json` lists the `ui` checks; the report lists them and the visual cases under "Left for a person or dl-ui-review". For the `ui` checks, use the Playwright MCP tools if they are available: open each URL (sign in first when `login` is true), check the selector, the text and the console as listed, save a screenshot into `<run dir>/shots/`, and record the result:

```bash
node "scripts/si/dl-verify.mjs" record --out <run dir> --id CAT-UI-01 --result pass --note "Overview loads, no console errors" --screenshot shots/01-overview.png
```

Visual cases are judged by a person (or by `dl-ui-review` with the SI watching). Record each the same way. Record `--result not_run --note <reason>` for a case that does not apply.

## 6. Hand over the report

Read `report.md` and summarize for the SI: the counts, each failure with its note, the known-issue failures (reported apart from regressions), and what is still not run and why. For each failure, suggest `dl-diagnose` or the plan section. The report has a sign-off table at the end; the SI and the client's IT contact sign it.

Never paste the vars file, a token, a cookie or a password into the report, a note or chat. The script redacts what it knows to be secret, but a `--note` you write is yours to keep clean.
