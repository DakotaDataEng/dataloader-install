---
name: dl-deploy
description: Install DataLoader from this repository using vars.env, or guide the client setup and upgrade steps. Use this when the user says install or asks to deploy DataLoader.
argument-hint: "[linux | azure | snowflake | upgrade]"
---

# dl-deploy: install DataLoader at a client

You guide a system integrator (SI) through a DataLoader install. The steps are not in this skill. They are in the DataLoader runbooks, which you read now, at run time, so the install always follows the current runbook. Never work from memory of a runbook.

## Install from this repository

When the SI says install in this repository, read vars.env and use its values without repeating secrets in chat.

If TAGS includes azure, follow step 0 of docs/runbooks/client-azure-identity-vault-sso-databricks.md and run scripts/azure/provision.sh to create the shared fan-out job. Start with --dry-run and ask for any missing subscription, resource group, region or VM values. Skip Azure provisioning when TAGS does not include azure.

Run ./install.sh; it reads vars.env and installs the pinned release. Then continue with the setup checks below.

## 1. Find the runbooks

Run `node "scripts/si/find-runbooks.mjs"`. It prints the `docs/runbooks` directory and the file for each runbook. If it finds none, stop and tell the SI to clone the DataLoader repository at the release tag they install, then run Claude Code inside the checkout or set `DL_RUNBOOKS_DIR`. Use the runbooks from the same tag as the image: a runbook from another release can name flags the image does not have.

Read, in full:

- `README.md` (the index): which runbooks apply to this client, what the client's admins do before the SI arrives, and the handoff checklist.
- `install-linux-host.md`: the preflight, the install, `.env`, state and backups, upgrades.
- `client-azure-identity-vault-sso-databricks.md` when the client uses Azure, Entra sign-in, Key Vault or Databricks.
- `client-snowflake.md` when the client uses Snowflake.

## 2. Make a run directory

Use `$DL_SI_RUNS_DIR` if set, otherwise `~/dataloader-si-runs`, and create `deploy-<YYYY-MM-DD-HHMM>/` inside it. Never use the repository root or the current directory when it is a repository. Keep a `steps.md` there: one line per step with the time, the step, the check you ran and its result. Do not write secrets into it.

## 3. Ask what you need

Ask the SI, in one message, only for what the runbooks need and you do not have yet:

- The host: how to reach it (you run commands there yourself through `ssh`, or the SI pastes output back), its OS, and whether it is an Azure VM.
- The release tag to install, and the first admin's email.
- Which sources and destinations the client uses, and whether sign-in is Entra SSO.
- For Azure: whether the client's admins have done the client runbook's steps yet, and which.

Never ask for a password, a client secret, a key or a token in chat. The installer generates the admin password and stores it in `.env`; secrets for sources go in Key Vault or are typed into DataLoader by the SI.

## 4. Walk the steps in order

Work through the runbooks' steps in their order. For each step:

1. Say what the step does, who runs it (the SI, or the client's Azure, Entra, Databricks or Snowflake admin, with the role the runbook names), and show the command from the runbook with the client's values filled in.
2. Run it, or wait for the SI or admin to run it.
3. Run the step's check from the runbook and read the result. A step is done only when its check passes. If a check fails, stop, use the runbook's troubleshooting notes (or the `dl-diagnose` skill), and do not go on until it passes or the SI decides to skip it. Record a skipped step as skipped, with the reason.
4. Write the line to `steps.md`.

Start with the preflight dry run (`install.sh --dry-run`), naming the client's Key Vaults with `--key-vault` and every source and destination host with `--check-endpoint`, so the network paths are tested before anything changes.

These steps are where installs have gone wrong before. Do not skip them, and run their checks:

- **On an Azure VM, install with `--managed-identity`.** Without it DataLoader has no identity and every vault and Databricks sign-in fails. Check: Admin, Key vaults, Register vault shows the identity's object ID, not "no managed identity on this host". A host installed without it is fixed as the Azure runbook's step 2 says.
- **Key Vault roles.** Secrets User on single secrets lets DataLoader read them but not list them; the vault's Test then says it cannot list. Ask whether the client wants listing (role on the vault) or typed `kv://vault/secret` references.
- **The SSO app's client ID is the app's GUID**, copied from the app registration. A browser can autofill an email address into the field, and every sign-in then fails with AADSTS700016.
- **Microsoft Graph `User.Read.All` as an application permission with admin consent.** Admin consent can report success without granting the role. Check it with the `appRoleAssignments` GET the runbook gives, and grant it with the runbook's POST when it is missing. Then check Admin, Sign-in: the session check reads as passing within 15 minutes. Consent needs a tenant admin with the role the runbook names.
- **Databricks grants** for the identity's service principal, exactly as the runbook lists them. Check: the destination's Test says the staging volume is writable.
- **Azure SQL from inside Azure** redirects to ports 11000 to 11999: outbound TCP on that range, or the server's connection policy set to Proxy.
- **Snowflake**: the warehouse with its credit cap, the least-privilege roles, the service user, and the external stage, each with the runbook's check.

## 5. Hand off

When the install's health check passes and the SI has signed in:

1. Tell the SI where the bootstrap admin password is (the runbook's `grep` on `.env`). Do not print it yourself.
2. Remind them of the runbook's after-install steps: finish the setup wizard, delete the `DL_BOOTSTRAP_ADMIN_*` lines, put TLS in front, back up the state volume.
3. Suggest `dl-configure` for the first connection, destination and table, then `dl-verify` for the acceptance plan.
4. Show the path to `steps.md`.

## Arguments

`$ARGUMENTS` may name a part: `linux` (host install only), `azure` (the Azure client runbook), `snowflake`, or `upgrade` (the runbook's upgrade section, backup first). With none, ask which apply.
