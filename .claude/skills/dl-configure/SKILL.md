---
name: dl-configure
description: Configure a fresh DataLoader install from the SI's answers, a source connection, a destination and a first table load, each tested before it is saved. Use when the user asks to configure, set up connections or destinations, or add a first table on a DataLoader install.
argument-hint: "[base URL]"
---

# dl-configure: a first connection, destination and table

You configure a DataLoader install from the SI's answers. Every object is tested before it is saved, and every save is read back.

## How it works

DataLoader reads one setup file that describes the connections, destinations and tables, and `dl setup` applies it through the same routes the wizard and Admin pages use. This skill writes that file from the SI's answers, shows the plan, and applies it on the SI's yes. Where `dl` is missing, step 4 makes the same changes as API calls, one at a time.

- Collect the SI's answers into `answers.json` in the run directory (no secrets in it, see below).
- Step 4 turns `answers.json` into the setup file, or into API calls when `dl` is missing.

## 1. Prerequisites

- A run directory: `$DL_SI_RUNS_DIR` if set, otherwise `~/dataloader-si-runs`, with `configure-<YYYY-MM-DD-HHMM>/` inside it. Never the repository root.
- The install's base URL (`$ARGUMENTS`, or ask; `http://127.0.0.1:8080` on the host).
- A bearer the scripts can use. Ask the SI to set one in the shell that runs Claude Code, never to paste it in chat:
  - an OAuth client with the `admin` and `runs:trigger` scopes and the `admin` role (Admin, OAuth clients; the role defaults to viewer, which cannot read vaults or users): `DL_OAUTH_CLIENT_ID` and `DL_OAUTH_CLIENT_SECRET`; or
  - an existing admin API token in `DL_API_TOKEN`.

Check it: `node "scripts/si/dl-api.mjs" GET /api/v1/auth/me --base-url <url>` answers 200 with an admin role.

## 2. Read what the install offers

```bash
node "scripts/si/dl-api.mjs" GET "/api/v1/connectors/types?role=source" --base-url <url>
node "scripts/si/dl-api.mjs" GET "/api/v1/connectors/types?role=destination" --base-url <url>
node "scripts/si/dl-api.mjs" GET /api/v1/vaults --base-url <url>
```

The type lists give each type's `config_json` fields, which are required, and which are secret. Ask only for those fields. Do not guess field names.

## 3. Ask the SI

In one message, ask for:

- The source: type, host, port, database, user, and the schema and table of a small test table (under 1,000 rows).
- The destination: type and its fields, and the schema (and catalog) to load into.
- How the first table loads: full, or incremental with a timestamp column and the primary key.

For every secret field (passwords, keys), do not take the value in chat. Ask instead for one of:

1. a Key Vault reference `kv://<vault>/<secret>` to a vault registered in DataLoader (best: DataLoader resolves it and the value never leaves the vault); or
2. the name of an environment variable the SI sets in their shell (for example `PG_PASSWORD`), written `env:PG_PASSWORD` in the setup file. `dl` reads it from the environment of the computer running it, so inside the container it must be set in the container's environment.

Write the answers to `answers.json` with the references, not the values.

## 4. Write the setup file, plan, apply

Check for `dl` first: `dl --version`. The image carries it at `/app/bin/dl` on the container's PATH; to run it on the host, take it out of the image so it matches the running version (the install runbook, "Set up from a file", "Where `dl` is"). If `dl` is missing and cannot be had, use the fallback below.

1. **Write `setup.yml`** in the run directory from `answers.json`, starting from `"setup.example.yml"`: a `connections` entry for the source, a `destinations` entry for the destination and a `tables` entry for the first table (`load_strategy`, and `incremental_column`, `incremental_type` and `merge_keys` for an incremental load). Take the `config` field names from the type lists in step 2. Every secret is a `kv://vault/secret` reference or an `env:NAME` reference, never a value; a literal value under a password, token, secret or connection string key is refused. Use short lower-case keys such as `src_sales_pg` and `dest_lake`.
2. **Plan**: `dl setup plan setup.yml --url <url>`, signed in as the install runbook describes in "Point `dl` at the instance and sign in": on a new instance `--email` with the bootstrap admin's email and its password in `DL_SETUP_PASSWORD`; later, `DL_TOKEN` or `DL_CLIENT_ID` and `DL_CLIENT_SECRET` for an admin with the admin scope. `plan` changes nothing.
3. **Show the plan** to the SI as it printed, and ask whether to apply it. Do not apply without a yes.
4. **Apply**: on the yes, `dl setup apply setup.yml --url <url>` with the same sign-in. A second apply of the same file prints `no changes`. Exit 2 means something exists and differs from the file: show each difference and ask before adding `--force`, which makes the file win.
5. **Check it**: `dl-api.mjs GET /api/v1/connections`, `/api/v1/destinations` and `/api/v1/table-configs` list the three objects; test each saved connection and destination with `POST /api/v1/connections/<id>/test` and `POST /api/v1/destinations/<id>/test`. For Databricks the Test says the staging volume is writable; if not, the identity is missing a grant (the Azure client runbook, Databricks step).
6. **Run it once**: `POST /api/v1/table-configs/<id>/run` with `{"env":"test"}`, note the `run_id`, and poll `GET /api/v1/runs/<run_id>` every 5 seconds until `run.status` is `succeeded` or a failure. Report `run.rows_written`.

Stop at the first failure, show the answer, and suggest `dl-diagnose` if the cause is not plain.

### Fallback: no `dl`

Write each request body to a file in the run directory, then send it with `dl-api.mjs ... --body-file <file>`.

1. **Test the source**: `POST /api/v1/connections/test` with `{connection_key, display_name, db_type, config_json}`. Go on only when `is_healthy` is true.
2. **Save it**: `POST /api/v1/connections` with the same body. Note the `id`. Then `POST /api/v1/connections/<id>/test`.
3. **Check the table is visible**: `GET /api/v1/connections/<id>/introspect/tables?schema=<schema>` lists it.
4. **Test the destination**: `POST /api/v1/destinations/test` with `{destination_key, display_name, dest_type, config_json}`, then save with `POST /api/v1/destinations` and test the saved one with `POST /api/v1/destinations/<id>/test`.
5. **Create the table config** in TEST: `POST /api/v1/table-configs` with `connection_id`, `destination_id`, `environment: "test"`, `source_schema`, `source_table`, `dest_schema` (and `dest_catalog` where the destination has catalogs), `dest_table`, `load_strategy` (`full`, `incremental` with `incremental_column`, `incremental_type` and `primary_key_columns`, or `append_only`) and `compute_mode: "local"`.
6. **Run it once** as in step 6 above.

A 409 on save means the key exists: read it back with `GET /api/v1/connections` and ask before changing it. With the `env:NAME` option for a secret, the body file holds `"${NAME}"` and `dl-api.mjs` fills it in from the environment.

## 5. Finish

- Delete any body file that held a filled-in secret. `setup.yml` holds references only and can stay; body files with `${NAME}` or `kv://` references can stay.
- Write `configure.md` in the run directory: what was created (keys and IDs, no secrets), the test results, and the first run's row count.
- Suggest `dl-verify` next.
