---
name: dl-diagnose
description: Diagnose a DataLoader install that misbehaves. Collect health, version, logs and config with secrets redacted, match known failure signatures (Docker down, no managed identity, AADSTS700016, a failing session check, vault roles, Databricks grants, Azure SQL ports, Snowflake privileges and more), and suggest the fix with its runbook section. Use when a DataLoader install, sign-in, vault, connection, destination or load fails.
argument-hint: "[what is failing]"
---

# dl-diagnose: find out why an install fails

## 1. Run directory and access

Use `$DL_SI_RUNS_DIR` (or `~/dataloader-si-runs`) and create `diagnose-<YYYY-MM-DD-HHMM>/` in it, never the repository root. Ask the SI:

- What fails, in their words, and since when (`$ARGUMENTS` may say).
- The base URL (`http://127.0.0.1:8080` on the host) and the public URL users open.
- How to reach the host: run here on the host, or a `--host-shell` such as `ssh si@dl-host.client.example`. Without either, ask the SI to paste the output of the commands in step 2 into files in the run directory and use `match` on them.
- The install directory if it is not `/opt/dataloader`.

An admin bearer gives a fuller picture (sign-in settings, vaults, connections, the session check). The SI sets `DL_API_TOKEN`, or `DL_OAUTH_CLIENT_ID` and `DL_OAUTH_CLIENT_SECRET`, in their shell. Never take one in chat. Without one, only the routes that need no sign-in are read.

## 2. Collect and match

```bash
node "scripts/si/dl-diagnose.mjs" collect --out <run dir> --base-url <url> --public-url <public url> [--host-shell "<ssh ...>"] [--install-dir <dir>]
```

It reads health, readiness, setup status, the deployment target and the SSO status; with a bearer also the signed-in user, sign-in settings (with the session check's last result), the license, vaults and the managed identity, connections, destinations and the needs-attention lists. On the host it runs `docker version`, `docker compose ps`, the last 2000 log lines, and disk and OS facts, and lists the keys set in `.env`. Add `--probe` to also run the Test of every vault, connection and destination (reads only); ask the SI first, as each Test signs in to the client's systems.

**The bundle contains no secret values.** A bundle may be sent to Dakota for support, so configuration is copied by allowlist, not by redaction:

- `.env` is never copied. The bundle lists the names of the keys that are set, and a value only for a short list of known non-secret keys (the image tag, port, bind address, project name, auto-update, AppArmor profile, managed identity mode, dev mode), and only when the value has the expected shape. The command that reads the file on the host prints nothing else, so the other values never leave the host.
- From the API answers it keeps only listed fields: the sign-in settings without secrets, the license status and plan, each vault's name, URI and last probe, each connection's and destination's key, type and health, with the names of their config fields but no config values. Every other field is named as not collected.
- What it does contain: health and version, the open status routes, those allowed fields, the Test answers' status and message, `docker` output, the log lines, and host facts. Logs are redacted by pattern (tokens, passwords, cookies, keys), which can miss things, so read them before they leave the SI's machine.

Then it matches the bundle against the known signatures and writes `findings.md` and `findings.json`.

For logs or output the SI pasted:

```bash
node "scripts/si/dl-diagnose.mjs" match <file> [<file> ...]
```

## 3. Explain and fix

For each finding:

1. Read the runbook section it names (find the runbooks with `node "scripts/si/find-runbooks.mjs"`) and give the SI the fix from the runbook, with the client's values, not only the summary line.
2. Say who runs the fix (the SI, or the client's Azure, Entra, Databricks or Snowflake admin).
3. Give the check that proves it is fixed, from the same runbook step, and run it (or ask for its output) once the fix is in.

These are the signatures the script knows, among others: Docker not running; "no managed identity on this host" (install with `--managed-identity`); AADSTS700016 (the client ID is not the app's GUID); the Entra session check failing because the app lacks Graph `User.Read.All` (check `appRoleAssignments`); a vault that cannot list (role on single secrets) or lists but cannot read a secret; a vault token from another tenant; the vault firewall; a missing Databricks grant or an unwritable staging volume; Azure SQL redirect ports 11000 to 11999; Snowflake privileges, warehouse and key pair errors; the AppArmor user namespace error in the plugin sandbox; a master key that no longer decrypts stored secrets; a failed migration; an expired license; a port in use; a full disk; an image pull failure; dev mode on a client install; users on plain HTTP.

When nothing matches, read the logs around the time of the failure yourself, and the plan's matching case in the client acceptance plan. Say plainly what you found and what you could not tell.

## 4. Share

The bundle holds no secret values, but read it before it leaves the SI's machine: the log lines are filtered by pattern only, and a client name, a host name or an email address in a log line may be fine for the client and not for a ticket. Suggest the SI attach `findings.md` and the files that show the failure, not the whole directory.
