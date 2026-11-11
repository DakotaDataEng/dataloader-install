# DataLoader client acceptance test plan

Start with the public SI install repository at [DakotaDataEng/dataloader-install](https://github.com/DakotaDataEng/dataloader-install).

## Purpose

This plan shows that a DataLoader install works in the client's environment. It gives the client a record to sign off against.

Each case has an ID, steps, an expected result, and a mode:

- **automatable**: a script can run the check and compare the result. The case names the API call or command.
- **visual**: a person looks at the screen and judges the result.

## Who runs it

A system integrator (SI) runs the plan on the client's install. A client IT contact is present for the sign-off.

The SI needs an admin login to DataLoader and a shell on the host. Claude Code can run the automatable cases through `dl-verify`. A person walks the visual cases.

## Before you start

Gather these items. If you do not have something a case needs, record that case as **N/A** and give the reason. Do not record it as a failure.

| Item | Needed for | Notes |
|---|---|---|
| Linux host, Ubuntu 22.04 LTS or later (x86_64), with Docker Engine 24 or later and the `docker compose` v2 plugin | Every section | 2 vCPU, 8 GB RAM and 40 GB disk are enough. The host needs outbound HTTPS to the image registry and to each source and destination. |
| The image tag to accept, such as `1.0.0` | Install, upgrade | Pin a version tag. Do not use `stable` or `latest`. Upgrade cases need a second, newer tag. |
| A DNS name and TLS certificate for the host, and a reverse proxy (Caddy, nginx or Traefik) | HTTPS, sign-in | DataLoader serves plain HTTP on `127.0.0.1:8080`. Sign-in cookies are secure, so sign-in works only over HTTPS or on `localhost`. |
| Bootstrap admin email and password (12 characters or more) | Sign-in | Set as `DL_BOOTSTRAP_ADMIN_EMAIL` and `DL_BOOTSTRAP_ADMIN_PASSWORD`. Used on the first boot only. |
| The license from Dakota, as a key or a file | Licensing | Without it the install runs a 30-day trial. Finish acceptance with a real license. A headless install can set `DL_LICENSE_KEY` instead of a file. |
| Microsoft Entra app registration: tenant ID, client ID, client secret, and redirect URI `https://<host>/api/v1/auth/oidc/callback` | Single sign-on | Also one Entra test user in an allowed email domain, and one outside it if you can. |
| Credentials for each source the client uses (Postgres, SQL Server, Oracle, Snowflake, ClickHouse, Iceberg), and a small test table in each | Connections, loads | A read-only account is enough. The release image already includes what SQL Server and Oracle need. See CAT-CONN-03 and CAT-CONN-04. |
| Credentials for each destination the client uses (Postgres, Databricks, Snowflake, Iceberg), with rights to create tables in one test schema | Destinations, loads | You also need a SQL client that can query each destination for row counts. |
| A mailbox or webhook receiver (Teams, Slack, or a generic HTTPS endpoint) | Notifications | |
| Azure resources, only if the install uses them: Key Vault, a managed identity for DataLoader when its host supports one, a service principal and secret only when the host is outside Azure or keeps an existing choice, a container registry, a Container Apps environment and Job | Azure section | Set these up before testing with the Azure setup runbook. Managed identity is the default when available. Skip section 9 if the install has no Azure resources. |

## How to record results

1. Copy the sign-off table at the end of this document into the client's acceptance record.
2. For each case, record **Pass**, **Fail** or **N/A**. Add evidence: command output, the HTTP status and body, or a screenshot file name.
3. For a **Fail**, write a short note. If the failure blocks go-live, record the ticket reference.
4. The client signs off when every case in scope is **Pass**, or has an exception the client agrees to.

Keep screenshots and logs in one folder per run, for example `acceptance-<client>-<YYYY-MM-DD>/`.

## Conventions for dl-verify

This section is for the tool. The SI does not need it to run a visual case.

### Variables

Commands and requests use `${NAME}` placeholders. The SI fills in the inputs below in a vars file kept outside the repository. Start from `sdks/claude-si-kit/plugins/dataloader-si/examples/vars.example.env`. The file holds credentials, so store it like one. Cases save the other values as they run (see "Saved by cases").

Values marked **secret** must never be written into this document, a ticket, or the evidence folder.

**Install and host**

| Variable | Meaning | Example shape |
|---|---|---|
| `BASE_URL` | URL the checks call. Use the loopback URL on the host, or the HTTPS URL when running remotely. | `http://127.0.0.1:8080` |
| `PUBLIC_URL` | HTTPS URL users open. | `https://dataloader.client.example` |
| `INSTALL_DIR` | Directory holding `docker-compose.deploy.yml` and `.env`. | `/opt/dataloader` |
| `COMPOSE` | Compose command for this install. | `docker compose -f /opt/dataloader/docker-compose.deploy.yml` |
| `DATA_VOLUME` | Docker volume that holds the state directory. | `dataloader_dataloader-data` |
| `IMAGE_TAG` | Tag under test. | `1.0.0` |
| `EXPECTED_VERSION` | Version that `GET /api/v1/health` reports for `IMAGE_TAG`. | `1.0.0` |
| `UPGRADE_TAG`, `UPGRADE_VERSION` | Newer tag and its version, for section 14. | `1.0.1`, `1.0.1` |
| `LICENSE_JSON` | **Secret.** License file contents as one string. | `{"claim":{...},"signature":"..."}` |

**Users and sign-in**

| Variable | Meaning | Example shape |
|---|---|---|
| `ADMIN_EMAIL`, `ADMIN_PASSWORD` | Bootstrap admin. The password is **secret**. | `dl-admin@client.example`, 12+ characters |
| `ADMIN2_EMAIL`, `ADMIN2_PASSWORD` | Second local admin, created by CAT-AUTH-23. The password is **secret**. | `dl-admin2@client.example` |
| `EDITOR_EMAIL`, `EDITOR_PASSWORD` | Acceptance editor. The password is **secret**. | `dl-editor@client.example` |
| `VIEWER_EMAIL`, `VIEWER_PASSWORD` | Acceptance viewer. The password is **secret**. | `dl-viewer@client.example` |
| `SVC_EMAIL` | Service account email. | `dl-svc-acceptance@client.example` |
| `SSO_ISSUER_URL` | Entra issuer. | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| `SSO_CLIENT_ID` | App registration client ID. | UUID |
| `SSO_CLIENT_SECRET` | **Secret.** App registration client secret. | string |
| `SSO_REDIRECT_URI` | Redirect URI registered in Entra. | `https://dataloader.client.example/api/v1/auth/oidc/callback` |
| `SSO_ALLOWED_DOMAIN` | Email domain allowed to sign in. | `client.example` |

**Sources and loads**

| Variable | Meaning | Example shape |
|---|---|---|
| `SRC_POSTGRES_CONFIG`, `SRC_MSSQL_CONFIG`, `SRC_ORACLE_CONFIG`, `SRC_SNOWFLAKE_CONFIG`, `SRC_CLICKHOUSE_CONFIG`, `SRC_ICEBERG_CONFIG` | **Secret.** Connection settings for each source type in use. Field names come from `GET /api/v1/connectors/types?role=source`. | `{"host":"pg.client.example","port":5432,"database":"sales","username":"dl_ro","password":"..."}` |
| `SRC_POSTGRES_BAD_CONFIG` | The Postgres settings with a wrong password. | JSON object |
| `SRC_POSTGRES_KV_CONFIG` | Postgres settings whose `password` is a `kv://` reference (Azure only). | `{"host":"...","password":"kv://client-kv/pg-password"}` |
| `SRC_POSTGRES_SCHEMA`, `SRC_POSTGRES_TABLE` | Test table on the Postgres source. | `public`, `dl_acceptance` |
| `SECRET_PROBE` | **Secret.** One source password, used only to prove it does not leak. | string |
| `LOAD_SRC_ID` | Connection the loads read from. Defaults to `${CONN_POSTGRES_ID}`, the Postgres source CAT-CONN-02 saves. Change it only to load from another source. | `${CONN_POSTGRES_ID}` |
| `LOAD_SRC_SCHEMA`, `LOAD_SRC_TABLE` | Test table the loads read. | `public`, `dl_acceptance` |
| `LOAD_SRC_ROWS` | Row count of that table. Keep it under 1,000. | `250` |
| `LOAD_SRC_PK`, `LOAD_SRC_PK_JSON` | Primary key column, and the same as a JSON array. | `id`, `["id"]` |
| `LOAD_SRC_WATERMARK` | Updated-at timestamp column. | `updated_at` |
| `LOAD_SRC_DSN` | **Secret.** How the SI's SQL client connects to the load source. | `postgres://user:...@host/db` |
| `LOAD_SRC_INSERT_SQL` | Inserts one new row with the current timestamp. Two cases run it, so it must take a fresh key each time. | `INSERT INTO public.dl_acceptance (id, name, updated_at) SELECT max(id) + 1, 'cat', now() FROM public.dl_acceptance` |
| `CRON_TZ` | Client time zone for schedules. | `America/Denver` |
| `WEBHOOK_SECRET` | **Secret.** Shared secret for the acceptance webhook sensor. | random string |

**Destinations**

| Variable | Meaning | Example shape |
|---|---|---|
| `DEST_POSTGRES_CONFIG`, `DEST_DATABRICKS_CONFIG`, `DEST_SNOWFLAKE_CONFIG`, `DEST_ICEBERG_CONFIG` | **Secret.** Connection settings for each destination in use (`GET /api/v1/connectors/types?role=destination`). | JSON object |
| `DEST_POSTGRES_SCHEMA` | Test schema on the Postgres destination. | `dl_acceptance` |
| `DEST_DATABRICKS_CATALOG`, `DEST_DATABRICKS_SCHEMA` | Unity Catalog test location. | `sandbox`, `dl_acceptance` |
| `DEST_SNOWFLAKE_CATALOG`, `DEST_SNOWFLAKE_SCHEMA` | Snowflake database and schema. | `SANDBOX`, `DL_ACCEPTANCE` |
| `DEST_ICEBERG_CATALOG`, `DEST_ICEBERG_SCHEMA` | Iceberg catalog and namespace. | `lake`, `dl_acceptance` |
| `DEST_POSTGRES_DSN`, `DEST_DATABRICKS_DSN`, `DEST_SNOWFLAKE_DSN`, `DEST_ICEBERG_DSN` | **Secret.** How the SI's SQL client connects to each destination. | connection string, or CLI profile name |
| `DEST_DEFAULT_ID` | Destination to mark as default. Defaults to `${DEST_POSTGRES_ID}`, the Postgres destination CAT-DEST-01 saves. Change it only to mark another destination as default. | `${DEST_POSTGRES_ID}` |

**Notifications**

| Variable | Meaning | Example shape |
|---|---|---|
| `NOTIFY_CHANNEL_TYPE` | Channel type to test. | `teams_webhook` |
| `NOTIFY_CHANNEL_CONFIG` | **Secret.** Channel settings (`GET /api/v1/notifications/channel-types` lists the fields). | `{"webhook_url":"https://..."}` |
| `NOTIFY_EMAIL_TO` | Mailbox for the email test. | `dl-alerts@client.example` |
| `EMAIL_TRANSPORT_JSON` | **Secret.** SMTP transport settings. | `{"kind":"smtp","config":{"host":"smtp.client.example","port":587,"username":"...","password":"...","from":"..."}}` |

**Access policies (section 17)**

| Variable | Meaning | Example shape |
|---|---|---|
| `ACC_GROUP` | A Unity Catalog group (Databricks) or a role (Snowflake) that already exists. DataLoader does not create it. | `payroll_readers` |
| `ACC_TEXT_COLUMN` | A text column of the load table to mask, spelled as the destination column is. | `name` |
| `ACC_FILTER_COLUMN`, `ACC_FILTER_VALUE` | A column of the load table, and one value that stays visible to everyone. | `region`, `north` |

**dbt and automation (section 18)**

| Variable | Meaning | Example shape |
|---|---|---|
| `DBT_PROJECT_BODY` | **Secret.** The `POST /api/v1/dbt/projects` body for the client's dbt project: name, repository, ref, credential reference, and a TEST target with a destination and schema. Its source should read the table the Postgres load writes, or the load should feed one of its models. | `{"name":"acceptance","git_url":"https://git.client.example/dbt.git","targets":[...]}` |
| `DBT_MODEL_KEY` | Key of one model in that project, as the Assets page shows it. | `orders_clean` |
| `DAGSTER_URL` | Dagster address for the comparison. Only for the Dagster cases. | `https://acme.dagster.cloud/prod` |
| `DAGSTER_CODE_LOCATION` | The Dagster code location that is the dbt project. | `sales` |
| `DAGSTER_TOKEN` | **Secret.** A Dagster+ API token that can read the deployment. Set it in the environment of the `dl` command. Leave it unset for Dagster OSS. | string |

**Azure (section 9 only)**

| Variable | Meaning | Example shape |
|---|---|---|
| `AZ_TENANT_ID`, `AZ_SUBSCRIPTION_ID` | Tenant and subscription. | UUIDs |
| `AZ_RG` | DataLoader resource group. | `rg-dataloader-client` |
| `AZ_SP_CLIENT_ID` | Service principal client ID. | UUID |
| `AZ_SP_CLIENT_SECRET` | **Secret.** Service principal secret. | string |
| `AZ_KV_NAME`, `AZ_KV_URI` | Key Vault name and URI. | `client-dl-kv`, `https://client-dl-kv.vault.azure.net/` |
| `AZ_KV_PROBE_VALUE` | **Secret.** Throwaway value written by CAT-AZ-03. | random string |
| `AZ_MI_CLIENT_ID`, `AZ_MI_RESOURCE_ID` | Managed identity client ID and resource ID. | UUID, `/subscriptions/.../userAssignedIdentities/dl-mi` |
| `AZ_ACR_NAME`, `AZ_ACR_LOGIN_SERVER` | Registry name and login server. | `clientdlacr`, `clientdlacr.azurecr.io` |
| `AZ_WORKER_TAG` | Worker image tag in the registry. | `1.0.0` |
| `AZ_ACA_ENV_ID` | Container Apps environment resource ID. | `/subscriptions/.../managedEnvironments/dl-env` |
| `AZ_CALLBACK_BASE` | Public URL that workers call back to. Also `DL_FANOUT_CALLBACK_BASE` in `.env`. | `https://dataloader.client.example` |
| `FANOUT_SRC_ID`, `FANOUT_SRC_SCHEMA`, `FANOUT_SRC_TABLE` | Large source table for fan-out. | UUID, `public`, `dl_large` |
| `FANOUT_SRC_ROWS` | Its row count. | `2000000` |
| `FANOUT_PARTITION_COLUMN` | Integer column to split on. | `id` |
| `FANOUT_THRESHOLD` | Workspace fan-out threshold for the test. Set it below `FANOUT_SRC_ROWS`. | `100000` |

**Jobs (section 22)**

| Variable | Meaning | Example shape |
|---|---|---|
| `JOB_BODY` | The `POST /api/v1/jobs` body for one acceptance job. Its name starts with `acceptance-`, it is enabled, and it uses a connection or destination this install can reach. The plan creates, runs and deletes only this job. | `{"name":"acceptance-jobs","environment":"test","job_type":"databricks","connection_id":"<uuid>","settings":{...},"timeout_secs":600}` |

**Saved by cases**: every other name, such as `SESSION`, `ADMIN_ID`, `CONN_POSTGRES_ID` or `TC_PG_ID`. The `save` key in each marker shows where it comes from. `SVC_TOKEN` and `OAUTH_CLIENT_SECRET` are secrets captured at run time. dl-verify must not write them to its report.

Substitution rules:

- `${NAME}` inside a string is replaced by the variable's text.
- A JSON value that is exactly `"${NAME}"` is replaced by the variable's value, parsed as JSON. If it does not parse, it is sent as a string.
- A case whose variables are not set is recorded as N/A, not run.

### Markers

Directly under each case heading is one HTML comment with a single-line JSON object. dl-verify reads lines that match `^<!-- cat: (.*) -->$`. The example below is indented, so it is not read as a case:

```
  <!-- cat: {"id":"CAT-EXAMPLE-00","mode":"automatable","check":{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"expect_json":{"status":"healthy"}}} -->
```

Keys:

| Key | Required | Meaning |
|---|---|---|
| `id` | yes | Stable case ID, `CAT-<AREA>-<NN>`. IDs are never reused or renumbered. |
| `mode` | yes | `automatable` or `visual`. |
| `check` | automatable only | One check object, or an array of check objects run in order. The case passes when every check passes. |
| `look_for` | visual only | Array of short criteria a person confirms on screen. |
| `requires` | no | Array of tags. dl-verify records the case as N/A when a tag is not enabled for the run. Tags: `azure`, `sso`, `license`, `lockout` (an install whose trial or license has expired), `https`, `plugin`, `notify`, `src:<type>`, `dest:<type>`, `upgrade`, `hostunit` (a Docker install with the host update unit), `dbt` (a dbt project the client wants checked), `dagster` (the dbt project runs under Dagster today and moves to DataLoader). |
| `depends_on` | no | Array of case IDs whose saved values this case uses. |
| `destructive` | no | `true` when the case stops the service, changes the image, deletes something, or restores data. dl-verify asks before it runs. The prose carries a matching **Warning** line. |
| `known_issue` | no | Issue reference (`#NNNN`, or `pending` until one is filed) for a known defect that makes the case fail today. dl-verify reports these failures as expected, apart from regressions. |

Each marker stays on one line. The plan never contains a secret. Every credential is a `${VAR}` from the variables tables.

### Check kinds

There are four check kinds. Every check object has a `kind`.

**`http`**: a request to DataLoader.

| Field | Meaning |
|---|---|
| `method`, `path` | Request line. `path` starts `/api/v1/` and resolves against `BASE_URL`. |
| `auth` | `none`; `session` (the admin session cookie saved as `SESSION`, the default); `session:<VAR>` (the cookie saved under `VAR`); or `bearer:<VAR>` (sends `Authorization: Bearer ${VAR}`). |
| `body` | JSON request body. `form` sends `application/x-www-form-urlencoded`. `multipart` sends files: `{"file":"@path"}`. |
| `headers` | Extra request headers. |
| `expect_status` | Status code, or an array of allowed codes. |
| `expect_json` | Object of `dotted.path: expected value`. Array indexes are numbers (`items.0.status`). `"*"` means present and not null. |
| `expect_json_contains` | Object of `dotted.path: value`. The path is an array that must contain the value, or a string that must contain it. `@body` means the whole response as text. |
| `expect_body_not_contains` | String, or array of strings, that must not appear anywhere in the response. |
| `save` | Object of `VAR: dotted.path`. Stores response values for later cases. `"@cookie"` stores every cookie the response set. `"@body"` stores the whole JSON body. |
| `retry` | `{"every_s":N,"for_s":M}`: repeat until the checks pass or time runs out. Used for runs and sensors. |

**`cli`**: a shell command on the DataLoader host.

| Field | Meaning |
|---|---|
| `run` | Command line (bash). |
| `expect_exit` | Exit code. Default `0`. |
| `expect_stdout_contains` | String, or array of strings, that must appear in stdout. |
| `expect_stdout_not_contains` | String, or array of strings, that must not appear. |
| `retry` | Same as for `http`. |

**`sql`**: a query against a destination or source, run with the SI's SQL client.

| Field | Meaning |
|---|---|
| `target` | Variable that holds the connection details, such as `DEST_POSTGRES_DSN`. |
| `query` | One SQL statement. |
| `expect_scalar` | Expected value of the first column of the first row. |
| `expect_min` | Minimum numeric value of the first column of the first row. |

**`ui`**: a browser check with a pass condition a script can test.

| Field | Meaning |
|---|---|
| `path` | Page path under `PUBLIC_URL`, such as `/login`. |
| `login` | `true` to sign in as the bootstrap admin first. |
| `expect_selector` | CSS selector that must be visible. |
| `expect_text` | Text that must appear on the page. |
| `expect_no_console_errors` | `true` to fail on any console error or page error. |

---

## 1. Install and health

The install uses `docker-compose.deploy.yml` in `${INSTALL_DIR}`. The image is pinned in `${INSTALL_DIR}/.env` as `DATALOADER_TAG=${IMAGE_TAG}`. Metadata lives in the embedded Postgres inside the `dataloader-data` volume, unless the client chose an external Postgres.

### CAT-HEALTH-01 Host has Docker Engine and the compose plugin
<!-- cat: {"id":"CAT-HEALTH-01","mode":"automatable","check":[{"kind":"cli","run":"docker version --format '{{.Server.Version}}'"},{"kind":"cli","run":"docker compose version --short"}]} -->

- **Before you start**: Shell on the host, as a user in the `docker` group.
- **Steps**: Run `docker version --format '{{.Server.Version}}'` and `docker compose version --short`.
- **Expected**: Both exit 0. The server is version 24 or later, and compose is v2.

### CAT-HEALTH-02 Image tag is pinned
<!-- cat: {"id":"CAT-HEALTH-02","mode":"automatable","check":{"kind":"cli","run":"${COMPOSE} config --images","expect_stdout_contains":":${IMAGE_TAG}"}} -->

- **Before you start**: `${INSTALL_DIR}/.env` exists.
- **Steps**: Run `${COMPOSE} config --images`.
- **Expected**: The image ends in `:${IMAGE_TAG}`, not `:stable` or `:latest`.

### CAT-HEALTH-03 Container is running and healthy
<!-- cat: {"id":"CAT-HEALTH-03","mode":"automatable","check":{"kind":"cli","run":"${COMPOSE} ps --format '{{.Service}} {{.Status}}'","expect_stdout_contains":"dataloader","retry":{"every_s":10,"for_s":180},"expect_stdout_not_contains":["unhealthy","Restarting"]}} -->

- **Before you start**: `${COMPOSE} up -d` has run.
- **Steps**: Run `${COMPOSE} ps`. The first boot unpacks the embedded Postgres and runs migrations, so allow up to 3 minutes. The service needs no outbound access to start.
- **Expected**: The `dataloader` service shows `Up ... (healthy)` and is not restarting.

### CAT-HEALTH-04 Liveness endpoint reports healthy
<!-- cat: {"id":"CAT-HEALTH-04","mode":"automatable","check":{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"expect_json":{"status":"healthy","database":true,"dev_mode":false}}} -->

- **Before you start**: CAT-HEALTH-03 passed.
- **Steps**: `curl -fsS ${BASE_URL}/api/v1/health`
- **Expected**: HTTP 200. The body has `"status":"healthy"`, `"database":true` and `"dev_mode":false`. `database_mode` is `embedded` or `external`, to match the client's choice.

### CAT-HEALTH-05 Readiness endpoint reports ready
<!-- cat: {"id":"CAT-HEALTH-05","mode":"automatable","check":{"kind":"http","method":"GET","path":"/api/v1/health/ready","auth":"none","expect_status":200,"expect_json":{"status":"ready","pool_acquire":true}}} -->

- **Steps**: `curl -fsS ${BASE_URL}/api/v1/health/ready`
- **Expected**: HTTP 200 with `"status":"ready"` and `"pool_acquire":true`.

### CAT-HEALTH-06 Running version matches the tag under test
<!-- cat: {"id":"CAT-HEALTH-06","mode":"automatable","check":{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"expect_json":{"version":"${EXPECTED_VERSION}"}}} -->

- **Steps**: Read `version` from `GET /api/v1/health`.
- **Expected**: `version` equals `${EXPECTED_VERSION}`.

### CAT-HEALTH-07 Boot log is clean
<!-- cat: {"id":"CAT-HEALTH-07","mode":"automatable","check":{"kind":"cli","run":"${COMPOSE} logs --no-color dataloader","expect_stdout_contains":"Listening on","expect_stdout_not_contains":["panicked","Migration error","\"level\":\"ERROR\""]}} -->

- **Steps**: Run `${COMPOSE} logs --no-color dataloader` and read the start-up lines.
- **Expected**: Migrations applied, and the server listening on port 8080. No panics, no migration errors, and no `ERROR` lines.

### CAT-HEALTH-08 Port is bound to localhost only
<!-- cat: {"id":"CAT-HEALTH-08","mode":"automatable","check":{"kind":"cli","run":"${COMPOSE} port dataloader 8080","expect_stdout_contains":"127.0.0.1:"}} -->

- **Before you start**: The client has not chosen to expose port 8080 on a private network.
- **Steps**: Run `${COMPOSE} port dataloader 8080`.
- **Expected**: The output starts with `127.0.0.1:`. Only the reverse proxy on the host reaches DataLoader.

### CAT-HEALTH-09 HTTPS through the reverse proxy
<!-- cat: {"id":"CAT-HEALTH-09","mode":"automatable","requires":["https"],"check":{"kind":"cli","run":"curl -fsS -o /dev/null -w '%{http_code} %{ssl_verify_result}' ${PUBLIC_URL}/api/v1/health","expect_stdout_contains":"200 0"}} -->

- **Before you start**: Reverse proxy and certificate are in place.
- **Steps**: From a machine on the client network, run `curl -fsS ${PUBLIC_URL}/api/v1/health`.
- **Expected**: HTTP 200, with a certificate that verifies (no `-k`). Plain `http://` to the public name redirects to HTTPS or is refused.

### CAT-HEALTH-10 First-boot status is public and shows setup state
<!-- cat: {"id":"CAT-HEALTH-10","mode":"automatable","check":{"kind":"http","method":"GET","path":"/api/v1/setup/status","auth":"none","expect_status":200,"expect_json":{"first_boot":"*"}}} -->

- **Steps**: `curl -fsS ${BASE_URL}/api/v1/setup/status`
- **Expected**: HTTP 200 with `first_boot` and `workspace_configured`. On a new install, `first_boot` stays `true` until the setup wizard finishes.

### CAT-HEALTH-11 Deployment target is detected as compose
<!-- cat: {"id":"CAT-HEALTH-11","mode":"automatable","check":{"kind":"http","method":"GET","path":"/api/v1/runtime/deployment-target","auth":"none","expect_status":200,"expect_json":{"target":"compose"}}} -->

- **Steps**: `curl -fsS ${BASE_URL}/api/v1/runtime/deployment-target`
- **Expected**: `{"target":"compose"}`. Admin pages use this to show the right restart command.

### CAT-HEALTH-12 State volume exists and holds the keys
<!-- cat: {"id":"CAT-HEALTH-12","mode":"automatable","check":{"kind":"cli","run":"${COMPOSE} exec -T dataloader ls /var/lib/dataloader","expect_stdout_contains":["jwt.key","master.key"]}} -->

- **Steps**: Run `${COMPOSE} exec -T dataloader ls /var/lib/dataloader`.
- **Expected**: The listing has `jwt.key` and `master.key`, and `pg/` for embedded Postgres. Both key files must be in every backup. Losing `master.key` means re-entering the sign-in and Azure secrets.

### CAT-HEALTH-13 Web app loads in a browser
<!-- cat: {"id":"CAT-HEALTH-13","mode":"automatable","check":{"kind":"ui","path":"/login","expect_selector":"input[type=password]","expect_no_console_errors":true}} -->

- **Steps**: Open `${PUBLIC_URL}/` in Chrome or Edge.
- **Expected**: The browser opens `/login`, or `/setup` for a new install. The page shows no console errors. You are not signed in automatically.

### CAT-HEALTH-14 Service survives a restart
<!-- cat: {"id":"CAT-HEALTH-14","mode":"automatable","destructive":true,"check":[{"kind":"cli","run":"${COMPOSE} restart dataloader"},{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"expect_json":{"status":"healthy"},"retry":{"every_s":5,"for_s":120}}]} -->

- **Warning**: Restarts the service. Runs in progress stop.
- **Steps**: Run `${COMPOSE} restart dataloader`, then poll `GET /api/v1/health`.
- **Expected**: Health returns to `healthy` within 2 minutes. Data and settings from earlier cases are still there. Re-run CAT-LIC-01 and CAT-AUTH-04 to confirm.

---

## 2. Licensing

A new install with no license runs a 30-day trial with every feature on. A signed license has a seven-day grace period after its expiry date, during which everything works as normal. A trial has no grace period. When the grace period or the trial ends, the app is read-only: sign-in, reading and export still work, running loads finish, and every change returns HTTP 402 until a valid license is uploaded.

### CAT-LIC-01 License status is readable
<!-- cat: {"id":"CAT-LIC-01","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"GET","path":"/api/v1/settings/license","expect_status":200,"expect_json":{"status":"*"}}} -->

- **Before you start**: Signed in (CAT-AUTH-03).
- **Steps**: `GET /api/v1/settings/license`
- **Expected**: HTTP 200. Before a license is uploaded, `status` is `trial` and `trial_days_remaining` is between 1 and 30. After upload, `status` is `active`, or `expiring_soon` within 30 days of expiry.

### CAT-LIC-02 Invalid license is rejected
<!-- cat: {"id":"CAT-LIC-02","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"POST","path":"/api/v1/settings/license","body":{"license_key":"{\"claim\":{},\"signature\":\"bad\"}"},"expect_status":400,"expect_json":{"category":"*"}}} -->

- **Steps**: `POST /api/v1/settings/license` with a tampered license, such as `{"license_key":"{\"claim\":{},\"signature\":\"bad\"}"}`.
- **Expected**: HTTP 400 with a `category` and a readable `message`. The status from CAT-LIC-01 does not change.

### CAT-LIC-03 Client license applies
<!-- cat: {"id":"CAT-LIC-03","mode":"automatable","requires":["license"],"depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"POST","path":"/api/v1/settings/license","body":{"license_key":"${LICENSE_JSON}"},"expect_status":200,"expect_json":{"status":"active"}}} -->

- **Before you start**: The license file from Dakota.
- **Steps**: In the app, open **Admin, License** and paste or upload the license. Or call `POST /api/v1/settings/license` with `{"license_key":"<file contents>"}`.
- **Expected**: HTTP 200 and `status` `active`. `tenant` shows the client name, and `expires_at` matches the contract. If the trial has already ended, the upload still works. See CAT-LIC-07.

### CAT-LIC-04 Licensed features match the contract
<!-- cat: {"id":"CAT-LIC-04","mode":"automatable","requires":["license"],"depends_on":["CAT-LIC-03"],"check":{"kind":"http","method":"GET","path":"/api/v1/settings/license","expect_status":200,"expect_json":{"status":"active","features":"*"}}} -->

- **Steps**: `GET /api/v1/settings/license`. Read `features` and `max_connections`.
- **Expected**: `features` lists what the client bought: `ai`, `container_offload` and `plugins`. `container_offload` must be present if the client uses fan-out. `plugins` must be present if they install a plugin. `max_connections` matches the contract. Absent means unlimited.

### CAT-LIC-05 License survives a restart
<!-- cat: {"id":"CAT-LIC-05","mode":"automatable","requires":["license"],"destructive":true,"depends_on":["CAT-LIC-03"],"check":[{"kind":"cli","run":"${COMPOSE} restart dataloader"},{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"retry":{"every_s":5,"for_s":120}},{"kind":"http","method":"GET","path":"/api/v1/settings/license","expect_status":200,"expect_json":{"status":"active"}}]} -->

- **Warning**: Restarts the service. Runs in progress stop.
- **Steps**: Restart the service, sign in again if needed, and read the license status.
- **Expected**: Status is still `active`, with the same tenant and expiry.

### CAT-LIC-06 License page and trial banner read correctly
<!-- cat: {"id":"CAT-LIC-06","mode":"visual","look_for":["Admin, License shows tenant, plan, expiry and features that match the API","During a trial, a banner shows the days left; after a license is applied, the banner is gone","No raw error codes or developer notes on the page"]} -->

- **Steps**: Open **Admin, License**. On a trial install, also look at the top of any page.
- **Expected**: See `look_for`.

### CAT-LIC-07 Expired install can sign in and recover
<!-- cat: {"id":"CAT-LIC-07","mode":"automatable","requires":["lockout","license"],"check":[{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${ADMIN_EMAIL}","password":"${ADMIN_PASSWORD}"},"expect_status":200,"save":{"SESSION":"@cookie"}},{"kind":"http","method":"GET","path":"/api/v1/settings/license","expect_status":200,"expect_json":{"status":"expired"}},{"kind":"http","method":"POST","path":"/api/v1/auth/refresh","expect_status":200,"save":{"SESSION":"@cookie"}},{"kind":"http","method":"POST","path":"/api/v1/connections","body":{"connection_key":"cat_lockout_probe","display_name":"probe","db_type":"postgres","config_json":{}},"expect_status":402,"expect_json":{"category":"license_expired"}},{"kind":"http","method":"POST","path":"/api/v1/settings/license","body":{"license_key":"${LICENSE_JSON}"},"expect_status":200,"expect_json":{"status":"active"}},{"kind":"http","method":"POST","path":"/api/v1/auth/logout","expect_status":[200,204]}]} -->

- **Before you start**: An install whose trial or license has expired. Use a test host with the clock past the trial end, or an expired test license. Skip this on a live install.
- **Steps**: Sign in as the admin, read the license status, try a change, upload a valid license, and sign out.
- **Expected**: Sign-in, license upload, session refresh and sign-out all work while locked out. Other changes return 402 `license_expired` until the new license applies. After that, the app is writable again.

---

## 3. Sign-in and roles

DataLoader has three people roles: admin, editor and viewer. It also has service accounts. The first admin comes from the bootstrap settings. After single sign-on (SSO) is set up, at least one Entra user must be an admin before the bootstrap admin can be disabled.

Most API routes accept only the browser session cookie. API tokens and OAuth client tokens are accepted by `GET /api/v1/auth/whoami`. CAT-AUTH-19 checks whether they reach other routes.

### CAT-AUTH-01 Bootstrap admin was seeded once
<!-- cat: {"id":"CAT-AUTH-01","mode":"automatable","check":{"kind":"cli","run":"${COMPOSE} logs --no-color dataloader","expect_stdout_contains":"Bootstrap admin seeded"}} -->

- **Before you start**: First boot ran with `DL_BOOTSTRAP_ADMIN_EMAIL` and `DL_BOOTSTRAP_ADMIN_PASSWORD` set in `.env`.
- **Steps**: Search the first-boot log for `Bootstrap admin seeded`.
- **Expected**: The line appears once, with the admin email and no password. After the first successful sign-in, remove `DL_BOOTSTRAP_ADMIN_PASSWORD` from `.env`.

### CAT-AUTH-02 Wrong password is refused
<!-- cat: {"id":"CAT-AUTH-02","mode":"automatable","check":{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${ADMIN_EMAIL}","password":"not-the-password"},"expect_status":401,"expect_json":{"error":"Invalid credentials"}}} -->

- **Steps**: `POST /api/v1/auth/login` with the admin email and a wrong password.
- **Expected**: HTTP 401 with `"error":"Invalid credentials"`. The body shows no stack trace and no database detail.

### CAT-AUTH-03 Bootstrap admin signs in
<!-- cat: {"id":"CAT-AUTH-03","mode":"automatable","check":{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${ADMIN_EMAIL}","password":"${ADMIN_PASSWORD}"},"expect_status":200,"expect_json":{"role":"admin"},"save":{"SESSION":"@cookie","ADMIN_ID":"user_id"}}} -->

- **Steps**: `POST /api/v1/auth/login` with `{"email":"${ADMIN_EMAIL}","password":"${ADMIN_PASSWORD}"}`.
- **Expected**: HTTP 200 and `role` `admin`. The response sets the `dl_access_token` and `dl_refresh_token` cookies. Both are `HttpOnly`, and `Secure` outside dev mode. Later cases send the saved cookie.

### CAT-AUTH-04 Session identifies the admin
<!-- cat: {"id":"CAT-AUTH-04","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"GET","path":"/api/v1/auth/me","expect_status":200,"expect_json":{"email":"${ADMIN_EMAIL}","role":"admin"}}} -->

- **Steps**: `GET /api/v1/auth/me` with the session cookie.
- **Expected**: HTTP 200 with the admin email and `role` `admin`.

### CAT-AUTH-05 Requests without a session are refused
<!-- cat: {"id":"CAT-AUTH-05","mode":"automatable","check":[{"kind":"http","method":"GET","path":"/api/v1/connections","auth":"none","expect_status":401},{"kind":"http","method":"GET","path":"/api/v1/users","auth":"none","expect_status":401}]} -->

- **Steps**: Call `GET /api/v1/connections` and `GET /api/v1/users` with no cookie.
- **Expected**: HTTP 401 for both.

### CAT-AUTH-06 Setup wizard can be completed
<!-- cat: {"id":"CAT-AUTH-06","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/setup/complete","expect_status":[200,204]},{"kind":"http","method":"GET","path":"/api/v1/setup/status","auth":"none","expect_status":200,"expect_json":{"first_boot":false}}]} -->

- **Before you start**: The SI walked the wizard in the browser (CAT-UI-02), or set up the workspace through the API.
- **Steps**: Finish the wizard, or call `POST /api/v1/setup/complete`. Then read `GET /api/v1/setup/status`.
- **Expected**: `first_boot` is `false`. Signing in now opens Overview, not the setup wizard.

### CAT-AUTH-07 SSO is reported as not configured before setup
<!-- cat: {"id":"CAT-AUTH-07","mode":"automatable","check":{"kind":"http","method":"GET","path":"/api/v1/auth/sso/status","auth":"none","expect_status":200,"expect_json":{"configured":"*"}}} -->

- **Steps**: `GET /api/v1/auth/sso/status` with no cookie.
- **Expected**: HTTP 200 with `configured`, `provider`, `login_url` and `enforced`. Before SSO is saved, `configured` is `false`, and the sign-in page shows only the email form.

### CAT-AUTH-08 SSO settings save
<!-- cat: {"id":"CAT-AUTH-08","mode":"automatable","requires":["sso"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/settings/sso","body":{"issuer_url":"${SSO_ISSUER_URL}","client_id":"${SSO_CLIENT_ID}","redirect_url":"${SSO_REDIRECT_URI}","allowed_email_domains":["${SSO_ALLOWED_DOMAIN}"]},"expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/settings/sso/rotate-secret","body":{"client_secret":"${SSO_CLIENT_SECRET}"},"expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/settings/sso","expect_status":200,"expect_json":{"client_id":"${SSO_CLIENT_ID}"}}]} -->

- **Before you start**: The Entra app registration has the redirect URI `${PUBLIC_URL}/api/v1/auth/oidc/callback`.
- **Steps**: Open **Admin, Sign-in**. Enter the issuer URL, client ID, redirect URI, allowed email domains and client secret. Save. The API equivalent is `PUT /api/v1/settings/sso`, then `POST /api/v1/settings/sso/rotate-secret` with `{"client_secret":"${SSO_CLIENT_SECRET}"}`.
- **Expected**: Both calls return 200. `GET /api/v1/settings/sso` shows the saved values and never returns the client secret.

### CAT-AUTH-09 SSO discovery test passes
<!-- cat: {"id":"CAT-AUTH-09","mode":"automatable","requires":["sso"],"depends_on":["CAT-AUTH-08"],"check":{"kind":"http","method":"POST","path":"/api/v1/settings/sso/test","expect_status":200,"expect_json":{"ok":true}}} -->

- **Steps**: Click **Test connection** on the Sign-in page, or call `POST /api/v1/settings/sso/test`.
- **Expected**: HTTP 200 with `"ok":true` and a message such as "Probed 5 endpoints". A failure returns `"ok":false` and a `code`, such as `discovery_unreachable`.

### CAT-AUTH-10 Login page offers Microsoft sign-in
<!-- cat: {"id":"CAT-AUTH-10","mode":"automatable","requires":["sso"],"depends_on":["CAT-AUTH-08"],"check":[{"kind":"http","method":"GET","path":"/api/v1/auth/sso/status","auth":"none","expect_status":200,"expect_json":{"configured":true}},{"kind":"ui","path":"/login","expect_selector":"[data-test=\"sso-button\"]","expect_text":"Sign in with Microsoft"}]} -->

- **Steps**: Sign out and open `/login`.
- **Expected**: `configured` is `true`. The page shows **Sign in with Microsoft** above the email form. The email form is still there.

### CAT-AUTH-11 Entra user signs in
<!-- cat: {"id":"CAT-AUTH-11","mode":"visual","requires":["sso"],"depends_on":["CAT-AUTH-10"],"look_for":["Clicking Sign in with Microsoft goes to login.microsoftonline.com for the client tenant","After Entra sign-in and MFA, the browser returns to DataLoader and lands on Overview","The top bar shows the Entra user's name","As admin, Users lists the new user with an Entra identity"]} -->

- **Before you start**: An Entra test user whose email is in `${SSO_ALLOWED_DOMAIN}`.
- **Steps**: In a private browser window, click **Sign in with Microsoft** and finish the Microsoft sign-in.
- **Expected**: See `look_for`. New SSO users start as viewers, unless group sync gives them a role.

### CAT-AUTH-12 Email outside the allowed domains is refused
<!-- cat: {"id":"CAT-AUTH-12","mode":"visual","requires":["sso"],"depends_on":["CAT-AUTH-10"],"look_for":["Sign-in with an Entra account outside the allowed domains ends on an error, not Overview","The browser lands on the login page, which says the email domain is not allowed","No user row is created for that account"]} -->

- **Before you start**: A Microsoft account in the tenant whose email domain is not allowed. Skip if none exists.
- **Steps**: Sign in with that account.
- **Expected**: See `look_for`.

### CAT-AUTH-13 Admin creates an editor and a viewer
<!-- cat: {"id":"CAT-AUTH-13","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/users","body":{"email":"${EDITOR_EMAIL}","display_name":"Acceptance Editor","role":"editor","password":"${EDITOR_PASSWORD}"},"expect_status":201,"save":{"EDITOR_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/users","body":{"email":"${VIEWER_EMAIL}","display_name":"Acceptance Viewer","role":"viewer","password":"${VIEWER_PASSWORD}"},"expect_status":201,"save":{"VIEWER_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${EDITOR_EMAIL}","password":"${EDITOR_PASSWORD}"},"expect_status":200,"expect_json":{"role":"editor"},"save":{"SESSION_EDITOR":"@cookie"}},{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${VIEWER_EMAIL}","password":"${VIEWER_PASSWORD}"},"expect_status":200,"expect_json":{"role":"viewer"},"save":{"SESSION_VIEWER":"@cookie"}}]} -->

- **Steps**: In **Users**, click **New user** twice: one editor, one viewer, each with a local password of 12 characters or more. The API is `POST /api/v1/users` with `{email, display_name, role, password}`. Then sign in as each.
- **Expected**: Each create returns 201. Each user signs in and has the role they were given. A second create with the same email returns 409 `email_exists`.

### CAT-AUTH-14 Viewer cannot change anything
<!-- cat: {"id":"CAT-AUTH-14","mode":"automatable","depends_on":["CAT-AUTH-13"],"check":[{"kind":"http","method":"GET","path":"/api/v1/connections","auth":"session:SESSION_VIEWER","expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/connections","auth":"session:SESSION_VIEWER","body":{"connection_key":"cat_viewer_probe","display_name":"probe","db_type":"postgres","config_json":{}},"expect_status":403,"expect_json":{"error":"forbidden"}},{"kind":"http","method":"GET","path":"/api/v1/users","auth":"session:SESSION_VIEWER","expect_status":403}]} -->

- **Steps**: As the viewer, list connections, try to create one, and try to list users.
- **Expected**: The list returns 200. The create and the users list return 403 with `"error":"forbidden"`. The message does not say which role is needed.

### CAT-AUTH-15 Editor cannot reach admin surfaces
<!-- cat: {"id":"CAT-AUTH-15","mode":"automatable","depends_on":["CAT-AUTH-13"],"check":[{"kind":"http","method":"GET","path":"/api/v1/users","auth":"session:SESSION_EDITOR","expect_status":403},{"kind":"http","method":"GET","path":"/api/v1/settings/sso","auth":"session:SESSION_EDITOR","expect_status":403},{"kind":"http","method":"GET","path":"/api/v1/plugins","auth":"session:SESSION_EDITOR","expect_status":403}]} -->

- **Steps**: As the editor, call `GET /api/v1/users`, `GET /api/v1/settings/sso` and `GET /api/v1/plugins`.
- **Expected**: HTTP 403 for each.

### CAT-AUTH-16 Navigation matches the role
<!-- cat: {"id":"CAT-AUTH-16","mode":"visual","depends_on":["CAT-AUTH-13"],"look_for":["Signed in as viewer or editor, the sidebar has no Admin item","Pasting /admin/users or /settings/license into the address bar as a viewer or editor redirects to Overview with a short message","Viewer sees no New or Run buttons that would fail with 403","Signed in as admin, the Admin item is present and opens Users, Groups, Sign-in, Sessions, Key vaults, OAuth clients, Audit history, Compute and fan-out, Database, Logs, Email, AI provider, Automation, General, Default destination, License, Notifications, Plugins and Updates"]} -->

- **Steps**: Sign in as the viewer, then the editor, then the admin. Check the sidebar and the pages listed.
- **Expected**: See `look_for`.

### CAT-AUTH-17 Admin cannot disable themselves
<!-- cat: {"id":"CAT-AUTH-17","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"PATCH","path":"/api/v1/users/${ADMIN_ID}/disable","expect_status":409,"expect_json":{"error":"cannot_disable_self"}}} -->

- **Steps**: As the bootstrap admin, call `PATCH /api/v1/users/${ADMIN_ID}/disable`.
- **Expected**: HTTP 409 `cannot_disable_self`. The account stays enabled.

### CAT-AUTH-18 Disabled user cannot sign in
<!-- cat: {"id":"CAT-AUTH-18","mode":"automatable","depends_on":["CAT-AUTH-13"],"check":[{"kind":"http","method":"PATCH","path":"/api/v1/users/${VIEWER_ID}/disable","expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${VIEWER_EMAIL}","password":"${VIEWER_PASSWORD}"},"expect_status":403,"expect_json":{"error":"account_disabled"}},{"kind":"http","method":"PATCH","path":"/api/v1/users/${VIEWER_ID}/enable","expect_status":200}]} -->

- **Steps**: Disable the viewer. Try to sign in as the viewer. Enable the viewer again.
- **Expected**: Disable returns 200. Sign-in returns 403 `account_disabled`, even with the right password. Enable returns 200, and the viewer can sign in again.

### CAT-AUTH-19 API token authenticates a service account
<!-- cat: {"id":"CAT-AUTH-19","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/admin/users/service-account","body":{"email":"${SVC_EMAIL}","display_name":"Acceptance service account"},"expect_status":[200,201],"save":{"SVC_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/admin/users/${SVC_ID}/tokens","body":{"name":"acceptance","ttl_days":7},"expect_status":[200,201],"save":{"SVC_TOKEN":"token","SVC_TOKEN_ID":"id"}},{"kind":"http","method":"GET","path":"/api/v1/auth/whoami","auth":"bearer:SVC_TOKEN","expect_status":200,"expect_json":{"auth_method":"bearer"}},{"kind":"http","method":"GET","path":"/api/v1/connections","auth":"bearer:SVC_TOKEN","expect_status":200}]} -->

- **Steps**: Create a service account. Create a token for it. The token shows once. Call `GET /api/v1/auth/whoami` and `GET /api/v1/connections` with `Authorization: Bearer <token>`.
- **Expected**: `whoami` returns 200 with `"auth_method":"bearer"`. `GET /api/v1/connections` returns 200. The token works on every route its role allows.

### CAT-AUTH-20 API token can be revoked
<!-- cat: {"id":"CAT-AUTH-20","mode":"automatable","depends_on":["CAT-AUTH-19"],"destructive":true,"check":[{"kind":"http","method":"DELETE","path":"/api/v1/admin/users/${SVC_ID}/tokens/${SVC_TOKEN_ID}","expect_status":[200,204]},{"kind":"http","method":"GET","path":"/api/v1/auth/whoami","auth":"bearer:SVC_TOKEN","expect_status":401}]} -->

- **Warning**: Deletes the acceptance token. Do not point `SVC_ID` at a production service account.
- **Steps**: Revoke the token, then call `whoami` with it.
- **Expected**: Revoke returns 204, or 200. `whoami` then returns 401.

### CAT-AUTH-21 OAuth client credentials issue a token
<!-- cat: {"id":"CAT-AUTH-21","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/settings/oauth-clients","body":{"name":"acceptance-client","scopes":["read"]},"expect_status":201,"save":{"OAUTH_CLIENT_ID":"client.client_id","OAUTH_CLIENT_SECRET":"client_secret","OAUTH_ROW_ID":"client.id"}},{"kind":"http","method":"POST","path":"/api/v1/oauth/token","auth":"none","form":{"grant_type":"client_credentials","client_id":"${OAUTH_CLIENT_ID}","client_secret":"${OAUTH_CLIENT_SECRET}","scope":"read"},"expect_status":200,"expect_json":{"token_type":"bearer","expires_in":3600}},{"kind":"http","method":"POST","path":"/api/v1/oauth/token","auth":"none","form":{"grant_type":"client_credentials","client_id":"${OAUTH_CLIENT_ID}","client_secret":"wrong","scope":"read"},"expect_status":401,"expect_json":{"error":"invalid_client"}}]} -->

- **Steps**: In **Admin, OAuth clients**, create a client with scope `read`. Copy the secret. It shows once. Exchange it at `POST /api/v1/oauth/token` with `grant_type=client_credentials`. Then try a wrong secret.
- **Expected**: Create returns 201 with a secret that starts `dlos_`. The exchange returns 200, `token_type` `bearer` and `expires_in` 3600. The wrong secret returns 401 `invalid_client`.

### CAT-AUTH-22 OAuth client can be revoked
<!-- cat: {"id":"CAT-AUTH-22","mode":"automatable","depends_on":["CAT-AUTH-21"],"destructive":true,"check":[{"kind":"http","method":"DELETE","path":"/api/v1/settings/oauth-clients/${OAUTH_ROW_ID}","expect_status":204},{"kind":"http","method":"POST","path":"/api/v1/oauth/token","auth":"none","form":{"grant_type":"client_credentials","client_id":"${OAUTH_CLIENT_ID}","client_secret":"${OAUTH_CLIENT_SECRET}","scope":"read"},"expect_status":401}]} -->

- **Warning**: Revokes the acceptance OAuth client.
- **Steps**: Delete the client. Try the token exchange again.
- **Expected**: Delete returns 204. The exchange returns 401 `invalid_client`.

### CAT-AUTH-23 Bootstrap admin cannot be disabled before an SSO admin exists
<!-- cat: {"id":"CAT-AUTH-23","mode":"automatable","depends_on":["CAT-AUTH-13"],"check":[{"kind":"http","method":"POST","path":"/api/v1/users","body":{"email":"${ADMIN2_EMAIL}","display_name":"Acceptance Admin 2","role":"admin","password":"${ADMIN2_PASSWORD}"},"expect_status":[201,409]},{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${ADMIN2_EMAIL}","password":"${ADMIN2_PASSWORD}"},"expect_status":200,"save":{"SESSION_ADMIN2":"@cookie"}},{"kind":"http","method":"PATCH","path":"/api/v1/users/${ADMIN_ID}/disable","auth":"session:SESSION_ADMIN2","expect_status":409,"expect_json":{"error":"no_sso_admin_designated"}}]} -->

- **Before you start**: No SSO user is an admin yet.
- **Steps**: Create a second local admin with `ADMIN2_EMAIL`. As that admin, try to disable the bootstrap admin.
- **Expected**: HTTP 409 `no_sso_admin_designated`. The message says to make an SSO user an admin first.

### CAT-AUTH-24 Bootstrap admin is retired after SSO handover
<!-- cat: {"id":"CAT-AUTH-24","mode":"visual","requires":["sso"],"depends_on":["CAT-AUTH-11"],"destructive":true,"look_for":["As admin, Users lets you change the Entra user from CAT-AUTH-11 to admin","Signed in as that SSO admin, disabling the bootstrap admin asks for confirmation and then shows it as Disabled","Signing in with the bootstrap email and password now fails with account_disabled","The SSO admin can re-enable the bootstrap admin (break-glass path)"]} -->

- **Warning**: Disables the bootstrap admin. Before you start, confirm the SSO admin can sign in. At the end, agree with the client whether to turn the bootstrap admin back on as a break-glass account.
- **Steps**: Make the Entra user an admin. Sign in as that user. Disable the bootstrap admin. Try the bootstrap sign-in. Then agree the final state with the client.
- **Expected**: See `look_for`.

### CAT-AUTH-25 SSO enforcement blocks local passwords
<!-- cat: {"id":"CAT-AUTH-25","mode":"automatable","requires":["sso"],"depends_on":["CAT-AUTH-13","CAT-AUTH-24"],"check":[{"kind":"http","method":"PATCH","path":"/api/v1/settings/sso/enforce","body":{"enabled":true},"expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/auth/sso/status","auth":"none","expect_status":200,"expect_json":{"enforced":true}},{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${EDITOR_EMAIL}","password":"${EDITOR_PASSWORD}"},"expect_status":403},{"kind":"http","method":"PATCH","path":"/api/v1/settings/sso/enforce","body":{"enabled":false},"expect_status":200}]} -->

- **Before you start**: An SSO admin exists and can sign in.
- **Steps**: In **Admin, Sign-in**, find Enforcement. Turn on **Enforce SSO** and confirm. Try a local-password sign-in as the editor. Turn enforcement off again, unless the client wants it on.
- **Expected**: `sso/status` shows `enforced: true`. Users and Groups hide their local create buttons. The editor's local sign-in is refused with 403 `sso_required`. The one exception is a host that sets `DL_ALLOW_LOCAL_LOGIN=true`, the break-glass switch. Every such sign-in is logged as `local_login_break_glass`. Leave the switch unset for acceptance.

### CAT-AUTH-26 Sign-out ends the session
<!-- cat: {"id":"CAT-AUTH-26","mode":"automatable","depends_on":["CAT-AUTH-13"],"check":[{"kind":"http","method":"POST","path":"/api/v1/auth/logout","auth":"session:SESSION_EDITOR","expect_status":[200,204]},{"kind":"http","method":"POST","path":"/api/v1/auth/refresh","auth":"session:SESSION_EDITOR","expect_status":401}]} -->

- **Steps**: Sign out as the editor. Try to refresh the session with the old refresh cookie.
- **Expected**: Sign-out succeeds. The refresh returns 401. The browser returns to `/login`.

---

## 4. Secrets and vaults

DataLoader encrypts the SSO client secret, the Azure service principal secret and the bootstrap vault secret with the master key in the state volume. Store connection, destination and channel passwords in Azure Key Vault when you can, and refer to them as `kv://<vault>/<secret>`. Without Key Vault, DataLoader keeps those passwords in its database, encrypted.

The Key Vault cases are in the Azure section (CAT-AZ-01 to CAT-AZ-05). When the install uses Key Vault, run them before section 5.

### CAT-SEC-01 Stored admin secrets are write-only
<!-- cat: {"id":"CAT-SEC-01","mode":"automatable","requires":["sso"],"depends_on":["CAT-AUTH-08"],"check":{"kind":"http","method":"GET","path":"/api/v1/settings/sso","expect_status":200,"expect_json":{"client_secret_set":true}}} -->

- **Steps**: `GET /api/v1/settings/sso`. If the install uses Azure, also call `GET /api/v1/settings/azure` and `GET /api/v1/settings/compute-backend/sp-credentials`.
- **Expected**: Each response shows `client_secret_set: true` and no field with the secret value.

### CAT-SEC-02 Credentials never appear in logs
<!-- cat: {"id":"CAT-SEC-02","mode":"automatable","depends_on":["CAT-CONN-02"],"check":{"kind":"cli","run":"${COMPOSE} logs --no-color dataloader","expect_stdout_not_contains":["${ADMIN_PASSWORD}","${SECRET_PROBE}"]}} -->

- **Before you start**: Run this after sections 5 to 7, so the log holds connection tests and loads. `SECRET_PROBE` is the source password used in section 5.
- **Steps**: Search the full container log for the admin password and the source password.
- **Expected**: Neither string appears.

### CAT-SEC-03 Connection responses do not return passwords
<!-- cat: {"id":"CAT-SEC-03","mode":"automatable","depends_on":["CAT-CONN-02"],"check":{"kind":"http","method":"GET","path":"/api/v1/connections/${CONN_POSTGRES_ID}","expect_status":200,"expect_json":{"config_json.password":"*"},"expect_body_not_contains":["${SECRET_PROBE}"]}} -->

- **Steps**: `GET /api/v1/connections/${CONN_POSTGRES_ID}` and read `config_json`.
- **Expected**: Password fields hold a `kv://` reference or a masked value, never the plain password. Without Key Vault, the API returns `***` for a stored password.

### CAT-SEC-04 Secret fields are masked and offer Key Vault
<!-- cat: {"id":"CAT-SEC-04","mode":"visual","look_for":["Password and key fields on the connection, destination and channel forms are masked while typing","Each secret field offers Pick existing and Enter new when a vault is registered","With no vault registered, the field says in plain words that Key Vault is not set up","After saving and reopening the form, the secret is not shown in the page"]} -->

- **Steps**: Open **Connections, New connection**, pick Postgres, and look at the password field. Save a connection, reopen it, and look again. Repeat on a destination and on a notification channel.
- **Expected**: See `look_for`.

---
## 5. Connections

Run one create-and-test case for each source type the client uses. Mark the others N/A. `SRC_<TYPE>_CONFIG` holds the settings for that type. `GET /api/v1/connectors/types?role=source` lists the fields.

### CAT-CONN-01 Connector registry lists every 1.0 type
<!-- cat: {"id":"CAT-CONN-01","mode":"automatable","check":{"kind":"http","method":"GET","path":"/api/v1/connectors/types","auth":"none","expect_status":200,"expect_json":{"0.id":"*"}}} -->

- **Steps**: `GET /api/v1/connectors/types`.
- **Expected**: Sources `postgres`, `mssql`, `oracle`, `snowflake`, `clickhouse` and `iceberg` are listed. Destinations `postgres`, `snowflake`, `databricks` and `iceberg` are listed. Each has its fields. Secret fields have `secret: true`.

### CAT-CONN-02 Postgres source connects
<!-- cat: {"id":"CAT-CONN-02","mode":"automatable","requires":["src:postgres"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/connections/test","body":{"connection_key":"cat_src_postgres","display_name":"Acceptance Postgres source","db_type":"postgres","config_json":"${SRC_POSTGRES_CONFIG}"},"expect_status":200,"expect_json":{"is_healthy":true}},{"kind":"http","method":"POST","path":"/api/v1/connections","body":{"connection_key":"cat_src_postgres","display_name":"Acceptance Postgres source","db_type":"postgres","config_json":"${SRC_POSTGRES_CONFIG}"},"expect_status":201,"save":{"CONN_POSTGRES_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/connections/${CONN_POSTGRES_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Steps**: Open **Connections, New connection**, pick Postgres, fill in the fields, click **Test connection**, then save. The API is `POST /api/v1/connections/test`, `POST /api/v1/connections` and `POST /api/v1/connections/{id}/test`.
- **Expected**: Both tests return `is_healthy: true` with a time. The create returns 201.

### CAT-CONN-03 SQL Server source connects
<!-- cat: {"id":"CAT-CONN-03","mode":"automatable","requires":["src:mssql"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/connections","body":{"connection_key":"cat_src_mssql","display_name":"Acceptance SQL Server source","db_type":"mssql","config_json":"${SRC_MSSQL_CONFIG}"},"expect_status":201,"save":{"CONN_MSSQL_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/connections/${CONN_MSSQL_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Steps**: As in CAT-CONN-02, with type `mssql`.
- **Expected**: The test returns `is_healthy: true`.

### CAT-CONN-04 Oracle source connects
<!-- cat: {"id":"CAT-CONN-04","mode":"automatable","requires":["src:oracle"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/connections","body":{"connection_key":"cat_src_oracle","display_name":"Acceptance Oracle source","db_type":"oracle","config_json":"${SRC_ORACLE_CONFIG}"},"expect_status":201,"save":{"CONN_ORACLE_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/connections/${CONN_ORACLE_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Before you start**: The release image includes the Oracle client libraries. An image built without them (internal or demo builds) fails this test, and the message says so.
- **Steps**: As in CAT-CONN-02, with type `oracle`.
- **Expected**: The test returns `is_healthy: true`. If the client libraries are missing, the message says so.

### CAT-CONN-05 Snowflake source connects
<!-- cat: {"id":"CAT-CONN-05","mode":"automatable","requires":["src:snowflake"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/connections","body":{"connection_key":"cat_src_snowflake","display_name":"Acceptance Snowflake source","db_type":"snowflake","config_json":"${SRC_SNOWFLAKE_CONFIG}"},"expect_status":201,"save":{"CONN_SNOWFLAKE_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/connections/${CONN_SNOWFLAKE_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Steps**: As in CAT-CONN-02, with type `snowflake`.
- **Expected**: The test returns `is_healthy: true`.

### CAT-CONN-06 ClickHouse source connects
<!-- cat: {"id":"CAT-CONN-06","mode":"automatable","requires":["src:clickhouse"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/connections","body":{"connection_key":"cat_src_clickhouse","display_name":"Acceptance ClickHouse source","db_type":"clickhouse","config_json":"${SRC_CLICKHOUSE_CONFIG}"},"expect_status":201,"save":{"CONN_CLICKHOUSE_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/connections/${CONN_CLICKHOUSE_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Steps**: As in CAT-CONN-02, with type `clickhouse`.
- **Expected**: The test returns `is_healthy: true`.

### CAT-CONN-07 Iceberg source connects
<!-- cat: {"id":"CAT-CONN-07","mode":"automatable","requires":["src:iceberg"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/connections","body":{"connection_key":"cat_src_iceberg","display_name":"Acceptance Iceberg source","db_type":"iceberg","config_json":"${SRC_ICEBERG_CONFIG}"},"expect_status":201,"save":{"CONN_ICEBERG_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/connections/${CONN_ICEBERG_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Steps**: As in CAT-CONN-02, with type `iceberg`. The catalog is a REST catalog on S3 or Azure storage.
- **Expected**: The test returns `is_healthy: true`.

### CAT-CONN-08 Bad credentials give a readable failure
<!-- cat: {"id":"CAT-CONN-08","mode":"automatable","requires":["src:postgres"],"depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"POST","path":"/api/v1/connections/test","body":{"connection_key":"cat_src_badpw","display_name":"Bad password probe","db_type":"postgres","config_json":"${SRC_POSTGRES_BAD_CONFIG}"},"expect_status":[200,400],"expect_body_not_contains":["${SECRET_PROBE}"]}} -->

- **Steps**: Test a Postgres connection with a wrong password (`SRC_POSTGRES_BAD_CONFIG`).
- **Expected**: Either 200 with `is_healthy: false`, or 400 with an `error` that names the failed sign-in (Postgres answers 400, because it signs in while the connector is built). The server does not return 500 and does not repeat the password.

### CAT-CONN-09 Duplicate connection key is refused
<!-- cat: {"id":"CAT-CONN-09","mode":"automatable","requires":["src:postgres"],"depends_on":["CAT-CONN-02"],"check":{"kind":"http","method":"POST","path":"/api/v1/connections","body":{"connection_key":"cat_src_postgres","display_name":"Duplicate","db_type":"postgres","config_json":"${SRC_POSTGRES_CONFIG}"},"expect_status":409}} -->

- **Steps**: Create a second connection with the key `cat_src_postgres`.
- **Expected**: HTTP 409. The form shows the conflict next to the key field. It does not show an error page.

### CAT-CONN-10 Introspection lists tables and suggests columns
<!-- cat: {"id":"CAT-CONN-10","mode":"automatable","requires":["src:postgres"],"depends_on":["CAT-CONN-02"],"check":[{"kind":"http","method":"GET","path":"/api/v1/connections/${CONN_POSTGRES_ID}/introspect/schemas","expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/connections/${CONN_POSTGRES_ID}/introspect/tables?schema=${SRC_POSTGRES_SCHEMA}","expect_status":200,"expect_json":{"0.name":"*"}},{"kind":"http","method":"GET","path":"/api/v1/connections/${CONN_POSTGRES_ID}/introspect/columns?schema=${SRC_POSTGRES_SCHEMA}&table=${SRC_POSTGRES_TABLE}","expect_status":200,"expect_json":{"columns":"*","suggestions":"*"}}]} -->

- **Steps**: List the schemas. List the tables in `${SRC_POSTGRES_SCHEMA}`. List the columns of `${SRC_POSTGRES_TABLE}`.
- **Expected**: Each call returns 200. The test table is in the table list. The columns response has `columns` and `suggestions`, such as the time column, the key and the partition column.

### CAT-CONN-11 Connection form is easy to fill
<!-- cat: {"id":"CAT-CONN-11","mode":"visual","look_for":["The type dropdown lists every source type; changing type changes the fields","Fields are separate inputs (host, port, database, user), not one connection string by default","Test connection shows a clear pass or fail message in plain language","The list shows the new connection with a health indicator","Connection key cannot be changed after save"]} -->

- **Steps**: Create one connection in the app, then edit it once.
- **Expected**: See `look_for`.

---

## 6. Destinations

Run the case for each destination the client uses. `DEST_<TYPE>_CONFIG` holds the settings for that type.

### CAT-DEST-01 Postgres destination connects
<!-- cat: {"id":"CAT-DEST-01","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/destinations/test","body":{"destination_key":"cat_dest_postgres","display_name":"Acceptance Postgres destination","dest_type":"postgres","config_json":"${DEST_POSTGRES_CONFIG}"},"expect_status":200,"expect_json":{"is_healthy":true}},{"kind":"http","method":"POST","path":"/api/v1/destinations","body":{"destination_key":"cat_dest_postgres","display_name":"Acceptance Postgres destination","dest_type":"postgres","config_json":"${DEST_POSTGRES_CONFIG}"},"expect_status":201,"save":{"DEST_POSTGRES_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/destinations/${DEST_POSTGRES_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Steps**: In **Connections**, choose the Destinations filter. Click **New destination**, pick Postgres, fill in the fields, test, and save. The API is `POST /api/v1/destinations/test`, `POST /api/v1/destinations` and `POST /api/v1/destinations/{id}/test`.
- **Expected**: Both tests return `is_healthy: true`. The create returns 201.

### CAT-DEST-02 Databricks destination connects
<!-- cat: {"id":"CAT-DEST-02","mode":"automatable","requires":["dest:databricks"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/destinations","body":{"destination_key":"cat_dest_databricks","display_name":"Acceptance Databricks destination","dest_type":"databricks","config_json":"${DEST_DATABRICKS_CONFIG}"},"expect_status":201,"save":{"DEST_DATABRICKS_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/destinations/${DEST_DATABRICKS_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Before you start**: A running SQL warehouse, and a Unity Catalog schema the credentials can write to.
- **Steps**: As in CAT-DEST-01, with type `databricks`.
- **Expected**: The test returns `is_healthy: true`.

### CAT-DEST-03 Snowflake destination connects
<!-- cat: {"id":"CAT-DEST-03","mode":"automatable","requires":["dest:snowflake"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/destinations","body":{"destination_key":"cat_dest_snowflake","display_name":"Acceptance Snowflake destination","dest_type":"snowflake","config_json":"${DEST_SNOWFLAKE_CONFIG}"},"expect_status":201,"save":{"DEST_SNOWFLAKE_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/destinations/${DEST_SNOWFLAKE_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Steps**: As in CAT-DEST-01, with type `snowflake`.
- **Expected**: The test returns `is_healthy: true`.

### CAT-DEST-04 Iceberg destination connects
<!-- cat: {"id":"CAT-DEST-04","mode":"automatable","requires":["dest:iceberg"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/destinations","body":{"destination_key":"cat_dest_iceberg","display_name":"Acceptance Iceberg destination","dest_type":"iceberg","config_json":"${DEST_ICEBERG_CONFIG}"},"expect_status":201,"save":{"DEST_ICEBERG_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/destinations/${DEST_ICEBERG_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Steps**: As in CAT-DEST-01, with type `iceberg`.
- **Expected**: The test returns `is_healthy: true`.

### CAT-DEST-05 Default destination can be set
<!-- cat: {"id":"CAT-DEST-05","mode":"automatable","depends_on":["CAT-DEST-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/destinations/${DEST_DEFAULT_ID}/set-default","expect_status":204},{"kind":"http","method":"GET","path":"/api/v1/destinations/${DEST_DEFAULT_ID}","expect_status":200,"expect_json":{"is_default":true}}]} -->

- **Before you start**: `DEST_DEFAULT_ID` is the destination the client wants as the default, such as the saved Databricks destination.
- **Steps**: In **Admin, Default destination**, mark it as default. Or call `POST /api/v1/destinations/{id}/set-default`.
- **Expected**: The call returns 204. Only that destination has `is_default: true`. New table configs pre-select it.

### CAT-DEST-06 Destination form reads well
<!-- cat: {"id":"CAT-DEST-06","mode":"visual","look_for":["The destination form shows only the fields for the chosen type","Test shows a clear result and names the failing part (host, auth, warehouse, catalog)","The destinations list marks the default"]} -->

- **Steps**: Create or edit one destination in the app.
- **Expected**: See `look_for`.

---

## 7. Table configs and sample loads (Local mode)

Each load reads the source test table (`LOAD_SRC_*`, usually the Postgres source from CAT-CONN-02). It writes to one destination, and it runs inside the DataLoader container. That is Local mode.

Loads run in the TEST environment, which caps a run at 1,000 rows. Keep the source test table under 1,000 rows. Leave the TEST table prefix in **Settings, Workspace** empty, or add the prefix to the table names in the SQL checks.

These cases set `compute_mode` to `local`, so they do not need Azure. Fan-out is tested in section 9.

### CAT-LOAD-01 Table config saves with source preflight
<!-- cat: {"id":"CAT-LOAD-01","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-CONN-02","CAT-DEST-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${LOAD_SRC_ID}","destination_id":"${DEST_POSTGRES_ID}","environment":"test","source_schema":"${LOAD_SRC_SCHEMA}","source_table":"missing_table_cat","dest_schema":"${DEST_POSTGRES_SCHEMA}","dest_table":"cat_load_pg","load_strategy":"full","compute_mode":"local"},"expect_status":422,"expect_json":{"validation.field":"source_table"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${LOAD_SRC_ID}","destination_id":"${DEST_POSTGRES_ID}","environment":"test","source_schema":"${LOAD_SRC_SCHEMA}","source_table":"${LOAD_SRC_TABLE}","dest_schema":"${DEST_POSTGRES_SCHEMA}","dest_table":"cat_load_pg","load_strategy":"full","compute_mode":"local"},"expect_status":201,"save":{"TC_PG_ID":"id"}}]} -->

- **Steps**: Try to save a table config that names a table that does not exist. Then save one for the real test table.
- **Expected**: The first save returns 422, with `validation.field` `source_table` and suggested names. The second returns 201.

### CAT-LOAD-02 Load to Postgres succeeds
<!-- cat: {"id":"CAT-LOAD-02","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-LOAD-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_PG_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_PG_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_PG_ID}","expect_status":200,"expect_json":{"run.status":"succeeded","run.rows_written":"${LOAD_SRC_ROWS}"},"retry":{"every_s":5,"for_s":600}}]} -->

- **Steps**: Click **Run now** on the table config (TEST). Or call `POST /api/v1/table-configs/{id}/run` with `{"env":"test"}`. Watch **Runs** until the run finishes.
- **Expected**: 202 with a `run_id`. The run goes queued, running, then succeeded. `run.rows_written` equals the source row count.

### CAT-LOAD-03 Rows landed in Postgres
<!-- cat: {"id":"CAT-LOAD-03","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-LOAD-02"],"check":{"kind":"sql","target":"DEST_POSTGRES_DSN","query":"SELECT count(*) FROM ${DEST_POSTGRES_SCHEMA}.cat_load_pg","expect_scalar":"${LOAD_SRC_ROWS}"}} -->

- **Steps**: Query the destination table.
- **Expected**: The count equals the source row count. Spot-check a few rows against the source.

### CAT-LOAD-04 Load to Databricks succeeds
<!-- cat: {"id":"CAT-LOAD-04","mode":"automatable","requires":["dest:databricks"],"depends_on":["CAT-CONN-02","CAT-DEST-02"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${LOAD_SRC_ID}","destination_id":"${DEST_DATABRICKS_ID}","environment":"test","source_schema":"${LOAD_SRC_SCHEMA}","source_table":"${LOAD_SRC_TABLE}","dest_catalog":"${DEST_DATABRICKS_CATALOG}","dest_schema":"${DEST_DATABRICKS_SCHEMA}","dest_table":"cat_load_dbx","load_strategy":"full","compute_mode":"local"},"expect_status":201,"save":{"TC_DBX_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_DBX_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_DBX_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_DBX_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":10,"for_s":900}}]} -->

- **Steps**: Create a table config to Databricks. Run it in TEST.
- **Expected**: The run succeeds. Allow extra time if the SQL warehouse is starting.

### CAT-LOAD-05 Rows landed in Databricks
<!-- cat: {"id":"CAT-LOAD-05","mode":"automatable","requires":["dest:databricks"],"depends_on":["CAT-LOAD-04"],"check":{"kind":"sql","target":"DEST_DATABRICKS_DSN","query":"SELECT count(*) FROM ${DEST_DATABRICKS_CATALOG}.${DEST_DATABRICKS_SCHEMA}.cat_load_dbx","expect_scalar":"${LOAD_SRC_ROWS}"}} -->

- **Steps**: Query the table in a Databricks SQL editor.
- **Expected**: The count equals the source row count.

### CAT-LOAD-06 Load to Snowflake succeeds
<!-- cat: {"id":"CAT-LOAD-06","mode":"automatable","requires":["dest:snowflake"],"depends_on":["CAT-CONN-02","CAT-DEST-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${LOAD_SRC_ID}","destination_id":"${DEST_SNOWFLAKE_ID}","environment":"test","source_schema":"${LOAD_SRC_SCHEMA}","source_table":"${LOAD_SRC_TABLE}","dest_catalog":"${DEST_SNOWFLAKE_CATALOG}","dest_schema":"${DEST_SNOWFLAKE_SCHEMA}","dest_table":"CAT_LOAD_SF","load_strategy":"full","compute_mode":"local"},"expect_status":201,"save":{"TC_SF_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_SF_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_SF_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_SF_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":10,"for_s":900}}]} -->

- **Steps**: Create a table config to Snowflake. Run it in TEST.
- **Expected**: The run succeeds.

### CAT-LOAD-07 Rows landed in Snowflake
<!-- cat: {"id":"CAT-LOAD-07","mode":"automatable","requires":["dest:snowflake"],"depends_on":["CAT-LOAD-06"],"check":{"kind":"sql","target":"DEST_SNOWFLAKE_DSN","query":"SELECT count(*) FROM ${DEST_SNOWFLAKE_CATALOG}.${DEST_SNOWFLAKE_SCHEMA}.CAT_LOAD_SF","expect_scalar":"${LOAD_SRC_ROWS}"}} -->

- **Steps**: Query the table in Snowflake.
- **Expected**: The count equals the source row count.

### CAT-LOAD-08 Load to Iceberg succeeds
<!-- cat: {"id":"CAT-LOAD-08","mode":"automatable","requires":["dest:iceberg"],"depends_on":["CAT-CONN-02","CAT-DEST-04"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${LOAD_SRC_ID}","destination_id":"${DEST_ICEBERG_ID}","environment":"test","source_schema":"${LOAD_SRC_SCHEMA}","source_table":"${LOAD_SRC_TABLE}","dest_catalog":"${DEST_ICEBERG_CATALOG}","dest_schema":"${DEST_ICEBERG_SCHEMA}","dest_table":"cat_load_ice","load_strategy":"append_only","compute_mode":"local"},"expect_status":201,"save":{"TC_ICE_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_ICE_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_ICE_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_ICE_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":10,"for_s":900}}]} -->

- **Steps**: Create a table config to Iceberg with strategy `append_only`, then run it.
- **Expected**: The run succeeds.

### CAT-LOAD-09 Rows landed in Iceberg
<!-- cat: {"id":"CAT-LOAD-09","mode":"automatable","requires":["dest:iceberg"],"depends_on":["CAT-LOAD-08"],"check":{"kind":"sql","target":"DEST_ICEBERG_DSN","query":"SELECT count(*) FROM ${DEST_ICEBERG_CATALOG}.${DEST_ICEBERG_SCHEMA}.cat_load_ice","expect_scalar":"${LOAD_SRC_ROWS}"}} -->

- **Steps**: Query the table with the client's Iceberg tool, such as Spark, Trino, DuckDB or Snowflake.
- **Expected**: The count equals the source row count.

### CAT-LOAD-10 Incremental load picks up only new rows
<!-- cat: {"id":"CAT-LOAD-10","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-CONN-02","CAT-DEST-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${LOAD_SRC_ID}","destination_id":"${DEST_POSTGRES_ID}","environment":"test","source_schema":"${LOAD_SRC_SCHEMA}","source_table":"${LOAD_SRC_TABLE}","dest_schema":"${DEST_POSTGRES_SCHEMA}","dest_table":"cat_load_pg_inc","load_strategy":"incremental","incremental_column":"${LOAD_SRC_WATERMARK}","incremental_type":"timestamp","primary_key_columns":"${LOAD_SRC_PK_JSON}","compute_mode":"local"},"expect_status":201,"save":{"TC_INC_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_INC_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_INC1_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_INC1_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":5,"for_s":600}},{"kind":"sql","target":"LOAD_SRC_DSN","query":"${LOAD_SRC_INSERT_SQL}"},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_INC_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_INC2_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_INC2_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":5,"for_s":600}},{"kind":"sql","target":"DEST_POSTGRES_DSN","query":"SELECT count(*) FROM ${DEST_POSTGRES_SCHEMA}.cat_load_pg_inc","expect_min":"${LOAD_SRC_ROWS}"}]} -->

- **Before you start**: The source test table has a primary key and an updated-at timestamp column. `LOAD_SRC_INSERT_SQL` adds one new row with the current timestamp.
- **Steps**: Create an incremental config and run it. Insert one row in the source. Run it again.
- **Expected**: Both runs succeed. The second run writes only the new row, plus any rows in the 12-hour lookback window. The destination has one more row than after the first run, and no duplicate keys.

### CAT-LOAD-11 TEST row cap applies
<!-- cat: {"id":"CAT-LOAD-11","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-LOAD-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_PG_ID}/run","body":{"env":"test","row_limit_override":10},"expect_status":202,"expect_json":{"row_limit":10},"save":{"RUN_CAP_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_CAP_ID}","expect_status":200,"expect_json":{"run.status":"succeeded","run.rows_written":10},"retry":{"every_s":5,"for_s":600}}]} -->

- **Before you start**: The source test table has more than 10 rows.
- **Steps**: Run the Postgres config in TEST with a row limit of 10.
- **Expected**: The run shows `row_limit` 10 and writes 10 rows.

### CAT-LOAD-12 A second run while one is active is refused
<!-- cat: {"id":"CAT-LOAD-12","mode":"visual","depends_on":["CAT-LOAD-01"],"look_for":["Clicking Run now twice quickly starts one run","The second click shows a message that a run is already active (HTTP 409), not an error page"]} -->

- **Steps**: Click **Run now** twice in quick succession on a config whose run takes more than a few seconds.
- **Expected**: See `look_for`.

### CAT-LOAD-13 Each configured source loads
<!-- cat: {"id":"CAT-LOAD-13","mode":"visual","look_for":["For every source type from section 5 other than the load source, one table config runs to succeeded","Row counts in the destination match the source test table","Failures show a readable error on the run detail page"]} -->

- **Steps**: For each other configured source, create a table config to the default destination. Run it once in TEST.
- **Expected**: See `look_for`. Record each source type and run ID as evidence.

### CAT-LOAD-14 Table config form helps the user
<!-- cat: {"id":"CAT-LOAD-14","mode":"visual","look_for":["Source catalog, schema and table are dropdowns filled from the connection","The destination catalog and schema default from the workspace or connection, marked as defaults","Watermark, primary key and partition fields show suggested columns with a reason","Quick start fills a sensible strategy","Custom query mode has a SQL editor with a Format button"]} -->

- **Steps**: In the app, create a new table config against the Postgres source.
- **Expected**: See `look_for`.

---

## 8. Schedules and sensors

The scheduler runs any active table config that has a cron schedule. Sensors check on a regular tick (60 seconds by default), or they fire when a webhook is called.

### CAT-SCHED-01 Cron expressions are validated
<!-- cat: {"id":"CAT-SCHED-01","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/cron/validate","body":{"expression":"*/5 * * * *","timezone":"America/Denver"},"expect_status":200,"expect_json":{"valid":true,"next_runs":"*"}},{"kind":"http","method":"POST","path":"/api/v1/cron/validate","body":{"expression":"not a cron"},"expect_status":200,"expect_json":{"valid":false}}]} -->

- **Steps**: Validate `*/5 * * * *` in `America/Denver`. Then validate an invalid expression.
- **Expected**: The first returns `valid: true`, a description and the next five run times. The second returns `valid: false` with an error.

### CAT-SCHED-02 Schedule is saved and listed
<!-- cat: {"id":"CAT-SCHED-02","mode":"automatable","depends_on":["CAT-LOAD-01"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_PG_ID}","body":{"cron_schedule":"*/5 * * * *","cron_timezone":"${CRON_TZ}"},"expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/dashboard/schedule-overview?limit=3","expect_status":200,"expect_json_contains":{"@body":"${TC_PG_ID}"}}]} -->

- **Steps**: On the Postgres table config, set the schedule to every 5 minutes in the client's time zone, and save. Open **Automation, Schedule**.
- **Expected**: The save returns 200. The schedule overview lists the config with its next run times, shown in the chosen time zone.

### CAT-SCHED-03 Scheduled run fires
<!-- cat: {"id":"CAT-SCHED-03","mode":"automatable","depends_on":["CAT-SCHED-02"],"check":{"kind":"http","method":"GET","path":"/api/v1/execution-runs?env=test&table_config_id=${TC_PG_ID}&trigger_type=cron","expect_status":200,"expect_json":{"runs.0.status":"succeeded"},"retry":{"every_s":30,"for_s":600}}} -->

- **Steps**: Wait up to 10 minutes. List the runs for the config with trigger type `cron`.
- **Expected**: At least one `cron` run has succeeded. It appears in **Runs** without a page reload.

### CAT-SCHED-04 Schedule can be removed
<!-- cat: {"id":"CAT-SCHED-04","mode":"automatable","depends_on":["CAT-SCHED-02"],"check":{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_PG_ID}","body":{"cron_schedule":""},"expect_status":200}} -->

- **Steps**: Clear the schedule and save.
- **Expected**: 200. No new `cron` runs appear for this config after the next 5-minute mark.

### CAT-SENS-01 Sensor types are listed
<!-- cat: {"id":"CAT-SENS-01","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"GET","path":"/api/v1/sensors/types","expect_status":200,"expect_json":{"0.id":"*"}}} -->

- **Steps**: `GET /api/v1/sensors/types`.
- **Expected**: `file_watch`, `webhook`, `api_poll`, `db_change` and `row_count_change` are listed, with their fields. Only `webhook` is event-driven.

### CAT-SENS-02 Webhook sensor triggers a load
<!-- cat: {"id":"CAT-SENS-02","mode":"automatable","depends_on":["CAT-LOAD-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/sensors","body":{"name":"cat-webhook","sensor_type":"webhook","config_json":{"path":"cat-acceptance","secret":"${WEBHOOK_SECRET}"},"trigger_table_ids":["${TC_PG_ID}"]},"expect_status":201,"save":{"SENSOR_WH_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/webhooks/cat-acceptance","auth":"none","headers":{"X-Dataloader-Secret":"${WEBHOOK_SECRET}"},"body":{},"expect_status":202,"expect_json":{"enqueued":1},"retry":{"every_s":10,"for_s":180}},{"kind":"http","method":"GET","path":"/api/v1/execution-runs?env=test&table_config_id=${TC_PG_ID}&trigger_type=sensor","expect_status":200,"expect_json":{"runs.0.status":"succeeded"},"retry":{"every_s":10,"for_s":600}}]} -->

- **Steps**: Create a webhook sensor on path `cat-acceptance` that triggers the Postgres table config. Wait for one sensor tick. Then call `POST ${PUBLIC_URL}/api/v1/webhooks/cat-acceptance` with the header `X-Dataloader-Secret`.
- **Expected**: The webhook returns 202 with `enqueued: 1`. A `sensor` run succeeds. Until the first tick after creation, the path returns 404. That is expected.

### CAT-SENS-03 Webhook with a wrong secret is refused
<!-- cat: {"id":"CAT-SENS-03","mode":"automatable","depends_on":["CAT-SENS-02"],"check":[{"kind":"http","method":"POST","path":"/api/v1/webhooks/cat-acceptance","auth":"none","headers":{"X-Dataloader-Secret":"wrong"},"body":{},"expect_status":401},{"kind":"http","method":"POST","path":"/api/v1/webhooks/no-such-path-cat","auth":"none","headers":{"X-Dataloader-Secret":"${WEBHOOK_SECRET}"},"body":{},"expect_status":404}]} -->

- **Steps**: Call the webhook with a wrong secret. Then call a path that does not exist.
- **Expected**: 401 for the wrong secret and 404 for the unknown path. No run is queued.

### CAT-SENS-04 Row-count sensor fires on a source change
<!-- cat: {"id":"CAT-SENS-04","mode":"automatable","depends_on":["CAT-LOAD-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/sensors","body":{"name":"cat-rowcount","sensor_type":"row_count_change","config_json":{"connection_id":"${LOAD_SRC_ID}","table":"${LOAD_SRC_SCHEMA}.${LOAD_SRC_TABLE}","threshold_pct":0},"trigger_table_ids":["${TC_PG_ID}"]},"expect_status":201,"save":{"SENSOR_RC_ID":"id"}},{"kind":"http","method":"GET","path":"/api/v1/sensors/${SENSOR_RC_ID}/ticks?limit=5","expect_status":200,"expect_json":{"ticks.0.status":"*"},"retry":{"every_s":15,"for_s":180}},{"kind":"sql","target":"LOAD_SRC_DSN","query":"${LOAD_SRC_INSERT_SQL}"},{"kind":"http","method":"GET","path":"/api/v1/sensors/${SENSOR_RC_ID}/ticks?limit=1","expect_status":200,"expect_json":{"ticks.0.status":"triggered"},"retry":{"every_s":15,"for_s":300}}]} -->

- **Steps**: Create a `row_count_change` sensor on the source test table. Wait for the first tick, which records the starting count and does not fire. Insert a row in the source. Wait for the next tick.
- **Expected**: The latest tick has status `triggered` and `runs_requested` 1. A `sensor` run for the Postgres config follows.

### CAT-SENS-05 Sensors can be paused and deleted
<!-- cat: {"id":"CAT-SENS-05","mode":"automatable","depends_on":["CAT-SENS-02","CAT-SENS-04"],"destructive":true,"check":[{"kind":"http","method":"PUT","path":"/api/v1/sensors/${SENSOR_RC_ID}","body":{"is_active":false},"expect_status":200},{"kind":"http","method":"DELETE","path":"/api/v1/sensors/${SENSOR_RC_ID}","expect_status":[200,204]},{"kind":"http","method":"DELETE","path":"/api/v1/sensors/${SENSOR_WH_ID}","expect_status":[200,204]}]} -->

- **Warning**: Deletes the two acceptance sensors and their tick history.
- **Steps**: Pause the row-count sensor. Delete both acceptance sensors.
- **Expected**: Each call succeeds, and the sensors leave the list.

### CAT-SENS-06 Sensor dialog behaves
<!-- cat: {"id":"CAT-SENS-06","mode":"visual","look_for":["New sensor opens a centered dialog with a backdrop","Escape and a backdrop click close it; Tab stays inside it; focus returns to the button on close","Choosing a type changes the fields; secret fields offer Key Vault","Switch to JSON round-trips without losing input","Each sensor row shows its last evaluation and status"]} -->

- **Steps**: Open **Automation, Sensors, New sensor**. Try each type without saving. Then look at the list.
- **Expected**: See `look_for`.

---
## 9. Azure resources and fan-out

**Applies only when the install uses Azure.** On a Linux host with no Azure parts, skip this whole section and record N/A. Every case here has `requires: ["azure"]`.

Set up these Azure parts before this section, with the Azure setup runbook ([step 0](client-azure-identity-vault-sso-databricks.md#0-provision-the-azure-resources-with-one-command)) or by hand:

- A Key Vault with role-based access.
- A service principal with rights on the vault and on the DataLoader resource group.
- A user-assigned managed identity that can pull images from the registry (`AcrPull`).
- The `dataloader-worker` image in the registry.
- An Azure Container Apps environment.
- A Container Apps Job named `shared`.

The Job name is fixed in 1.0, and DataLoader does not create the Job. The setup script creates it. Without the script, the SI creates it by hand. Fan-out cases fail until a Job named `shared` exists.

Fan-out splits a large table into partitions. Each partition runs as an execution of the `shared` Job. Workers report back to the callback base URL, which Azure must be able to reach. In 1.0, fan-out works for Postgres, Databricks and Snowflake destinations. Iceberg destinations always run in Local mode.

When connections use Key Vault, run the Key Vault cases (CAT-AZ-01 to CAT-AZ-05) before section 5.

### CAT-AZ-01 Key Vault registers
<!-- cat: {"id":"CAT-AZ-01","mode":"automatable","requires":["azure"],"depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"POST","path":"/api/v1/vaults","body":{"name":"${AZ_KV_NAME}","uri":"${AZ_KV_URI}","env_tag":"both","sp_tenant_id":"${AZ_TENANT_ID}","sp_client_id":"${AZ_SP_CLIENT_ID}","sp_secret_inline":"${AZ_SP_CLIENT_SECRET}"},"expect_status":201,"expect_json":{"is_bootstrap":true},"save":{"VAULT_ID":"id"}}} -->

- **Steps**: Open **Admin, Key vaults**, then **Register vault**. The Overview's Key Vault step opens the same page. Enter the vault name, the URI (`https://<name>.vault.azure.net/`), environment `both`, and the service principal. The API is `POST /api/v1/vaults`.
- **Expected**: 201. The vault appears in the list. The response does not contain the service principal secret. A second vault with the same name returns 409 `name_already_exists`. If this vault is already registered, take its `id` from `GET /api/v1/vaults` as `VAULT_ID`, and record the case as Pass.

### CAT-AZ-02 Key Vault test passes
<!-- cat: {"id":"CAT-AZ-02","mode":"automatable","requires":["azure"],"depends_on":["CAT-AZ-01"],"check":{"kind":"http","method":"POST","path":"/api/v1/vaults/${VAULT_ID}/test","expect_status":200,"expect_json":{"ok":true,"secret_count":"*"}}} -->

- **Steps**: Click **Test** on the vault row, or call `POST /api/v1/vaults/{id}/test`.
- **Expected**: `ok: true` and a secret count. A failure gives `ok: false` and a plain message, such as a missing list permission.

### CAT-AZ-03 DataLoader writes a secret to Key Vault
<!-- cat: {"id":"CAT-AZ-03","mode":"automatable","requires":["azure"],"depends_on":["CAT-AZ-01"],"check":{"kind":"http","method":"POST","path":"/api/v1/secrets","body":{"vault_name":"${AZ_KV_NAME}","secret_name":"cat-acceptance-probe","value":"${AZ_KV_PROBE_VALUE}"},"expect_status":[200,201],"expect_json":{"kv_uri":"*"},"save":{"KV_PROBE_URI":"kv_uri"}}} -->

- **Steps**: Call `POST /api/v1/secrets` with a probe value. In the app, the same happens when a secret field uses **Enter new**.
- **Expected**: The response has a `kv_uri` like `kv://<vault>/cat-acceptance-probe` and no value. The secret shows in the Azure portal.

### CAT-AZ-04 Secrets can be listed for picking
<!-- cat: {"id":"CAT-AZ-04","mode":"automatable","requires":["azure"],"depends_on":["CAT-AZ-03"],"check":{"kind":"http","method":"GET","path":"/api/v1/secrets/list?vault_name=${AZ_KV_NAME}","expect_status":200,"expect_json_contains":{"@body":"cat-acceptance-probe"}}} -->

- **Steps**: `GET /api/v1/secrets/list?vault_name=${AZ_KV_NAME}`.
- **Expected**: The list includes `cat-acceptance-probe` with its `kv_uri`. It shows no secret values.

### CAT-AZ-05 A connection resolves its password from Key Vault
<!-- cat: {"id":"CAT-AZ-05","mode":"automatable","requires":["azure","src:postgres"],"depends_on":["CAT-AZ-01"],"check":{"kind":"http","method":"POST","path":"/api/v1/connections/test","body":{"connection_key":"cat_src_postgres_kv","display_name":"Postgres via Key Vault","db_type":"postgres","config_json":"${SRC_POSTGRES_KV_CONFIG}"},"expect_status":200,"expect_json":{"is_healthy":true}}} -->

- **Before you start**: The source password is in the vault. `SRC_POSTGRES_KV_CONFIG` holds the Postgres settings, with `password` set to its `kv://` reference.
- **Steps**: Test a Postgres connection whose password is a `kv://` reference.
- **Expected**: `is_healthy: true`. The saved connection holds the `kv://` reference, not the password.

### CAT-AZ-06 Fan-out sign-in is configured for the host
<!-- cat: {"id":"CAT-AZ-06","mode":"automatable","requires":["azure"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/settings/compute-backend/sp-credentials","body":{"tenant_id":"${AZ_TENANT_ID}","client_id":"${AZ_SP_CLIENT_ID}","client_secret":"${AZ_SP_CLIENT_SECRET}","sign_in":"service_principal"},"expect_status":200,"expect_json":{"ok":true,"client_secret_set":true}},{"kind":"http","method":"GET","path":"/api/v1/settings/compute-backend/sp-credentials","expect_status":200,"expect_json":{"client_id":"${AZ_SP_CLIENT_ID}","client_secret_set":true,"sign_in":"service_principal"}}]} -->

- **Before you start**: Run this fallback check when DataLoader runs on a host outside Azure, or when an install keeps an existing saved service principal choice. Hosts with a managed identity use that identity by default; check that path in CAT-AZ-17.
- **Steps**: In **Admin, Compute and fan-out**, select **Service principal secret** and enter the tenant ID, client ID and secret. Or call `PUT /api/v1/settings/compute-backend/sp-credentials` with `sign_in: "service_principal"`.
- **Expected**: The saved service principal is selected. The GET returns the client ID and `client_secret_set: true`, never the secret itself.

### CAT-AZ-07 Compute backend coordinates are stored
<!-- cat: {"id":"CAT-AZ-07","mode":"automatable","requires":["azure"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/settings/compute-backend","body":{"subscription_id":"${AZ_SUBSCRIPTION_ID}","resource_group":"${AZ_RG}","managed_identity_client_id":"${AZ_MI_CLIENT_ID}","container_image_tag":"${AZ_WORKER_TAG}","container_registry_url":"${AZ_ACR_LOGIN_SERVER}"},"expect_status":200},{"kind":"http","method":"PATCH","path":"/api/v1/settings/runtime","body":{"aca_subscription_id":"${AZ_SUBSCRIPTION_ID}","aca_resource_group":"${AZ_RG}","aca_environment_id":"${AZ_ACA_ENV_ID}","aca_worker_image":"${AZ_ACR_LOGIN_SERVER}/dataloader-worker:${AZ_WORKER_TAG}","aca_managed_identity_resource_id":"${AZ_MI_RESOURCE_ID}"},"expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/settings/compute-backend","expect_status":200,"expect_json":{"configured":true,"resource_group":"${AZ_RG}"}}]} -->

- **Steps**: Save the subscription, resource group, managed identity client ID, worker image tag and registry. Save the Container Apps settings with `PATCH /api/v1/settings/runtime`.
- **Expected**: Both calls return 200. `GET /api/v1/settings/compute-backend` shows `configured: true` and the saved values. A registry URL without `.azurecr.io` returns 422.

### CAT-AZ-08 Managed identity and registry pull are verified
<!-- cat: {"id":"CAT-AZ-08","mode":"automatable","requires":["azure"],"depends_on":["CAT-AZ-06","CAT-AZ-07"],"check":{"kind":"http","method":"POST","path":"/api/v1/settings/compute-backend/test","expect_status":200,"expect_json":{"ok":true}}} -->

- **Steps**: Click **Test** on the compute backend panel, or call `POST /api/v1/settings/compute-backend/test`.
- **Expected**: `ok: true`. The managed identity exists in the resource group and can pull from the registry. A failure names what is missing.

### CAT-AZ-09 Worker image and Job exist in Azure
<!-- cat: {"id":"CAT-AZ-09","mode":"automatable","requires":["azure"],"known_issue":"#1452","check":[{"kind":"cli","run":"az acr repository show-tags -n ${AZ_ACR_NAME} --repository dataloader-worker -o tsv","expect_stdout_contains":"${AZ_WORKER_TAG}"},{"kind":"cli","run":"az containerapp job show -n shared -g ${AZ_RG} --query name -o tsv","expect_stdout_contains":"shared"}]} -->

- **Before you start**: Run `az login` on the machine that runs the check. The login needs read access to the resource group.
- **Steps**: List the worker image tags in the registry. Show the `shared` Job.
- **Expected**: The tag `${AZ_WORKER_TAG}` exists, and it matches the major and minor version of the DataLoader install. The Job `shared` exists in `${AZ_RG}`. Known issue: DataLoader does not create this Job, so this case fails until the setup script or the SI has created a Job named `shared`.

### CAT-AZ-10 Callback URL is reachable from outside the host
<!-- cat: {"id":"CAT-AZ-10","mode":"automatable","requires":["azure"],"check":{"kind":"cli","run":"curl -fsS -o /dev/null -w '%{http_code}' ${AZ_CALLBACK_BASE}/api/v1/health","expect_stdout_contains":"200"}} -->

- **Steps**: From a machine outside the client network, or from Azure Cloud Shell, call `${AZ_CALLBACK_BASE}/api/v1/health`.
- **Expected**: HTTP 200. Workers cannot report back without this.

### CAT-AZ-11 Fan-out is wired at boot
<!-- cat: {"id":"CAT-AZ-11","mode":"automatable","requires":["azure"],"destructive":true,"depends_on":["CAT-AZ-06","CAT-AZ-07"],"check":[{"kind":"cli","run":"grep -q '^DL_FANOUT_CALLBACK_BASE=' ${INSTALL_DIR}/.env"},{"kind":"cli","run":"${COMPOSE} up -d --force-recreate dataloader"},{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"retry":{"every_s":5,"for_s":120}},{"kind":"cli","run":"${COMPOSE} logs --no-color --since 5m dataloader","expect_stdout_contains":"fan-out dispatch wired","expect_stdout_not_contains":"staying in fall-back-to-Local mode"}]} -->

- **Warning**: Recreates the container. Runs in progress stop.
- **Steps**: Set `DL_FANOUT_CALLBACK_BASE=${AZ_CALLBACK_BASE}` in `.env`. Recreate the container. Read the start-up log. Sign in again afterwards (CAT-AUTH-03).
- **Expected**: The log shows `fan-out dispatch wired`, with the image and callback URL. It does not show `staying in fall-back-to-Local mode`. If it does, that line names the missing setting.

### CAT-AZ-12 Large table fans out to a Postgres destination
<!-- cat: {"id":"CAT-AZ-12","mode":"automatable","requires":["azure","dest:postgres"],"known_issue":"#1452","depends_on":["CAT-AZ-11","CAT-DEST-01"],"check":[{"kind":"http","method":"PATCH","path":"/api/v1/settings/runtime","body":{"fan_out_threshold":"${FANOUT_THRESHOLD}","max_containers":4},"expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${FANOUT_SRC_ID}","destination_id":"${DEST_POSTGRES_ID}","environment":"test","source_schema":"${FANOUT_SRC_SCHEMA}","source_table":"${FANOUT_SRC_TABLE}","dest_schema":"${DEST_POSTGRES_SCHEMA}","dest_table":"cat_fanout_pg","load_strategy":"full","partition_column":"${FANOUT_PARTITION_COLUMN}","compute_mode":"auto"},"expect_status":201,"save":{"TC_FO_PG_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_FO_PG_ID}/run","body":{"env":"test","row_limit_override":"${FANOUT_SRC_ROWS}"},"expect_status":202,"save":{"RUN_FO_PG_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_FO_PG_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":15,"for_s":1800}},{"kind":"cli","run":"[ \"$(az containerapp job execution list -n shared -g ${AZ_RG} --query 'length(@)' -o tsv)\" -ge 2 ]"},{"kind":"sql","target":"DEST_POSTGRES_DSN","query":"SELECT count(*) FROM ${DEST_POSTGRES_SCHEMA}.cat_fanout_pg","expect_scalar":"${FANOUT_SRC_ROWS}"}]} -->

- **Before you start**: A source table with more rows than `FANOUT_THRESHOLD`, and an integer partition column. Lowering the threshold, for example to 100000, is fine for acceptance. Restore it afterwards.
- **Steps**: Lower the workspace fan-out threshold. Create a table config with compute mode `auto` and a partition column. Run it. Watch the `shared` Job executions in the Azure portal.
- **Expected**: Two or more Job executions start and finish. The run succeeds. The destination row count equals the source row count, with no duplicates. Known issue: dispatch always targets a Job named `shared`. Without that Job, the run fails at dispatch.

### CAT-AZ-13 Fan-out to a Databricks destination
<!-- cat: {"id":"CAT-AZ-13","mode":"automatable","requires":["azure","dest:databricks"],"known_issue":"#1452","depends_on":["CAT-AZ-12","CAT-DEST-02"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${FANOUT_SRC_ID}","destination_id":"${DEST_DATABRICKS_ID}","environment":"test","source_schema":"${FANOUT_SRC_SCHEMA}","source_table":"${FANOUT_SRC_TABLE}","dest_catalog":"${DEST_DATABRICKS_CATALOG}","dest_schema":"${DEST_DATABRICKS_SCHEMA}","dest_table":"cat_fanout_dbx","load_strategy":"full","partition_column":"${FANOUT_PARTITION_COLUMN}","compute_mode":"auto"},"expect_status":201,"save":{"TC_FO_DBX_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_FO_DBX_ID}/run","body":{"env":"test","row_limit_override":"${FANOUT_SRC_ROWS}"},"expect_status":202,"save":{"RUN_FO_DBX_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_FO_DBX_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":15,"for_s":1800}},{"kind":"sql","target":"DEST_DATABRICKS_DSN","query":"SELECT count(*) FROM ${DEST_DATABRICKS_CATALOG}.${DEST_DATABRICKS_SCHEMA}.cat_fanout_dbx","expect_scalar":"${FANOUT_SRC_ROWS}"}]} -->

- **Steps**: As in CAT-AZ-12, with the Databricks destination.
- **Expected**: The run succeeds through Job executions, and the row count matches. Known issue: as in CAT-AZ-12.

### CAT-AZ-14 Fan-out to a Snowflake destination
<!-- cat: {"id":"CAT-AZ-14","mode":"automatable","requires":["azure","dest:snowflake"],"known_issue":"#1452","depends_on":["CAT-AZ-12","CAT-DEST-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${FANOUT_SRC_ID}","destination_id":"${DEST_SNOWFLAKE_ID}","environment":"test","source_schema":"${FANOUT_SRC_SCHEMA}","source_table":"${FANOUT_SRC_TABLE}","dest_catalog":"${DEST_SNOWFLAKE_CATALOG}","dest_schema":"${DEST_SNOWFLAKE_SCHEMA}","dest_table":"CAT_FANOUT_SF","load_strategy":"full","partition_column":"${FANOUT_PARTITION_COLUMN}","compute_mode":"auto"},"expect_status":201,"save":{"TC_FO_SF_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_FO_SF_ID}/run","body":{"env":"test","row_limit_override":"${FANOUT_SRC_ROWS}"},"expect_status":202,"save":{"RUN_FO_SF_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_FO_SF_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":15,"for_s":1800}},{"kind":"sql","target":"DEST_SNOWFLAKE_DSN","query":"SELECT count(*) FROM ${DEST_SNOWFLAKE_CATALOG}.${DEST_SNOWFLAKE_SCHEMA}.CAT_FANOUT_SF","expect_scalar":"${FANOUT_SRC_ROWS}"}]} -->

- **Steps**: As in CAT-AZ-12, with the Snowflake destination.
- **Expected**: The run succeeds through Job executions, and the row count matches. Known issue: as in CAT-AZ-12.

### CAT-AZ-15 Iceberg destination stays in Local mode with a warning
<!-- cat: {"id":"CAT-AZ-15","mode":"visual","requires":["azure","dest:iceberg"],"known_issue":"#1416","depends_on":["CAT-AZ-11","CAT-DEST-04"],"look_for":["A table config to Iceberg above the fan-out threshold shows a warning that Iceberg loads run in Local mode in 1.0","The run succeeds without starting any shared job executions","The run detail or log says the load ran in Local mode and why"]} -->

- **Steps**: Create a config from the large source table to the Iceberg destination, with compute mode `auto`. Run it.
- **Expected**: See `look_for`. Known issue: the Local-mode warning is not shown yet.

### CAT-AZ-16 Fan-out failures are reported clearly
<!-- cat: {"id":"CAT-AZ-16","mode":"visual","requires":["azure"],"known_issue":"#1452","destructive":true,"depends_on":["CAT-AZ-12"],"look_for":["With the worker image tag set to one that does not exist, a fan-out run fails within a few minutes","The run detail names the cause (image not found) instead of a generic engine error","After restoring the tag, the next run succeeds"]} -->

- **Warning**: Breaks fan-out on purpose until you restore the tag. Run it only in a maintenance window.
- **Steps**: Set the worker image tag to `cat-missing-tag`. Recreate the container. Run the CAT-AZ-12 config. Restore the tag, then recreate the container again.
- **Expected**: See `look_for`. Known issue: this case needs the `shared` Job. Without it, every fan-out run fails the same way, so the case proves nothing.

### CAT-AZ-17 Compute backend panel reads well
<!-- cat: {"id":"CAT-AZ-17","mode":"visual","requires":["azure"],"look_for":["Admin, Compute and fan-out shows the subscription, resource group, environment, worker image and managed identity","On a host with a managed identity, DataLoader's managed identity is selected by default and no service principal secret is needed","On a host outside Azure, Service principal secret is selected and its stored status is shown without revealing the secret","Test gives a plain pass or fail with the missing item named","Saving the sign-in choice applies without a restart"]} -->

- **Steps**: Open **Admin, Compute and fan-out**. Look at the Fan-out section.
- **Expected**: See `look_for`.

### CAT-AZ-18 Oracle partition reads through the release worker image
<!-- cat: {"id":"CAT-AZ-18","mode":"visual","requires":["azure","src:oracle","dest:postgres"],"depends_on":["CAT-AZ-11","CAT-CONN-04","CAT-DEST-01"],"look_for":["The run for the Oracle table config succeeds and its partitions are listed with the worker as the place they ran","The destination row count equals the Oracle row count, with no duplicates","The shared job's executions show the image digest of the release.yml worker tag, not a locally built image","No partition log contains a libclntsh, DPI-1047 or ORA-12 line"]} -->

- **Purpose**: Proves that the worker image shipped with this release can read Oracle partitions. The standard worker image does not include the Oracle client libraries unless it is built with them, so run this case on the release worker image only.
- **Before you start**: CAT-AZ-11 passes on this install. The `shared` Job exists and pulls `${AZ_WORKER_TAG}` from `${AZ_ACR_NAME}` (CAT-AZ-09). A Postgres destination exists (CAT-DEST-01). The Oracle connection passes its test (CAT-CONN-04). That test proves the DataLoader service can reach Oracle, not the worker.
- **Source table**: More rows than `FANOUT_THRESHOLD`, with an integer split column that has few or no nulls. For example, 500000 rows with `id NUMBER(10)`. Use a table of its own, owned by the test user, so a partial run never touches client data. The table config uses load strategy `full`, compute mode `fan_out` (or `auto` with the threshold below the row count), the integer column as the partition column, and the Postgres destination. Set `max_containers` to 2 or more, so at least two partitions run.
- **Oracle server**: Use an Oracle server that the Container Apps environment can reach. Check reachability from inside the environment with one command, run from an app in that environment: `az containerapp exec -g ${AZ_RG} -n <app in the environment> --command "bash -c 'timeout 5 bash -c \"</dev/tcp/<oracle host>/<oracle port>\" && echo reachable'"`. If it does not print `reachable` within a few seconds, fix the network path first. Do not open the Oracle server to the internet to make the check pass. If the client has no suitable server, a temporary Oracle container in a subnet the environment reaches is an option. It costs money, so get the client's approval first. Delete it when the case is done, and say so in the result.
- **Steps**: (1) Confirm the worker tag in **Admin, Compute and fan-out** is the release tag. Confirm that `az acr repository show -n ${AZ_ACR_NAME} --image dataloader-worker:${AZ_WORKER_TAG} --query digest -o tsv` matches the digest published with that release. (2) Create the table config above and run it. (3) While it runs, list the Job's executions with `az containerapp job execution list -n shared -g ${AZ_RG} -o table`. For each partition's execution, run `az containerapp job execution show -n shared -g ${AZ_RG} --job-execution-name <name> --query "properties.template.containers[0].image" -o tsv`. (4) Open the run page and look at the partitions.
- **Expected**: See `look_for`. A pass needs all of these: the run succeeds; two or more partitions ran as executions of `shared`; each execution's image is `dataloader-worker:${AZ_WORKER_TAG}` and matches the digest from step 1; the destination holds exactly the Oracle row count with no duplicate split-key values; and the run page lists each partition with the worker as where it ran. The run page does not show the image digest, so save the Azure execution output with the result.
- **If the worker cannot load the Oracle client**: The partition fails with a message such as `DPI-1047` or a missing `libclntsh.so`. Record the run ID, the execution name and the partition log. Raise a critical bug with the release team, and cite this case. Do not retry around it. A failure that names Oracle sign-in or network errors (ORA-01017 or ORA-12541) is a setup fault. Fix the source and run again.

---

## 10. Quality checks

Quality checks run against the destination after each successful load. With `on_failure` set to `fail`, a failed check marks the run `quality_check_failed`.

### CAT-QC-01 Passing check keeps the run green
<!-- cat: {"id":"CAT-QC-01","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-LOAD-01"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_PG_ID}","body":{"quality_checks":{"enabled":true,"on_failure":"fail","checks":[{"type":"row_count_min","min":1},{"type":"null_check","column":"${LOAD_SRC_PK}"}]}},"expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_PG_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_QC1_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_QC1_ID}","expect_status":200,"expect_json":{"run.status":"succeeded","run.quality_results":"*"},"retry":{"every_s":5,"for_s":600}}]} -->

- **Steps**: Add a minimum row count of 1 and a null check on the primary key to the Postgres config. Run it.
- **Expected**: The run succeeds. `run.quality_results` shows both checks passed.

### CAT-QC-02 Failing check marks the run
<!-- cat: {"id":"CAT-QC-02","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-QC-01"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_PG_ID}","body":{"quality_checks":{"enabled":true,"on_failure":"fail","checks":[{"type":"row_count_min","min":1000000000}]}},"expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_PG_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_QC2_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_QC2_ID}","expect_status":200,"expect_json":{"run.status":"quality_check_failed"},"retry":{"every_s":5,"for_s":600}}]} -->

- **Steps**: Change the minimum row count to one billion. Run again.
- **Expected**: The run ends as `quality_check_failed`. It shows in the dashboard's recent failures.

### CAT-QC-03 Warn mode keeps the run green
<!-- cat: {"id":"CAT-QC-03","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-QC-02"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_PG_ID}","body":{"quality_checks":{"enabled":true,"on_failure":"warn","checks":[{"type":"row_count_min","min":1000000000}]}},"expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_PG_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_QC3_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_QC3_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":5,"for_s":600}},{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_PG_ID}","body":{"quality_checks":{"enabled":false,"on_failure":"fail","checks":[]}},"expect_status":200}]} -->

- **Steps**: Change the same check to `warn`. Run it. Then turn quality checks off.
- **Expected**: The run succeeds, and the failed check is recorded in `quality_results`.

### CAT-QC-04 Quality checks on warehouse destinations
<!-- cat: {"id":"CAT-QC-04","mode":"automatable","requires":["dest:databricks"],"depends_on":["CAT-LOAD-04"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_DBX_ID}","body":{"quality_checks":{"enabled":true,"on_failure":"fail","checks":[{"type":"row_count_min","min":1000000000}]}},"expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_DBX_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_QC4_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_QC4_ID}","expect_status":200,"expect_json":{"run.status":"quality_check_failed","run.quality_results":"*"},"retry":{"every_s":10,"for_s":900}}]} -->

- **Steps**: Add a `row_count_min` check of one billion, with `on_failure: fail`, to the Databricks config from section 7. Run it. Repeat on the Snowflake config if the client uses Snowflake.
- **Expected**: The run ends as `quality_check_failed`, and `run.quality_results` shows the failed check. A check the warehouse cannot answer, such as a column that does not exist, shows as `error` with the warehouse message. Under `fail`, it also fails the run.

### CAT-QC-05 Quality section is usable
<!-- cat: {"id":"CAT-QC-05","mode":"visual","look_for":["Checks can be added, edited and removed while quality checks are turned off, with a note that they are not running","Column fields offer the table's columns","Run detail lists each check with pass, fail, skip or error and the measured value or the reason"]} -->

- **Steps**: Open the quality section of a table config, and the run detail from CAT-QC-02.
- **Expected**: See `look_for`.

---

## 11. Notifications

Channels send events to email, Teams, Slack, PagerDuty or a generic webhook. Rules decide which events go to which channel. Every signed-in user also has an in-app inbox.

### CAT-NOTIF-01 Channel types are listed
<!-- cat: {"id":"CAT-NOTIF-01","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"GET","path":"/api/v1/notifications/channel-types","expect_status":200,"expect_json":{"0.id":"*"}}} -->

- **Steps**: `GET /api/v1/notifications/channel-types`.
- **Expected**: `email`, `slack_webhook`, `teams_webhook`, `pagerduty` and `generic_webhook` are listed.

### CAT-NOTIF-02 Channel is created and a test message arrives
<!-- cat: {"id":"CAT-NOTIF-02","mode":"automatable","requires":["notify"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"POST","path":"/api/v1/notifications/channels","body":{"name":"cat-acceptance","channel_type":"${NOTIFY_CHANNEL_TYPE}","config_json":"${NOTIFY_CHANNEL_CONFIG}"},"expect_status":[200,201],"save":{"CHANNEL_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/notifications/channels/${CHANNEL_ID}/test","expect_status":200}]} -->

- **Steps**: In **Admin, Notifications**, choose **New channel**. Pick the client's channel type and fill it in. Save, then click **Send test**.
- **Expected**: The channel saves. The test returns 200, and the message arrives at the receiver (mailbox, Teams channel or webhook log). Record where it arrived.

### CAT-NOTIF-03 Rule delivers a run event
<!-- cat: {"id":"CAT-NOTIF-03","mode":"automatable","requires":["notify","dest:postgres"],"depends_on":["CAT-NOTIF-02","CAT-LOAD-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/notifications/rules","body":{"event_type":"run_succeeded","severity":"info","channel_id":"${CHANNEL_ID}"},"expect_status":[200,201],"save":{"RULE_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_PG_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_NOTIF_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_NOTIF_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":5,"for_s":600}},{"kind":"http","method":"GET","path":"/api/v1/notifications/inbox?limit=10","expect_status":200,"expect_json":{"items.0.id":"*"},"retry":{"every_s":5,"for_s":120}}]} -->

- **Steps**: Add a rule that sends `run_succeeded` events to the channel. Run the Postgres config. Check the receiver and the bell icon.
- **Expected**: The event arrives within a minute and shows in the in-app inbox.

### CAT-NOTIF-04 Failure events are delivered
<!-- cat: {"id":"CAT-NOTIF-04","mode":"visual","requires":["notify"],"depends_on":["CAT-NOTIF-02"],"look_for":["A rule for run_failed at severity error delivers a message when a run fails","The message names the table, the environment and the error","The message links back to the run in DataLoader"]} -->

- **Steps**: Add a `run_failed` rule. Make a run fail. For example, remove the destination user's write grant, run the table, then restore the grant.
- **Expected**: See `look_for`.

### CAT-NOTIF-05 Workspace email transport sends
<!-- cat: {"id":"CAT-NOTIF-05","mode":"automatable","requires":["notify"],"depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"POST","path":"/api/v1/settings/runtime/test-email-transport","body":{"to":"${NOTIFY_EMAIL_TO}","transport":"${EMAIL_TRANSPORT_JSON}"},"expect_status":200,"expect_json":{"ok":true}}} -->

- **Before you start**: The client uses SMTP for email. Microsoft Graph is also available. This case covers SMTP.
- **Steps**: In **Admin, Email**, enter the SMTP details and click **Send a test**.
- **Expected**: `ok: true`, and the email arrives. A wrong password gives `ok: false` with a readable message.

### CAT-NOTIF-06 Notification screens read well
<!-- cat: {"id":"CAT-NOTIF-06","mode":"visual","look_for":["With no channels, the page shows one New channel button in the empty state and none in the header","Channel forms use typed fields; JSON mode is optional","Secret fields (webhook URLs with tokens, SMTP password, PagerDuty key) offer Key Vault","The bell icon shows an unread count that clears when read"]} -->

- **Steps**: Walk **Admin, Notifications** and the bell icon.
- **Expected**: See `look_for`.

---
## 12. Retired

This section is kept so the numbers below stay stable. Its cases were removed from the 1.0 build, and their IDs are not reused.

---

## 13. Observability

### CAT-OBS-01 Run history is queryable
<!-- cat: {"id":"CAT-OBS-01","mode":"automatable","depends_on":["CAT-LOAD-02"],"check":[{"kind":"http","method":"GET","path":"/api/v1/execution-runs?env=test&limit=20","expect_status":200,"expect_json":{"runs.0.id":"*","total":"*"}},{"kind":"http","method":"GET","path":"/api/v1/execution-runs?env=test&status=failed,quality_check_failed","expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/execution-runs/stats?env=test&window_hours=24","expect_status":200}]} -->

- **Steps**: List recent TEST runs, filter by failed status, and read the 24-hour stats.
- **Expected**: Each call returns 200. The runs from earlier sections are listed with status, trigger type, rows, and duration.

### CAT-OBS-02 Run logs are kept
<!-- cat: {"id":"CAT-OBS-02","mode":"automatable","depends_on":["CAT-LOAD-02"],"check":{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_PG_ID}/logs","expect_status":200,"expect_json_contains":{"@body":"${RUN_PG_ID}"}}} -->

- **Steps**: `GET /api/v1/runs/${RUN_PG_ID}/logs`.
- **Expected**: 200 with the run's log lines in time order (connect, read, write, finish).

### CAT-OBS-03 Live log stream works
<!-- cat: {"id":"CAT-OBS-03","mode":"visual","depends_on":["CAT-LOAD-01"],"look_for":["Starting a run and opening its log view shows lines arriving without a reload","The run header moves from queued to running to succeeded on its own","A finished run's log still shows in full when reopened"]} -->

- **Steps**: Start a run and open its log view (`/runs/<id>/log`) straight away.
- **Expected**: See `look_for`.

### CAT-OBS-04 Prometheus metrics are exposed
<!-- cat: {"id":"CAT-OBS-04","mode":"automatable","check":{"kind":"http","method":"GET","path":"/api/v1/metrics","expect_status":200,"expect_json_contains":{"@body":"dataloader_executions_total"}}} -->

- **Steps**: `curl -H "Authorization: Bearer ${API_TOKEN}" ${BASE_URL}/api/v1/metrics`, and the same without the header. If the client scrapes it, confirm the scrape in their monitoring tool.
- **Expected**: 200 with Prometheus text including `dataloader_executions_total` for a signed-in caller, and 401 without a credential.

### CAT-OBS-05 Audit history records changes
<!-- cat: {"id":"CAT-OBS-05","mode":"automatable","depends_on":["CAT-CONN-02","CAT-AUTH-13"],"check":[{"kind":"http","method":"GET","path":"/api/v1/audit?limit=50","expect_status":200,"expect_json_contains":{"@body":"cat_src_postgres"},"expect_body_not_contains":["${SECRET_PROBE}"]},{"kind":"http","method":"GET","path":"/api/v1/audit?limit=50&entity_type=connections","auth":"session:SESSION_VIEWER","expect_status":200,"expect_body_not_contains":["${SECRET_PROBE}"]},{"kind":"http","method":"GET","path":"/api/v1/audit?limit=50&format=csv","expect_status":200,"expect_body_not_contains":["${SECRET_PROBE}"]}]} -->

- **Steps**: Open **Admin, Audit history**, or `GET /api/v1/audit?limit=50`, as the admin and as the viewer. Also try `format=csv`. Search each response for the source password (`SECRET_PROBE`).
- **Expected**: The connection, destination and table config changes from earlier sections are listed with user and time. The CSV download works. No password appears in any response, for any role. Audit entries show a stored secret as `***`.

### CAT-OBS-06 Container logs are structured
<!-- cat: {"id":"CAT-OBS-06","mode":"automatable","check":{"kind":"cli","run":"${COMPOSE} logs --no-color --tail 20 dataloader","expect_stdout_contains":"\"level\""}} -->

- **Steps**: Read the last lines of the container log.
- **Expected**: Lines are JSON with `level`, `message`, and fields, and the log driver rotates at 10 MB by 5 files.

### CAT-OBS-07 Dashboard figures match history
<!-- cat: {"id":"CAT-OBS-07","mode":"automatable","depends_on":["CAT-LOAD-02"],"check":{"kind":"http","method":"GET","path":"/api/v1/dashboard/kpis","expect_status":200,"expect_json":{"total_table_configs":"*","window.runs":"*"}}} -->

- **Steps**: `GET /api/v1/dashboard/kpis` and compare with **Runs**.
- **Expected**: Table config and run counts match what earlier sections created.

---

## 14. Upgrade and rollback

On the compose install, an upgrade is a new image tag on the same state volume. Migrations run forward on boot. There is no downgrade migration, so a rollback by hand means restoring the state volume taken before the upgrade and starting the old tag. Cases CAT-UPG-01 to CAT-UPG-07 do that. CAT-UPG-08 to CAT-UPG-10 use the in-app Check now, Apply update and Roll back instead. They need the host update unit that `install.sh` sets up when run as root on a systemd host.

`DATA_VOLUME` is the state volume name, usually `dataloader_dataloader-data` (check with `docker volume ls`). These cases stop the service; run them in a maintenance window with the client's agreement.

### CAT-UPG-01 Pre-upgrade backup is taken
<!-- cat: {"id":"CAT-UPG-01","mode":"automatable","requires":["upgrade"],"destructive":true,"check":[{"kind":"cli","run":"${COMPOSE} stop dataloader"},{"kind":"cli","run":"docker run --rm -v ${DATA_VOLUME}:/src:ro -v ${INSTALL_DIR}/backups:/dst alpine tar czf /dst/pre-upgrade-${IMAGE_TAG}.tar.gz -C /src ."},{"kind":"cli","run":"cp ${INSTALL_DIR}/.env ${INSTALL_DIR}/backups/pre-upgrade-${IMAGE_TAG}.env"},{"kind":"cli","run":"${COMPOSE} start dataloader"},{"kind":"cli","run":"tar tzf ${INSTALL_DIR}/backups/pre-upgrade-${IMAGE_TAG}.tar.gz","expect_stdout_contains":["master.key","jwt.key"]}]} -->

- **Warning**: Stops the service for the length of the backup.
- **Steps**: Stop the container, archive the state volume and `.env` into `${INSTALL_DIR}/backups`, start it again, and list the archive.
- **Expected**: The archive exists and contains `master.key`, `jwt.key`, and (for embedded Postgres) `pg/`. An external Postgres needs its own snapshot at the same time.

### CAT-UPG-02 Upgrade to the newer tag
<!-- cat: {"id":"CAT-UPG-02","mode":"automatable","requires":["upgrade"],"destructive":true,"depends_on":["CAT-UPG-01"],"check":[{"kind":"cli","run":"sed -i 's/^DATALOADER_TAG=.*/DATALOADER_TAG=${UPGRADE_TAG}/' ${INSTALL_DIR}/.env"},{"kind":"cli","run":"${COMPOSE} pull"},{"kind":"cli","run":"${COMPOSE} up -d"},{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"expect_json":{"status":"healthy","version":"${UPGRADE_VERSION}"},"retry":{"every_s":10,"for_s":300}}]} -->

- **Warning**: Replaces the running image. Runs in flight are interrupted.
- **Steps**: Set `DATALOADER_TAG=${UPGRADE_TAG}` in `.env`, pull, and `up -d`. Watch the log for the migrations.
- **Expected**: Health is `healthy` and reports `${UPGRADE_VERSION}` within 5 minutes. The log shows the new migrations applied and no errors.

### CAT-UPG-03 Data and sessions survive the upgrade
<!-- cat: {"id":"CAT-UPG-03","mode":"automatable","requires":["upgrade"],"depends_on":["CAT-UPG-02"],"check":[{"kind":"http","method":"GET","path":"/api/v1/auth/me","expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/connections/${CONN_POSTGRES_ID}","expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/table-configs/${TC_PG_ID}","expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/settings/license","expect_status":200,"expect_json":{"status":"active"}}]} -->

- **Steps**: With the session from before the upgrade, read your profile, the Postgres connection, the Postgres table config, and the license.
- **Expected**: All return 200 with the same data. The license is still active. SSO settings are intact.

### CAT-UPG-04 Loads still run after the upgrade
<!-- cat: {"id":"CAT-UPG-04","mode":"automatable","requires":["upgrade","dest:postgres"],"depends_on":["CAT-UPG-02"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_PG_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_UPG_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_UPG_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":5,"for_s":600}}]} -->

- **Steps**: Run the Postgres config once.
- **Expected**: The run succeeds. Repeat CAT-HEALTH-04 to CAT-HEALTH-07 and CAT-CONN-02's test call.

### CAT-UPG-05 Roll back to the previous tag
<!-- cat: {"id":"CAT-UPG-05","mode":"automatable","requires":["upgrade"],"destructive":true,"depends_on":["CAT-UPG-01","CAT-UPG-02"],"check":[{"kind":"cli","run":"${COMPOSE} down"},{"kind":"cli","run":"docker run --rm -v ${DATA_VOLUME}:/dst -v ${INSTALL_DIR}/backups:/src:ro alpine sh -c 'rm -rf /dst/* /dst/..?* /dst/.[!.]* ; tar xzf /src/pre-upgrade-${IMAGE_TAG}.tar.gz -C /dst'"},{"kind":"cli","run":"sed -i 's/^DATALOADER_TAG=.*/DATALOADER_TAG=${IMAGE_TAG}/' ${INSTALL_DIR}/.env"},{"kind":"cli","run":"${COMPOSE} up -d"},{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"expect_json":{"status":"healthy","version":"${EXPECTED_VERSION}"},"retry":{"every_s":10,"for_s":300}}]} -->

- **Warning**: Deletes the current contents of the state volume and replaces them with the pre-upgrade backup. Anything changed after CAT-UPG-01 is lost. Check the archive from CAT-UPG-01 before running this.
- **Steps**: Stop the stack, restore the pre-upgrade archive into the volume, set `DATALOADER_TAG` back to `${IMAGE_TAG}`, and start. Restore an external Postgres from its snapshot at the same point.
- **Expected**: Health is `healthy` and reports `${EXPECTED_VERSION}`.

### CAT-UPG-06 Data is intact after rollback
<!-- cat: {"id":"CAT-UPG-06","mode":"automatable","requires":["upgrade"],"depends_on":["CAT-UPG-05"],"check":[{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${ADMIN_EMAIL}","password":"${ADMIN_PASSWORD}"},"expect_status":200,"save":{"SESSION":"@cookie"}},{"kind":"http","method":"GET","path":"/api/v1/table-configs/${TC_PG_ID}","expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/connections/${CONN_POSTGRES_ID}/test","expect_status":200,"expect_json":{"is_healthy":true}}]} -->

- **Preconditions**: The bootstrap admin is still enabled, or sign in as the SSO admin instead.
- **Steps**: Sign in, read the table config, and test the connection.
- **Expected**: All succeed. Stored secrets still decrypt (the connection test and SSO test pass). Then repeat CAT-UPG-02 if the client is going live on the newer tag.

### CAT-UPG-07 Update status shows the running version
<!-- cat: {"id":"CAT-UPG-07","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":{"kind":"http","method":"GET","path":"/api/v1/admin/update/status","expect_status":200}} -->

- **Steps**: Open **Admin, Updates**, or `GET /api/v1/admin/update/status`.
- **Expected**: 200. The page shows the current version and whether a newer release exists. On a network without registry access, it shows a readable check error rather than failing.

### CAT-UPG-08 Check now finds the newer tag
<!-- cat: {"id":"CAT-UPG-08","mode":"automatable","requires":["upgrade","hostunit"],"depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"GET","path":"/api/v1/admin/update/status","expect_status":200,"expect_json":{"deployment":"docker","docker_update.unit_installed":true,"check_enabled":true}},{"kind":"http","method":"POST","path":"/api/v1/admin/update/check","expect_status":200,"expect_json":{"current_version":"*","last_checked_at":"*"}}]} -->

- **Preconditions**: A Docker install with the host update unit (`install.sh` run as root on a systemd host). Update checks are on (Admin, Updates). The registry holds `${UPGRADE_TAG}`.
- **Steps**: In **Admin, Updates**, click **Check now**. API: `GET /api/v1/admin/update/status`, then `POST /api/v1/admin/update/check`.
- **Expected**: Status reports `deployment` `docker` and `docker_update.unit_installed` `true`. Check now returns 200, the page shows when it last checked, and it names the newer version and its release notes when `${UPGRADE_TAG}` is newer than the running tag. With the host unit missing, the page says to re-run `install.sh` instead of offering Apply update.

### CAT-UPG-09 Apply update from the app
<!-- cat: {"id":"CAT-UPG-09","mode":"automatable","requires":["upgrade","hostunit"],"destructive":true,"depends_on":["CAT-UPG-01","CAT-UPG-08"],"check":[{"kind":"http","method":"POST","path":"/api/v1/admin/update/docker-apply","body":{"tag":"${UPGRADE_TAG}"},"expect_status":202},{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"expect_json":{"status":"healthy","version":"${UPGRADE_VERSION}"},"retry":{"every_s":10,"for_s":600}},{"kind":"http","method":"GET","path":"/api/v1/admin/update/status","expect_status":200,"expect_json":{"docker_update.last_result.status":"applied","docker_update.last_result.new_version":"${UPGRADE_VERSION}"},"retry":{"every_s":10,"for_s":120}}]} -->

- **Warning**: Replaces the running image through the host. Runs in flight stop with the restart. Take the backup in CAT-UPG-01 first. Use this case or CAT-UPG-02 to reach the newer tag, not both.
- **Steps**: In **Admin, Updates**, click **Apply update** and confirm. The page follows the restart and shows the host's result. API: `POST /api/v1/admin/update/docker-apply` with `{"tag":"${UPGRADE_TAG}"}`.
- **Expected**: 202, then health reports `${UPGRADE_VERSION}` within 10 minutes. The page says the update applied, naming both versions. Status shows `docker_update.last_result.status` `applied`. A refusal or failure reads as a sentence with the log tail behind it, and a failed start puts the old tag back. CAT-UPG-03 and CAT-UPG-04 pass again.

### CAT-UPG-10 Roll back from the app
<!-- cat: {"id":"CAT-UPG-10","mode":"automatable","requires":["upgrade","hostunit"],"destructive":true,"depends_on":["CAT-UPG-09"],"check":[{"kind":"http","method":"POST","path":"/api/v1/admin/update/docker-apply","body":{"tag":"${IMAGE_TAG}","downgrade":true},"expect_status":202},{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"expect_json":{"status":"healthy","version":"${EXPECTED_VERSION}"},"retry":{"every_s":10,"for_s":600}},{"kind":"http","method":"GET","path":"/api/v1/admin/update/status","expect_status":200,"expect_json":{"docker_update.last_result.status":"applied","docker_update.last_result.rollback":true},"retry":{"every_s":10,"for_s":120}},{"kind":"http","method":"GET","path":"/api/v1/connections/${CONN_POSTGRES_ID}","expect_status":200}]} -->

- **Warning**: Moves the install back to the previous tag and restarts it. Runs in flight stop. The database keeps the newer schema, which the older version ignores.
- **Steps**: In **Admin, Updates**, click **Roll back to** the previous version and confirm. API: `POST /api/v1/admin/update/docker-apply` with `{"tag":"${IMAGE_TAG}","downgrade":true}`. Without `downgrade` the host refuses an older tag.
- **Expected**: 202, then health reports `${EXPECTED_VERSION}`. Status shows the result as `applied` with `rollback` `true`. Connections, table configs and users are still there and the license is still active. If a migration made a breaking change, restore the backup from CAT-UPG-01 instead (CAT-UPG-05).

---

## 15. Backup and restore

DataLoader has two backup layers: the state volume (everything, including keys and embedded Postgres) and the signed configuration export (connections, destinations, table configs, sensors, dependencies, notification channels and rules, without secrets or run history). Scheduled offsite backup and point-in-time restore are not in 1.0; the client's own tooling copies `${INSTALL_DIR}/backups` offsite.

### CAT-BAK-01 State volume backup
<!-- cat: {"id":"CAT-BAK-01","mode":"automatable","destructive":true,"check":[{"kind":"cli","run":"${COMPOSE} stop dataloader"},{"kind":"cli","run":"docker run --rm -v ${DATA_VOLUME}:/src:ro -v ${INSTALL_DIR}/backups:/dst alpine tar czf /dst/dataloader-state-acceptance.tar.gz -C /src ."},{"kind":"cli","run":"${COMPOSE} start dataloader"},{"kind":"cli","run":"tar tzf ${INSTALL_DIR}/backups/dataloader-state-acceptance.tar.gz","expect_stdout_contains":"master.key"}]} -->

- **Warning**: Stops the service for the length of the backup.
- **Steps**: Stop, archive the volume, start. Agree the schedule and offsite copy with the client.
- **Expected**: The archive contains `master.key`, `jwt.key`, and `pg/`. The client knows the archive holds keys and must be stored like a credential.

### CAT-BAK-02 Configuration export
<!-- cat: {"id":"CAT-BAK-02","mode":"automatable","depends_on":["CAT-CONN-02"],"check":{"kind":"http","method":"GET","path":"/api/v1/config/export","expect_status":200,"expect_json":{"version":"*","signature":"*"},"expect_json_contains":{"@body":"cat_src_postgres"},"save":{"EXPORT_ENVELOPE":"@body"}}} -->

- **Steps**: `GET /api/v1/config/export` and save the file.
- **Expected**: A signed envelope with `version`, `exported_at`, `data`, and `signature`. It includes the acceptance connection. Run CAT-BAK-03 to check it holds no secrets.

### CAT-BAK-03 Export holds no secrets
<!-- cat: {"id":"CAT-BAK-03","mode":"automatable","depends_on":["CAT-CONN-02"],"check":{"kind":"http","method":"GET","path":"/api/v1/config/export","expect_status":200,"expect_body_not_contains":["${SECRET_PROBE}","${SSO_CLIENT_SECRET}"]}} -->

- **Steps**: Search the export for a source password and the SSO client secret.
- **Expected**: Neither appears; secrets are referenced by `kv://` URI. A password saved without Key Vault shows as `***` in the export.

### CAT-BAK-04 Import dry run
<!-- cat: {"id":"CAT-BAK-04","mode":"automatable","depends_on":["CAT-BAK-02"],"check":{"kind":"http","method":"POST","path":"/api/v1/config/import?dry_run=true","body":"${EXPORT_ENVELOPE}","expect_status":200}} -->

- **Steps**: `POST /api/v1/config/import?dry_run=true` with the export.
- **Expected**: 200 with per-table counts. Nothing changes. A tampered envelope is refused because the signature does not match.

### CAT-BAK-05 Named snapshot and restore
<!-- cat: {"id":"CAT-BAK-05","mode":"automatable","destructive":true,"depends_on":["CAT-LOAD-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/config/snapshots","body":{"name":"cat-acceptance","description":"Before snapshot restore test"},"expect_status":[200,201],"save":{"SNAP_ID":"id"}},{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_PG_ID}","body":{"is_active":false},"expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/config/snapshots/${SNAP_ID}/restore","expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/table-configs/${TC_PG_ID}","expect_status":200,"expect_json":{"is_active":true}}]} -->

- **Warning**: Overwrites current configuration with the snapshot. Changes made after the snapshot are reverted.
- **Steps**: Take a snapshot, pause the Postgres config, restore the snapshot, and read the config.
- **Expected**: The config is active again. The snapshot is listed under `GET /api/v1/config/snapshots`.

### CAT-BAK-06 Full restore on a new host
<!-- cat: {"id":"CAT-BAK-06","mode":"visual","destructive":true,"look_for":["On a second host with the same image tag, restoring the state archive into an empty volume and starting the stack gives a healthy install","The same users can sign in and see the same connections, table configs and history","Connection tests and the SSO test pass, proving master.key restored correctly"]} -->

- **Warning**: Run on a separate host only. Stop the second host afterwards so two installs do not run the same schedules against the same destinations.
- **Steps**: Install the compose file on a second host, restore `dataloader-state-acceptance.tar.gz` into its volume, copy `.env` and `license/`, start it, and sign in. Disable schedules on it before starting if the first install is still live.
- **Expected**: See `look_for`.

---

## 16. UI walk

Walk the main screens as the admin, in light and dark themes, with the TEST environment selected unless a case says otherwise. Each case lists what an operator should see. The checks cover whether forms help, secrets stay hidden, the environment switch works, restart needs are stated, the copy is plain, and no demo data appears.

### CAT-UI-01 Every page loads without errors
<!-- cat: {"id":"CAT-UI-01","mode":"automatable","check":[{"kind":"ui","path":"/overview","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/overview/trends","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/tables","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/tables?mode=bulk","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/tables/promotion","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/assets","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/assets/dbt","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/automation/schedule","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/automation/sensors","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/automation/ticks","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/runs","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/runs/timeline","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/connections","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/connections?kind=destination","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/admin/users","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/admin/groups","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/admin/audit","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/admin/plugins","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/admin/notifications","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/settings/workspace","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/settings/automation","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/settings/updates","login":true,"expect_no_console_errors":true},{"kind":"ui","path":"/help/troubleshooting","login":true,"expect_no_console_errors":true}]} -->

- **Steps**: Open each main page as the admin.
- **Expected**: Every page renders with no console errors and no failed API calls other than expected 404s.

### CAT-UI-02 Setup wizard
<!-- cat: {"id":"CAT-UI-02","mode":"visual","look_for":["The first admin sign-in on a new install lands on the setup wizard","The wizard has two steps: the workspace name, then the license","The workspace name is kept when going Back and forward","A chosen or pasted license file shows who it is for and when it ends, or why it was refused, before Finish setup is allowed","Choosing a license file and then switching to the trial leaves no license applied","Finishing lands on Overview, which shows the getting-started list: Connect a source, Add a destination, Add a table, Run it","Each step checks itself off once it exists, and only the next step has a primary button","Admins also see Single sign-on, Key Vault and Fan-out as optional steps"]} -->

- **Steps**: On a new install, walk both wizard steps, then look at Overview. On an install that already finished setup, record N/A and rely on CAT-AUTH-06.
- **Expected**: See `look_for`.

### CAT-UI-03 Overview
<!-- cat: {"id":"CAT-UI-03","mode":"visual","look_for":["KPI cards, daily volume chart, schedule heatmap, recent failures and suggestions all render","Figures match Runs","Empty areas show a short explanation, not broken charts or placeholder rows","Numbers update while a run finishes, without a reload"]} -->

- **Steps**: Open Overview after sections 7 and 8.
- **Expected**: See `look_for`.

### CAT-UI-04 TEST and PROD switch
<!-- cat: {"id":"CAT-UI-04","mode":"visual","look_for":["The top bar shows TEST (blue) or PROD (red) as a switch, not a static label","Switching to PROD asks for confirmation and explains the effect; switching to TEST does not","Lists reload for the chosen environment and the choice persists across pages and reloads","Run now in TEST mentions the 1,000-row cap; in PROD it does not","TEST-only options such as Dev full load are hidden in PROD"]} -->

- **Steps**: Switch between TEST and PROD while visiting Connections, Tables and a Run now dialog.
- **Expected**: See `look_for`.

### CAT-UI-05 List pages
<!-- cat: {"id":"CAT-UI-05","mode":"visual","look_for":["Loading shows skeletons shaped like the list, not spinners","An empty list shows an explanation and one create button; the header create button appears only when the list has rows","A filter with no matches says so and offers Clear filters","An error shows a retry and a copy-details option"]} -->

- **Steps**: Look at Connections (with its Sources and Destinations filters), Tables, Assets, Sensors, Notifications, OAuth clients and Plugins, including an empty one and a filtered one.
- **Expected**: See `look_for`.

### CAT-UI-06 Forms fill themselves where they can
<!-- cat: {"id":"CAT-UI-06","mode":"visual","look_for":["Connection forms split into fields per database type","Table config forms default destination catalog and schema from workspace and connection settings","Column fields suggest values with a reason","Time zone fields offer a short North American list with an Other option","AI model fields are dropdowns per provider"]} -->

- **Steps**: Open New connection, New table, Admin General, your Preferences (account menu), and Admin AI provider.
- **Expected**: See `look_for`.

### CAT-UI-07 Dialogs
<!-- cat: {"id":"CAT-UI-07","mode":"visual","look_for":["New user, New group, New sensor, Install plugin, the PROD confirmation and delete confirmations are centered with a backdrop","Escape closes each; a backdrop click closes each","Tab and Shift-Tab stay inside the dialog","Focus returns to the button that opened it"]} -->

- **Steps**: Open and close each dialog listed, with keyboard and mouse.
- **Expected**: See `look_for`.

### CAT-UI-08 Admin layout and restart hints
<!-- cat: {"id":"CAT-UI-08","mode":"visual","look_for":["Admin pages are grouped (People, Security, Platform, Workspace) and each has a rail entry","Admin is visible only to admins","A section that edits settings has a save bar with the count of unsaved changes, Discard and Save","Leaving a page with unsaved changes asks first","Fields that apply without restart say so","Fields that need a restart show the exact command for this install (docker compose ... restart dataloader) with a copy button, or offer Restart now"]} -->

- **Steps**: Walk every page under Admin.
- **Expected**: See `look_for`.

### CAT-UI-09 Plain language
<!-- cat: {"id":"CAT-UI-09","mode":"visual","look_for":["No raw error codes, HTTP verbs, algorithm names or developer notes in the UI","Errors say what went wrong and what to do next","Copy fits a line-of-business user, not only an engineer"]} -->

- **Steps**: Read the copy on each page and on the errors seen in earlier sections.
- **Expected**: See `look_for`. Note each offending string with its page.

### CAT-UI-10 No demo data
<!-- cat: {"id":"CAT-UI-10","mode":"visual","look_for":["Promote, Overview, Users and Groups show only real data from this install","No sample rows, fake users or placeholder charts appear anywhere"]} -->

- **Steps**: Look closely at Promote, Overview, Users and Groups.
- **Expected**: See `look_for`.

### CAT-UI-11 Themes and density
<!-- cat: {"id":"CAT-UI-11","mode":"visual","look_for":["Light and dark themes both render every page with readable contrast and no hard-coded colors left behind","Compact, comfortable and spacious density apply and persist","A visible focus ring appears on every control when using the keyboard"]} -->

- **Steps**: Switch theme and density, then tab through a form.
- **Expected**: See `look_for`.

### CAT-UI-12 Version label
<!-- cat: {"id":"CAT-UI-12","mode":"visual","look_for":["The account menu shows the release version, matching CAT-HEALTH-06","The version changes after the upgrade in section 14"]} -->

- **Steps**: Open the account menu before and after the upgrade and read the version.
- **Expected**: See `look_for`.

### CAT-UI-13 History and run detail
<!-- cat: {"id":"CAT-UI-13","mode":"visual","look_for":["Runs filters by status, trigger and time","Run detail shows source, destination, strategy, rows, duration, quality results and error","A failed run offers Diagnose with AI only when an AI provider is set up"]} -->

- **Steps**: Open **Runs** and a succeeded and a failed run.
- **Expected**: See `look_for`.

---

## 17. Access policies

A table can carry tags, column masks and a row filter that its destination enforces. DataLoader loads every value unchanged and applies the policy before the first row lands. It needs Databricks with Unity Catalog, or Snowflake Enterprise edition. The groups (Databricks) or roles (Snowflake) are the client's own; DataLoader does not create them. The destination account that DataLoader signs in as needs the grants the save-time warnings name: `CREATE FUNCTION` on the policy schema and ownership or `MANAGE` on the table (Databricks), or `CREATE MASKING POLICY`, `CREATE ROW ACCESS POLICY`, `CREATE TAG` and the `APPLY` privileges (Snowflake).

The SI's own SQL login may be filtered by the policy it just set. The checks below read the destination's catalog views, not table data.

### CAT-ACC-01 Databricks: policy is saved and applied by a run
<!-- cat: {"id":"CAT-ACC-01","mode":"automatable","requires":["dest:databricks"],"depends_on":["CAT-LOAD-04"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_DBX_ID}","body":{"access_policy":{"table_tags":{"dl_acceptance":"true"},"columns":{"${ACC_TEXT_COLUMN}":{"tags":{"sensitivity":"restricted"},"mask":{"rule":{"see":["${ACC_GROUP}"],"others":"null"}}}},"row_filter":{"rule":{"see":["${ACC_GROUP}"],"others_where":{"column":"${ACC_FILTER_COLUMN}","op":"in","values":["${ACC_FILTER_VALUE}"]}}}}},"expect_status":200,"expect_json":{"access_policy.table_tags.dl_acceptance":"true"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_DBX_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_ACC_DBX_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_ACC_DBX_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":10,"for_s":900}},{"kind":"http","method":"GET","path":"/api/v1/table-configs/${TC_DBX_ID}","expect_status":200,"expect_json":{"access_policy_applied.at":"*"}},{"kind":"sql","target":"DEST_DATABRICKS_DSN","query":"SELECT count(*) FROM ${DEST_DATABRICKS_CATALOG}.information_schema.column_masks WHERE table_schema = '${DEST_DATABRICKS_SCHEMA}' AND table_name = 'cat_load_dbx' AND column_name = '${ACC_TEXT_COLUMN}'","expect_scalar":1},{"kind":"sql","target":"DEST_DATABRICKS_DSN","query":"SELECT count(*) FROM ${DEST_DATABRICKS_CATALOG}.information_schema.row_filters WHERE table_schema = '${DEST_DATABRICKS_SCHEMA}' AND table_name = 'cat_load_dbx'","expect_scalar":1},{"kind":"sql","target":"DEST_DATABRICKS_DSN","query":"SELECT count(*) FROM ${DEST_DATABRICKS_CATALOG}.information_schema.table_tags WHERE schema_name = '${DEST_DATABRICKS_SCHEMA}' AND table_name = 'cat_load_dbx' AND tag_name = 'dl_acceptance'","expect_scalar":1}]} -->

- **Preconditions**: The Databricks load from CAT-LOAD-04. `ACC_GROUP` exists in the account.
- **Steps**: On the table's **Edit** page, open **Access**. Add a table tag, protect `${ACC_TEXT_COLUMN}` (visible to `${ACC_GROUP}`, everyone else sees nothing), and add a row filter that shows everyone the rows where `${ACC_FILTER_COLUMN}` is `${ACC_FILTER_VALUE}`. Save, then **Run now**. API: `PUT /api/v1/table-configs/{id}` with `access_policy`, then the run call from CAT-LOAD-02.
- **Expected**: The save returns 200 and echoes `access_policy`. The run succeeds. The table config now carries `access_policy_applied` with the time of the run. Unity Catalog lists one column mask, one row filter and the table tag on `cat_load_dbx`. Someone outside `${ACC_GROUP}` sees NULL in the masked column and only the visible rows; a member of the group sees every value.

### CAT-ACC-02 Databricks: a second run keeps the policy
<!-- cat: {"id":"CAT-ACC-02","mode":"automatable","requires":["dest:databricks"],"depends_on":["CAT-ACC-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_DBX_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_ACC_DBX2_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_ACC_DBX2_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":10,"for_s":900}},{"kind":"sql","target":"DEST_DATABRICKS_DSN","query":"SELECT count(*) FROM ${DEST_DATABRICKS_CATALOG}.information_schema.column_masks WHERE table_schema = '${DEST_DATABRICKS_SCHEMA}' AND table_name = 'cat_load_dbx'","expect_scalar":1}]} -->

- **Steps**: Run the table again.
- **Expected**: The run succeeds and the mask is still attached once. The run log says what it checked. If someone removes a mask or tag that DataLoader applied, the next run puts it back and the log says so; a mask or tag DataLoader never applied is left alone.

### CAT-ACC-03 Snowflake: policy is saved and applied by a run
<!-- cat: {"id":"CAT-ACC-03","mode":"automatable","requires":["dest:snowflake"],"depends_on":["CAT-LOAD-06"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_SF_ID}","body":{"access_policy":{"table_tags":{"dl_acceptance":"true"},"columns":{"${ACC_TEXT_COLUMN}":{"mask":{"rule":{"see":["${ACC_GROUP}"],"others":"null"}}}},"row_filter":{"rule":{"see":["${ACC_GROUP}"],"others_where":{"column":"${ACC_FILTER_COLUMN}","op":"in","values":["${ACC_FILTER_VALUE}"]}}}}},"expect_status":200},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_SF_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_ACC_SF_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_ACC_SF_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":10,"for_s":900}},{"kind":"http","method":"GET","path":"/api/v1/table-configs/${TC_SF_ID}","expect_status":200,"expect_json":{"access_policy_applied.at":"*"}},{"kind":"sql","target":"DEST_SNOWFLAKE_DSN","query":"SELECT count(*) FROM TABLE(${DEST_SNOWFLAKE_CATALOG}.INFORMATION_SCHEMA.POLICY_REFERENCES(REF_ENTITY_NAME => '${DEST_SNOWFLAKE_CATALOG}.${DEST_SNOWFLAKE_SCHEMA}.CAT_LOAD_SF', REF_ENTITY_DOMAIN => 'TABLE'))","expect_min":2},{"kind":"sql","target":"DEST_SNOWFLAKE_DSN","query":"SELECT count(*) FROM TABLE(${DEST_SNOWFLAKE_CATALOG}.INFORMATION_SCHEMA.TAG_REFERENCES('${DEST_SNOWFLAKE_CATALOG}.${DEST_SNOWFLAKE_SCHEMA}.CAT_LOAD_SF', 'TABLE'))","expect_min":1}]} -->

- **Preconditions**: The Snowflake load from CAT-LOAD-06, on Enterprise edition or higher. `ACC_GROUP` is an existing role. Record N/A on Standard edition and run CAT-ACC-05 instead.
- **Steps**: As CAT-ACC-01, on the Snowflake table.
- **Expected**: The save returns 200, the run succeeds, and `access_policy_applied` is set. Snowflake lists a masking policy and a row access policy on `CAT_LOAD_SF` (at least two policy references) and the table tag. The policy and tag objects live in the destination's policy schema (default: the table's own schema).

### CAT-ACC-04 A destination that cannot enforce refuses a policy
<!-- cat: {"id":"CAT-ACC-04","mode":"automatable","requires":["dest:postgres"],"depends_on":["CAT-LOAD-01"],"check":{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_PG_ID}","body":{"access_policy":{"table_tags":{"dl_acceptance":"true"}}},"expect_status":422,"expect_json":{"field":"access_policy"}}} -->

- **Steps**: On the Postgres table's **Edit** page, open **Access**. API: `PUT /api/v1/table-configs/${TC_PG_ID}` with `{"access_policy":{"table_tags":{"dl_acceptance":"true"}}}`.
- **Expected**: On Postgres, HTTP 422 with `field` `access_policy` and an `error` saying PostgreSQL does not support access tags (Postgres can enforce column masks and row filters, not tags). Delta Lake and Iceberg answer HTTP 400 with `code` `access_policy_unsupported_destination`. In the UI the section says the destination can't enforce column masks or row filters and to load the table into Databricks or Snowflake. The table config is unchanged. Delta Lake and Iceberg destinations refuse the same way.

### CAT-ACC-05 A policy that cannot apply fails the run before any row lands
<!-- cat: {"id":"CAT-ACC-05","mode":"visual","requires":["dest:databricks"],"depends_on":["CAT-ACC-01"],"look_for":["With a column name that the table does not have, the save is refused with a sentence naming the column","With a group name that does not exist, the run fails before it loads any row, and the run detail says which group or grant is missing","On Snowflake Standard edition, the run fails with a sentence saying the account has no masking policies or tags","The destination table is never readable without its policy: no rows land while the policy is missing"]} -->

- **Steps**: Save a policy that names a column the table lacks. Then save one whose `see` group does not exist at the destination and run the table. Remove the bad policy afterwards.
- **Expected**: See `look_for`.

### CAT-ACC-06 Access section reads well
<!-- cat: {"id":"CAT-ACC-06","mode":"visual","depends_on":["CAT-ACC-01"],"look_for":["Edit has an Access section with Table tags, Protect a column and Row filter","A protected column lists who sees it and what everyone else sees (nothing, a fixed text, or the last four characters)","The section shows whether the last run confirmed the policy, and when","Choosing a destination that cannot enforce a policy hides the controls and says why","The table's Changes tab lists a policy change, and Promote warns when a policy is loosened (a mask or filter removed, a group added)"]} -->

- **Steps**: Open the Databricks table's **Edit** page, then its **Changes** tab, then **Tables, Promote** with the table selected.
- **Expected**: See `look_for`.

---

## 18. dbt, assets and automation

A dbt project's models become assets in the Assets graph, wired to the loads they read. Automation runs an asset when its condition holds, for example a model after its upstream load. A new project starts in dry run: automation records what it would do and starts nothing until an admin turns dry run off. Skip this section when the client does not use dbt.

### CAT-DBT-01 A dbt project is created and syncs
<!-- cat: {"id":"CAT-DBT-01","mode":"automatable","requires":["dbt"],"depends_on":["CAT-AUTH-03","CAT-LOAD-02"],"check":[{"kind":"http","method":"POST","path":"/api/v1/dbt/projects","body":"${DBT_PROJECT_BODY}","expect_status":201,"expect_json":{"id":"*"},"save":{"DBT_PROJECT_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/dbt/projects/${DBT_PROJECT_ID}/sync?wait=true","expect_status":200,"expect_json":{"state":"synced","environments.0.status":"ingested"},"retry":{"every_s":30,"for_s":300}},{"kind":"http","method":"GET","path":"/api/v1/dbt/projects/${DBT_PROJECT_ID}/parse-errors","expect_status":200,"expect_body_not_contains":["parse_failed","rejected"]}]} -->

- **Steps**: In **Assets, dbt projects**, click **New project**, fill in the repository, ref, Git access and a target for TEST, and save. Click **Sync**. API: `POST /api/v1/dbt/projects` with `${DBT_PROJECT_BODY}`, then `POST /api/v1/dbt/projects/{id}/sync?wait=true`.
- **Expected**: Create returns 201 and the project is in dry run. The sync returns `synced` and the TEST environment is `ingested`. The project lists no parse errors. The list shows the project, its source and environments, dry run, and the time of the last sync.

### CAT-DBT-02 The asset graph shows the project's models
<!-- cat: {"id":"CAT-DBT-02","mode":"automatable","requires":["dbt"],"depends_on":["CAT-DBT-01"],"check":[{"kind":"http","method":"GET","path":"/api/v1/assets?env=test&q=${DBT_MODEL_KEY}&limit=5","expect_status":200,"expect_json_contains":{"@body":"${DBT_MODEL_KEY}"}},{"kind":"http","method":"GET","path":"/api/v1/assets/graph?env=test&q=${DBT_MODEL_KEY}","expect_status":200,"expect_json":{"nodes":"*","edges":"*"},"expect_json_contains":{"@body":"${DBT_MODEL_KEY}"}}]} -->

- **Steps**: Open **Assets**, search for the model, and open it. API: `GET /api/v1/assets?env=test&q=<model>` and `GET /api/v1/assets/graph?env=test&q=<model>`.
- **Expected**: Both return 200 and name the model. The graph draws the model with an edge from the load it reads (or from the source it maps to), and the model's page shows its definition, its automation condition and its runs.

### CAT-DBT-03 dbt screens read well
<!-- cat: {"id":"CAT-DBT-03","mode":"visual","requires":["dbt"],"depends_on":["CAT-DBT-01"],"look_for":["Assets, dbt projects lists the project with its source, environments, dry run or live, and last sync","The graph opens on the project, draws loads and models with their edges, and a node's status (fresh, running, failed, waiting) reads in words","Opening a model shows its columns, its SQL, and the repository file it came from","A sync that fails shows its parse errors as sentences, not a stack trace"]} -->

- **Steps**: Walk **Assets** and **Assets, dbt projects**.
- **Expected**: See `look_for`.

### CAT-AUTO-01 Automation runs a model after its upstream load
<!-- cat: {"id":"CAT-AUTO-01","mode":"automatable","requires":["dbt","dest:postgres"],"depends_on":["CAT-DBT-02","CAT-LOAD-02"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/automation/settings/test","body":{"enabled":true,"dry_run":false},"expect_status":200},{"kind":"http","method":"PUT","path":"/api/v1/automation/projects/${DBT_PROJECT_ID}","body":{"dry_run":false},"expect_status":200},{"kind":"http","method":"GET","path":"/api/v1/assets?env=test&q=${DBT_MODEL_KEY}&limit=1","expect_status":200,"save":{"DBT_MODEL_ID":"0.id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_PG_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_AUTO_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_AUTO_ID}","expect_status":200,"expect_json":{"run.status":"succeeded"},"retry":{"every_s":5,"for_s":600}},{"kind":"http","method":"GET","path":"/api/v1/assets/${DBT_MODEL_ID}/evaluations?limit=5","expect_status":200,"expect_json_contains":{"@body":"requested"},"retry":{"every_s":15,"for_s":900}},{"kind":"http","method":"GET","path":"/api/v1/assets/${DBT_MODEL_ID}/events?limit=5","expect_status":200,"expect_json_contains":{"@body":"materialized"},"retry":{"every_s":15,"for_s":900}}]} -->

- **Warning**: Turns TEST automation on and takes the project out of dry run, so dbt builds real models in the project's TEST schema. CAT-AUTO-04 puts both back.
- **Preconditions**: The project reads the table that `TC_PG_ID` loads (a source mapped to that load), and keeps the project's default condition or one that reacts to its upstream.
- **Steps**: In **Admin, Automation**, turn on Automation in TEST and turn off dry run for the project. Run the Postgres load. Watch the model on **Assets**.
- **Expected**: The load succeeds. Within a few automation ticks (30 seconds each, plus the condition's own window) the model's evaluations show `requested`, a dbt run starts, and the model records a `materialized` event. The run appears in **Runs** as a dbt run and links to the model.

### CAT-AUTO-02 The tick log explains a decision
<!-- cat: {"id":"CAT-AUTO-02","mode":"automatable","requires":["dbt"],"depends_on":["CAT-AUTO-01"],"check":[{"kind":"http","method":"GET","path":"/api/v1/assets/${DBT_MODEL_ID}/evaluations?limit=1","expect_status":200,"expect_json":{"0.decision":"*","0.summary":"*","0.tick_id":"*"},"save":{"TICK_ID":"0.tick_id"}},{"kind":"http","method":"GET","path":"/api/v1/automation/ticks/${TICK_ID}","expect_status":200,"expect_json":{"tick":"*","evaluations":"*"},"expect_json_contains":{"@body":"${DBT_MODEL_KEY}"}},{"kind":"http","method":"GET","path":"/api/v1/automation/ticks/summary?env=test","expect_status":200,"expect_json":{"ticks":"*","runs_requested":"*"}}]} -->

- **Steps**: Open **Automation, Tick log**, pick the newest tick that names the model, and open it. API: `GET /api/v1/assets/{id}/evaluations`, then `GET /api/v1/automation/ticks/{tick_id}`.
- **Expected**: Each evaluation has a decision (`requested`, `skipped`, `capped`, `dry_run` or `failed`) and a summary sentence that says why, for example which upstream changed or why the asset waited. The tick opens with its evaluations and the totals read from `GET /api/v1/automation/ticks/summary`.

### CAT-AUTO-03 Automation screens read well
<!-- cat: {"id":"CAT-AUTO-03","mode":"visual","depends_on":["CAT-AUTO-01"],"look_for":["Automation has Schedule, Sensors and Tick log; the Tick log lists ticks newest first with what each asked for","A tick opens to its evaluations, each with a decision in words and the reason","A model's Automation tab shows its condition in words, the days of decisions, and a button to change the condition","Admin, Automation has the switches for TEST and PROD, the dry run per project, the check interval, and the dbt runtime health","With TEST automation off, the pages say so instead of showing an empty log"]} -->

- **Steps**: Walk **Automation** and **Admin, Automation**.
- **Expected**: See `look_for`.

### CAT-AUTO-04 Automation is put back
<!-- cat: {"id":"CAT-AUTO-04","mode":"automatable","requires":["dbt"],"depends_on":["CAT-AUTO-01"],"check":[{"kind":"http","method":"PUT","path":"/api/v1/automation/projects/${DBT_PROJECT_ID}","body":{"dry_run":true},"expect_status":200},{"kind":"http","method":"PUT","path":"/api/v1/automation/settings/test","body":{"enabled":false,"dry_run":true},"expect_status":200}]} -->

- **Steps**: In **Admin, Automation**, turn dry run back on for the project and Automation in TEST off, unless the client wants them live.
- **Expected**: Both calls return 200. The client agrees the final state in the sign-off notes.

### CAT-AUTO-05 The comparison with Dagster has every difference explained
<!-- cat: {"id":"CAT-AUTO-05","mode":"automatable","requires":["dbt","dagster"],"depends_on":["CAT-DBT-01"],"check":{"kind":"cli","run":"dl automation compare-dagster --dagster-url ${DAGSTER_URL} --code-location ${DAGSTER_CODE_LOCATION} --since 7d --env prod --json","expect_exit":0,"expect_stdout_contains":["\"dagster_runs\"","\"assets\""]}} -->

- **Preconditions**: The project has been in dry run for a week while Dagster kept building (see Move a Dagster code location to DataLoader). `DAGSTER_TOKEN` is exported for Dagster+. `dl` is signed in (`dl login`, or `DL_TOKEN`).
- **Steps**: Run the command from a machine that can reach both. Read every row with a `difference`.
- **Expected**: The command exits 0 and prints a report with a row per asset of the code location, and `notes` is empty. Every difference (`count_differs`, `dagster_only`, `dataloader_only`, `unmapped_asset`) has a reason, and the SI records each as fixed or accepted in the sign-off notes. A `blocking` difference fails the case. The token never appears in the output.

### CAT-AUTO-06 A project switches live and back
<!-- cat: {"id":"CAT-AUTO-06","mode":"visual","requires":["dbt","dagster"],"depends_on":["CAT-AUTO-05"],"look_for":["With Run live on, a model builds on its next upstream update and its Runs tab says automation started it","The Automation tab's latest evaluation says requested, and the Why list names the upstream","Turning Run live off returns the project to Dry run, and a later upstream update records dry_run and starts no run","The Dagster code location is still loaded, so its automation can be switched back on"]} -->

- **Warning**: Takes the project out of dry run, so dbt builds real models. Stop the code location's automation in Dagster first, and agree the final state with the client.
- **Steps**: Follow steps 4 and 5 of Move a Dagster code location to DataLoader: switch the project live, watch the first build, then roll back.
- **Expected**: See `look_for`.

---

## 19. Settings that apply without a restart

These Admin pages used to need a restart after a save. Each now takes effect at the next run or tick. For every case, note the container's start time first (`${COMPOSE} ps`), save the change, check the effect, and confirm the container was not restarted.

### CAT-SET-01 Log export applies at the next export
<!-- cat: {"id":"CAT-SET-01","mode":"visual","look_for":["Admin, Logs says changes apply at the next cleanup or export, no restart needed","Turning log export on for a destination, or editing its writer settings, makes the next export go there without a restart","Turning export off stops it at the next export","The container's start time is unchanged"]} -->

- **Preconditions**: A destination with log export available (for example a warehouse destination or the Azure Storage log container).
- **Steps**: In **Admin, Logs**, turn on export for the destination and save. Wait one export interval and look for the new log files or rows.
- **Expected**: See `look_for`.

### CAT-SET-02 Compute and fan-out apply at the next run
<!-- cat: {"id":"CAT-SET-02","mode":"visual","requires":["azure"],"look_for":["Admin, Compute and fan-out says every field applies without a restart","Saving the fan-out switch, the worker image or the stored service principal changes the next run, not only a run after a restart","Turning fan-out off makes a table above the threshold run in Local mode on its next run","The container's start time is unchanged"]} -->

- **Steps**: In **Admin, Compute and fan-out**, change the worker image tag to a valid tag and save, or turn fan-out off and on. Run a table above the threshold (CAT-AZ-12) before and after.
- **Expected**: See `look_for`.

### CAT-SET-03 Entra group sync applies at the next sync
<!-- cat: {"id":"CAT-SET-03","mode":"visual","requires":["sso"],"look_for":["Admin, Sign-in has the group sync panel with an interval of 60 seconds or more and says it applies at the next sync, no restart needed","Turning group sync on after SSO was set up starts it without a restart","Trigger sync runs one and reports how many groups it read","The container's start time is unchanged"]} -->

- **Steps**: In **Admin, Sign-in**, turn on group sync (set up SSO first if the install was booted without it), save, and click the sync trigger.
- **Expected**: See `look_for`.

### CAT-SET-04 Automation and run health settings apply at the next tick
<!-- cat: {"id":"CAT-SET-04","mode":"visual","look_for":["Admin, Automation says its switches take effect at the next check, no restart needed","Admin, Compute and fan-out, Run health says changes apply at the next check, no restart needed","Saving a value shows its default and that it is overridden","The container's start time is unchanged"]} -->

- **Steps**: Change the check interval on **Admin, Automation** and one run health threshold on **Admin, Compute and fan-out**, and save each.
- **Expected**: See `look_for`.

### CAT-SET-05 A license applied in the app survives a restart
<!-- cat: {"id":"CAT-SET-05","mode":"automatable","requires":["license"],"destructive":true,"depends_on":["CAT-LIC-03"],"check":[{"kind":"cli","run":"${COMPOSE} restart dataloader"},{"kind":"http","method":"GET","path":"/api/v1/health","auth":"none","expect_status":200,"retry":{"every_s":5,"for_s":120}},{"kind":"http","method":"POST","path":"/api/v1/auth/login","auth":"none","body":{"email":"${ADMIN_EMAIL}","password":"${ADMIN_PASSWORD}"},"expect_status":200,"save":{"SESSION":"@cookie"}},{"kind":"http","method":"GET","path":"/api/v1/settings/license","expect_status":200,"expect_json":{"status":"active"}}]} -->

- **Warning**: Restarts the service. Runs in flight are interrupted.
- **Steps**: With the license applied in **Admin, License** (not as a file or `DL_LICENSE_KEY`), restart the service and read the license.
- **Expected**: The license is still `active` and the runner sees it too: a load that needs a licensed feature (for example fan-out) still starts.

---

## 20. Held tables, the bell and Trends

### CAT-OPS-01 A failed table holds its schedule until it is retried
<!-- cat: {"id":"CAT-OPS-01","mode":"automatable","requires":["dest:postgres"],"destructive":true,"depends_on":["CAT-LOAD-01"],"check":[{"kind":"http","method":"POST","path":"/api/v1/table-configs","body":{"connection_id":"${LOAD_SRC_ID}","destination_id":"${DEST_POSTGRES_ID}","environment":"test","source_schema":"${LOAD_SRC_SCHEMA}","source_table":"${LOAD_SRC_TABLE}","dest_schema":"${DEST_POSTGRES_SCHEMA}","dest_table":"cat_hold_pg","load_strategy":"full","compute_mode":"local","cron_schedule":"0 3 * * *","cron_timezone":"${CRON_TZ}","quality_checks":{"enabled":true,"on_failure":"fail","checks":[{"type":"row_count_min","min":1000000000}]}},"expect_status":201,"save":{"TC_HOLD_ID":"id"}},{"kind":"http","method":"POST","path":"/api/v1/table-configs/${TC_HOLD_ID}/run","body":{"env":"test"},"expect_status":202,"save":{"RUN_HOLD_ID":"run_id"}},{"kind":"http","method":"GET","path":"/api/v1/runs/${RUN_HOLD_ID}","expect_status":200,"expect_json":{"run.status":"quality_check_failed"},"retry":{"every_s":5,"for_s":600}},{"kind":"http","method":"GET","path":"/api/v1/dashboard/schedule-overview?env=test","expect_status":200,"expect_json_contains":{"@body":"held"}},{"kind":"http","method":"PUT","path":"/api/v1/table-configs/${TC_HOLD_ID}","body":{"quality_checks":{"enabled":false,"on_failure":"fail","checks":[]}},"expect_status":200},{"kind":"http","method":"DELETE","path":"/api/v1/table-configs/${TC_HOLD_ID}","expect_status":[200,204]}]} -->

- **Warning**: Creates a scheduled table config, makes it fail on purpose, and deletes it at the end.
- **Steps**: Create a table config on a daily schedule with a quality check that cannot pass (a minimum of one billion rows). Run it so its last run ends as Failed or Quality Check Failed. Look at **Automation, Schedule** and the table's page. Then save a change (or run it again, or retry it) and look again.
- **Expected**: While the last run is failed, the table is held: the schedule overview lists it with `paused_reason` `held`, its schedule fires and sensor starts are dropped with the note that the table's last run failed and waits for a retry or a person, and the table page's Schedule tile says it waits until retried. A retry, **Run now**, a successful run, or a save releases the hold. When automatic retries stopped, the reason is `needs_review` and only a person (Run now, or a save) releases it. A webhook or sensor start counts as a sensor start and is held too; a manual run is never held.

### CAT-OPS-02 Held and unscheduled tables read well
<!-- cat: {"id":"CAT-OPS-02","mode":"visual","depends_on":["CAT-OPS-01"],"look_for":["The table's Schedule tile says Paused until retried while the table is held, and says retries stopped when it needs review","Automation, Schedule marks the held table and shows its next run as held, not as a time it will start","Run now on a held table starts a run, and the tile goes back to the next scheduled time after a success","Overview lists a table that needs review under Needs attention"]} -->

- **Steps**: Repeat CAT-OPS-01 up to the failed run without deleting the table, and look at each screen. Then run the table with the check turned off.
- **Expected**: See `look_for`. Delete the table when done.

### CAT-OPS-03 The bell offers the load alerts
<!-- cat: {"id":"CAT-OPS-03","mode":"automatable","depends_on":["CAT-AUTH-03"],"check":[{"kind":"http","method":"GET","path":"/api/v1/notifications/preferences","expect_status":200,"expect_json_contains":{"@body":"load_stuck"}},{"kind":"http","method":"GET","path":"/api/v1/notifications/preferences","expect_status":200,"expect_json_contains":{"@body":"load_overdue"}},{"kind":"http","method":"GET","path":"/api/v1/notifications/preferences","expect_status":200,"expect_json_contains":{"@body":"load_late"}},{"kind":"http","method":"GET","path":"/api/v1/notifications/preferences","expect_status":200,"expect_json_contains":{"@body":"load_needs_review"}}]} -->

- **Steps**: `GET /api/v1/notifications/preferences`, or open the bell's preferences from your account menu.
- **Expected**: The kinds include a load that is stuck, overdue or late, and a table that needs review. They are on by default, because the bell's default is attention only.

### CAT-OPS-04 Stuck, overdue, late and needs-review loads reach the bell
<!-- cat: {"id":"CAT-OPS-04","mode":"visual","depends_on":["CAT-OPS-03"],"look_for":["A load that is stuck, overdue, late or needs review shows in the bell as one item for that table and environment, and is not repeated on the next check","The item closes by itself when the problem clears, the table is paused, or the table is deleted","A notification rule for A load is stuck (or overdue, late, A table needs review) delivers one message to its channel when the item opens","The thresholds are under Admin, Compute and fan-out, Run health"]} -->

- **Preconditions**: A table that can be made to trip one of the rules, for example CAT-OPS-01's table for needs review. If no rule can be tripped on this install, record N/A with a reason.
- **Steps**: Trip one rule, wait for the check (every minute), and open the bell. Clear the cause and look again. Add a rule for the event under **Admin, Notifications** and trip it again.
- **Expected**: See `look_for`.

### CAT-OPS-05 Scheduled fires and start delay are recorded
<!-- cat: {"id":"CAT-OPS-05","mode":"automatable","depends_on":["CAT-SCHED-03"],"check":[{"kind":"http","method":"GET","path":"/api/v1/dashboard/trends?env=test&granularity=week&weeks=12&days=30&tz=${CRON_TZ}","expect_status":200,"expect_json":{"schedule.window_days":"*","schedule.since":"*"}}]} -->

- **Steps**: After the scheduled run in CAT-SCHED-03, `GET /api/v1/dashboard/trends?env=test&granularity=week&weeks=12&days=30&tz=<zone>`.
- **Expected**: 200 with a `schedule` object carrying `window_days` (30) and `since`, the missed fires and the start delay of scheduled runs.

### CAT-OPS-06 Trends shows missed fires and start delay
<!-- cat: {"id":"CAT-OPS-06","mode":"visual","depends_on":["CAT-OPS-05"],"look_for":["Overview, Trends has a Day and Week switch and a line with Missed fires and Start delay (median and p95) beside the tiles","Both say how many days they cover, at most 30","Missed fires opens Runs filtered to scheduled runs","A scheduled run that started more than a minute after its time says Started N min late on the run's page and in the Runs list, and an on-time run says nothing"]} -->

- **Steps**: Open **Overview, Trends** and a scheduled run from CAT-SCHED-03.
- **Expected**: See `look_for`.

---

## 21. In-app help

### CAT-HELP-01 Troubleshooting loads signed out
<!-- cat: {"id":"CAT-HELP-01","mode":"automatable","check":{"kind":"ui","path":"/help/troubleshooting","expect_text":"Troubleshooting","expect_no_console_errors":true}} -->

- **Steps**: In a private window, open `${PUBLIC_URL}/help/troubleshooting`.
- **Expected**: The page loads with no console errors and no sign-in, so a user who cannot reach the server or sign in can still read it.

### CAT-HELP-02 Help opens on a host with no network
<!-- cat: {"id":"CAT-HELP-02","mode":"visual","look_for":["The account menu has Help and docs, and it opens Troubleshooting inside the app","Every error card links to the cause that matches it on that page","The page and its fonts and icons load with the browser's network limited to the DataLoader host (no internet, no CDN)","Back to Overview (signed in) or Back to sign in (signed out) returns to the app"]} -->

- **Steps**: From a machine that can reach DataLoader but nothing else on the internet (or with the browser's network blocked except the DataLoader host), open the account menu and click **Help and docs**. Follow the link on an error card.
- **Expected**: See `look_for`.

---


## 22. Jobs

Jobs are the work DataLoader starts in Databricks or Snowflake. Every case in this section works on one acceptance job that the plan creates. No case touches a job the client already has.

### CAT-JOBS-01 Job list loads and an unknown job is refused
<!-- cat: {"id":"CAT-JOBS-01","mode":"automatable","check":[{"kind":"http","method":"GET","path":"/api/v1/jobs?environment=test&limit=50","auth":"session","expect_status":200,"expect_json":{"jobs":"*","total":"*"}},{"kind":"http","method":"GET","path":"/api/v1/jobs/00000000-0000-0000-0000-000000000000","auth":"session","expect_status":404,"expect_json":{"error":"Job not found"}}]} -->

- **Steps**: Call `GET /api/v1/jobs?environment=test&limit=50`. Then call `GET /api/v1/jobs/00000000-0000-0000-0000-000000000000`, an ID that no job has.
- **Expected**: The list returns 200 with `jobs` and `total`. The unknown job returns 404 with the error "Job not found".

### CAT-JOBS-02 Job list reads well and every link opens its page
<!-- cat: {"id":"CAT-JOBS-02","mode":"visual","look_for":["Each row shows the job name, its type, its connection, its last run, its next run and the assets it updates","Find a job matches part of a job name, and the Type filter shows only jobs of that type","Each column header sorts the list, and the header shows the direction","Clicking a job name opens the job page, and clicking a connection opens that connection","Clicking a last run opens its runs, clicking a next run opens the schedule, and clicking an asset opens that asset","A viewer sees the list and no Create job button"]} -->

- **Steps**: Open `${PUBLIC_URL}/jobs`. Type part of a job name in Find a job, then pick a type. Clear the filters. Click each column header. Click each link in one row. Sign in as the viewer and open the list again.
- **Expected**: See `look_for`.

### CAT-JOBS-03 Validate refuses a job with no name
<!-- cat: {"id":"CAT-JOBS-03","mode":"automatable","check":{"kind":"http","method":"POST","path":"/api/v1/jobs/validate","auth":"session","body":{"name":"","environment":"test","job_type":"databricks","settings":{},"timeout_secs":600},"expect_status":200,"expect_json":{"valid":false,"errors.0.field":"name","errors.0.message":"Give the job a name."}}} -->

- **Steps**: Send the request above, with an empty name. Nothing is saved.
- **Expected**: The response is 200 with `valid` set to false. The first error names the field `name` and says to give the job a name.

### CAT-JOBS-04 Create a job through the API
<!-- cat: {"id":"CAT-JOBS-04","mode":"automatable","check":{"kind":"http","method":"POST","path":"/api/v1/jobs","auth":"session","body":"${JOB_BODY}","expect_status":201,"expect_json":{"name":"*","environment":"test"},"save":{"JOB_ID":"id"}}} -->

- **Steps**: Send `POST /api/v1/jobs` with the value of `JOB_BODY`. The name must start with `acceptance-`.
- **Expected**: The response is 201 with the new job. Its ID is saved for the cases that follow.

### CAT-JOBS-05 Create and edit forms show their messages
<!-- cat: {"id":"CAT-JOBS-05","mode":"visual","depends_on":["CAT-JOBS-04"],"look_for":["On New job, Save with the name empty shows a message under Name and the note \"Fix the fields marked above, then try again.\"","Validate with the values from JOB_BODY shows \"These settings are valid.\"","On Edit job, clearing the name and choosing Save shows the same message under Name","Cancel returns to Jobs on New job, and to the job page on Edit job","The save button reads Create job on New job and Save job on Edit job"]} -->

- **Steps**: Open `${PUBLIC_URL}/jobs/new`. Leave the name empty and choose Save. Enter the values from `JOB_BODY` and choose Validate. Do not choose Save, because CAT-JOBS-04 already made the acceptance job. Open `${PUBLIC_URL}/jobs/${JOB_ID}/edit`, clear the name, and choose Save. Choose Cancel on each form.
- **Expected**: See `look_for`.

### CAT-JOBS-06 Edit saves a job through the API
<!-- cat: {"id":"CAT-JOBS-06","mode":"automatable","depends_on":["CAT-JOBS-04"],"check":{"kind":"http","method":"PATCH","path":"/api/v1/jobs/${JOB_ID}","auth":"session","body":"${JOB_BODY}","expect_status":200,"expect_json":{"id":"${JOB_ID}","name":"*"}}} -->

- **Steps**: Send `PATCH /api/v1/jobs/${JOB_ID}` with the value of `JOB_BODY`.
- **Expected**: The response is 200 with the same job ID and the saved name.

### CAT-JOBS-07 Job page shows the job and its links
<!-- cat: {"id":"CAT-JOBS-07","mode":"visual","depends_on":["CAT-JOBS-04"],"look_for":["The title is the job name, and the page has the sections Settings, Starts it, Runs and Assets it updates","Settings shows the connection, the time limit and the retries","Starts it links to Asset conditions and to Sensors, and each link opens its page","Assets it updates lists each asset as a link, and Open this job on the asset graph opens the asset graph","A viewer sees the page with no Edit, Delete or Run now button"]} -->

- **Steps**: Open `${PUBLIC_URL}/jobs/${JOB_ID}`. Read each section. Click each link in Starts it and in Assets it updates. Sign in as the viewer and open the page again.
- **Expected**: See `look_for`.

### CAT-JOBS-08 Run a job through the API
<!-- cat: {"id":"CAT-JOBS-08","mode":"automatable","depends_on":["CAT-JOBS-04"],"check":{"kind":"http","method":"POST","path":"/api/v1/jobs/${JOB_ID}/run","auth":"session","body":{},"expect_status":202,"expect_json":{"status":"queued","run_id":"*"},"save":{"RUN_ID":"run_id"}}} -->

- **Warning**: Starts a run on the client's Databricks or Snowflake compute. The run uses warehouse time.
- **Steps**: Send `POST /api/v1/jobs/${JOB_ID}/run`.
- **Expected**: The response is 202 with status `queued` and a run ID. The run then shows on the job page in CAT-JOBS-09.

### CAT-JOBS-09 Runs card shows a run, opens its log and stops it
<!-- cat: {"id":"CAT-JOBS-09","mode":"visual","depends_on":["CAT-JOBS-08"],"look_for":["The Runs card on the job page lists the run that CAT-JOBS-08 started, with its status and start time","The start time opens the run's log","A run that is still going has a Stop button, and Stop asks for confirmation before it cancels the run","A run that has ended shows its end state and has no Stop button","All runs opens Runs filtered to this job"]} -->

- **Warning**: If the run is still going, Stop cancels it on the client's compute.
- **Steps**: On `${PUBLIC_URL}/jobs/${JOB_ID}`, read the Runs card. Open the run's log from its start time. Choose Stop on a run that is still going, then Stop run in the dialog. Choose All runs.
- **Expected**: See `look_for`.

### CAT-JOBS-10 Delete removes the acceptance job
<!-- cat: {"id":"CAT-JOBS-10","mode":"automatable","depends_on":["CAT-JOBS-04"],"destructive":true,"check":[{"kind":"http","method":"DELETE","path":"/api/v1/jobs/${JOB_ID}","auth":"session","expect_status":204},{"kind":"http","method":"GET","path":"/api/v1/jobs/${JOB_ID}","auth":"session","expect_status":404,"expect_json":{"error":"Job not found"}}]} -->

- **Warning**: Deletes the acceptance job. Do not point `JOB_BODY` at a job the client uses.
- **Steps**: Send `DELETE /api/v1/jobs/${JOB_ID}`, then request the same job again. This case runs last.
- **Expected**: The delete returns 204. The job then returns 404 with "Job not found".

---

## Sign-off

Record one row per case. Result is Pass, Fail, or N/A. Evidence is a file name, command output, or short note.

| Case ID | Result | Evidence | Tester | Date |
|---|---|---|---|---|
| CAT-HEALTH-01 | | | | |
| CAT-HEALTH-02 | | | | |
| CAT-HEALTH-03 | | | | |
| CAT-HEALTH-04 | | | | |
| CAT-HEALTH-05 | | | | |
| CAT-HEALTH-06 | | | | |
| CAT-HEALTH-07 | | | | |
| CAT-HEALTH-08 | | | | |
| CAT-HEALTH-09 | | | | |
| CAT-HEALTH-10 | | | | |
| CAT-HEALTH-11 | | | | |
| CAT-HEALTH-12 | | | | |
| CAT-HEALTH-13 | | | | |
| CAT-HEALTH-14 | | | | |
| CAT-LIC-01 | | | | |
| CAT-LIC-02 | | | | |
| CAT-LIC-03 | | | | |
| CAT-LIC-04 | | | | |
| CAT-LIC-05 | | | | |
| CAT-LIC-06 | | | | |
| CAT-LIC-07 | | | | |
| CAT-AUTH-01 | | | | |
| CAT-AUTH-02 | | | | |
| CAT-AUTH-03 | | | | |
| CAT-AUTH-04 | | | | |
| CAT-AUTH-05 | | | | |
| CAT-AUTH-06 | | | | |
| CAT-AUTH-07 | | | | |
| CAT-AUTH-08 | | | | |
| CAT-AUTH-09 | | | | |
| CAT-AUTH-10 | | | | |
| CAT-AUTH-11 | | | | |
| CAT-AUTH-12 | | | | |
| CAT-AUTH-13 | | | | |
| CAT-AUTH-14 | | | | |
| CAT-AUTH-15 | | | | |
| CAT-AUTH-16 | | | | |
| CAT-AUTH-17 | | | | |
| CAT-AUTH-18 | | | | |
| CAT-AUTH-19 | | | | |
| CAT-AUTH-20 | | | | |
| CAT-AUTH-21 | | | | |
| CAT-AUTH-22 | | | | |
| CAT-AUTH-23 | | | | |
| CAT-AUTH-24 | | | | |
| CAT-AUTH-25 | | | | |
| CAT-AUTH-26 | | | | |
| CAT-SEC-01 | | | | |
| CAT-SEC-02 | | | | |
| CAT-SEC-03 | | | | |
| CAT-SEC-04 | | | | |
| CAT-CONN-01 | | | | |
| CAT-CONN-02 | | | | |
| CAT-CONN-03 | | | | |
| CAT-CONN-04 | | | | |
| CAT-CONN-05 | | | | |
| CAT-CONN-06 | | | | |
| CAT-CONN-07 | | | | |
| CAT-CONN-08 | | | | |
| CAT-CONN-09 | | | | |
| CAT-CONN-10 | | | | |
| CAT-CONN-11 | | | | |
| CAT-DEST-01 | | | | |
| CAT-DEST-02 | | | | |
| CAT-DEST-03 | | | | |
| CAT-DEST-04 | | | | |
| CAT-DEST-05 | | | | |
| CAT-DEST-06 | | | | |
| CAT-LOAD-01 | | | | |
| CAT-LOAD-02 | | | | |
| CAT-LOAD-03 | | | | |
| CAT-LOAD-04 | | | | |
| CAT-LOAD-05 | | | | |
| CAT-LOAD-06 | | | | |
| CAT-LOAD-07 | | | | |
| CAT-LOAD-08 | | | | |
| CAT-LOAD-09 | | | | |
| CAT-LOAD-10 | | | | |
| CAT-LOAD-11 | | | | |
| CAT-LOAD-12 | | | | |
| CAT-LOAD-13 | | | | |
| CAT-LOAD-14 | | | | |
| CAT-SCHED-01 | | | | |
| CAT-SCHED-02 | | | | |
| CAT-SCHED-03 | | | | |
| CAT-SCHED-04 | | | | |
| CAT-SENS-01 | | | | |
| CAT-SENS-02 | | | | |
| CAT-SENS-03 | | | | |
| CAT-SENS-04 | | | | |
| CAT-SENS-05 | | | | |
| CAT-SENS-06 | | | | |
| CAT-AZ-01 | | | | |
| CAT-AZ-02 | | | | |
| CAT-AZ-03 | | | | |
| CAT-AZ-04 | | | | |
| CAT-AZ-05 | | | | |
| CAT-AZ-06 | | | | |
| CAT-AZ-07 | | | | |
| CAT-AZ-08 | | | | |
| CAT-AZ-09 | | | | |
| CAT-AZ-10 | | | | |
| CAT-AZ-11 | | | | |
| CAT-AZ-12 | | | | |
| CAT-AZ-13 | | | | |
| CAT-AZ-14 | | | | |
| CAT-AZ-15 | | | | |
| CAT-AZ-16 | | | | |
| CAT-AZ-17 | | | | |
| CAT-QC-01 | | | | |
| CAT-QC-02 | | | | |
| CAT-QC-03 | | | | |
| CAT-QC-04 | | | | |
| CAT-QC-05 | | | | |
| CAT-NOTIF-01 | | | | |
| CAT-NOTIF-02 | | | | |
| CAT-NOTIF-03 | | | | |
| CAT-NOTIF-04 | | | | |
| CAT-NOTIF-05 | | | | |
| CAT-NOTIF-06 | | | | |
| CAT-OBS-01 | | | | |
| CAT-OBS-02 | | | | |
| CAT-OBS-03 | | | | |
| CAT-OBS-04 | | | | |
| CAT-OBS-05 | | | | |
| CAT-OBS-06 | | | | |
| CAT-OBS-07 | | | | |
| CAT-UPG-01 | | | | |
| CAT-UPG-02 | | | | |
| CAT-UPG-03 | | | | |
| CAT-UPG-04 | | | | |
| CAT-UPG-05 | | | | |
| CAT-UPG-06 | | | | |
| CAT-UPG-07 | | | | |
| CAT-UPG-08 | | | | |
| CAT-UPG-09 | | | | |
| CAT-UPG-10 | | | | |
| CAT-BAK-01 | | | | |
| CAT-BAK-02 | | | | |
| CAT-BAK-03 | | | | |
| CAT-BAK-04 | | | | |
| CAT-BAK-05 | | | | |
| CAT-BAK-06 | | | | |
| CAT-UI-01 | | | | |
| CAT-UI-02 | | | | |
| CAT-UI-03 | | | | |
| CAT-UI-04 | | | | |
| CAT-UI-05 | | | | |
| CAT-UI-06 | | | | |
| CAT-UI-07 | | | | |
| CAT-UI-08 | | | | |
| CAT-UI-09 | | | | |
| CAT-UI-10 | | | | |
| CAT-UI-11 | | | | |
| CAT-UI-12 | | | | |
| CAT-UI-13 | | | | |
| CAT-ACC-01 | | | | |
| CAT-ACC-02 | | | | |
| CAT-ACC-03 | | | | |
| CAT-ACC-04 | | | | |
| CAT-ACC-05 | | | | |
| CAT-ACC-06 | | | | |
| CAT-DBT-01 | | | | |
| CAT-DBT-02 | | | | |
| CAT-DBT-03 | | | | |
| CAT-AUTO-01 | | | | |
| CAT-AUTO-02 | | | | |
| CAT-AUTO-03 | | | | |
| CAT-AUTO-04 | | | | |
| CAT-AUTO-05 | | | | |
| CAT-AUTO-06 | | | | |
| CAT-SET-01 | | | | |
| CAT-SET-02 | | | | |
| CAT-SET-03 | | | | |
| CAT-SET-04 | | | | |
| CAT-SET-05 | | | | |
| CAT-OPS-01 | | | | |
| CAT-OPS-02 | | | | |
| CAT-OPS-03 | | | | |
| CAT-OPS-04 | | | | |
| CAT-OPS-05 | | | | |
| CAT-OPS-06 | | | | |
| CAT-HELP-01 | | | | |
| CAT-HELP-02 | | | | |
| CAT-JOBS-01 | | | | |
| CAT-JOBS-02 | | | | |
| CAT-JOBS-03 | | | | |
| CAT-JOBS-04 | | | | |
| CAT-JOBS-05 | | | | |
| CAT-JOBS-06 | | | | |
| CAT-JOBS-07 | | | | |
| CAT-JOBS-08 | | | | |
| CAT-JOBS-09 | | | | |
| CAT-JOBS-10 | | | | |

Client sign-off:

| Role | Name | Signature | Date |
|---|---|---|---|
| Client IT owner | | | |
| System integrator | | | |

