# Client runbook: Snowflake source and destination

This runbook is for a client's Snowflake admin, with help from an Azure (or
AWS) admin for the stage. Follow it before the system integrator (SI) arrives.
When it is done, DataLoader can test its Snowflake connections, read a
Snowflake table and load a table into Snowflake through an external stage.

Skip this runbook if the client uses Snowflake neither as a source nor as a
destination. Each step says whether it applies to the source, the destination
or both.

Every step names who runs it, what to run, and the check that proves it
worked. Replace every `<placeholder>`. The names in capitals (`DL_LOADER`,
`DL_WH`) are suggestions; use the client's own naming if it has one.

For how loads use the stage, see Snowflake destination: one-time stage
setup. For every other runbook, see the
runbook index.

## Who does what

| Role | Needed for | Snowflake or cloud role |
|---|---|---|
| Snowflake admin | Warehouse, resource monitor, storage integration (steps 2, 5) | `ACCOUNTADMIN` |
| Snowflake admin | Roles, users and grants (steps 3, 4, 6) | `SECURITYADMIN`, plus the owner of each database (often `SYSADMIN`) |
| Azure admin | Storage account, role assignments (step 5) | Contributor and User Access Administrator on the storage account |
| Entra consent admin | Consent for Snowflake's app in the tenant (step 5) | Global Administrator, Cloud Application Administrator or Application Administrator |
| DataLoader admin | The sign-in (managed identity or key pair), Key Vault, the connections (steps 1, 7, 8) | DataLoader admin, and Key Vault Secrets Officer on the vault for a key pair |

## A tip for Snowsight

In a Snowsight worksheet, **Run all** can fail with a statement count error on
a script this long. Run one statement at a time: put the cursor in the
statement and press Ctrl+Enter (Cmd+Return on a Mac).

## Before you start

- A Snowflake account and the role list above.
- The Key Vault DataLoader reads, registered in DataLoader (see steps 3 and 4
  of the [Azure runbook](client-azure-identity-vault-sso-databricks.md)).
- For the destination: an Azure storage account or an S3 bucket for the
  stage, in the same region as the Snowflake account.
- Snowflake's account identifier. As `ACCOUNTADMIN`, run:

  ```sql
  SELECT CURRENT_ORGANIZATION_NAME() AS org, CURRENT_ACCOUNT_NAME() AS account, CURRENT_REGION() AS region;
  ```

  DataLoader's account field takes `<org>-<account>` from that row.

---

## 1. Pick the sign-in, and make the key pair if you need one

**Applies to**: both. **Who**: DataLoader admin.

The source and the destination each sign in as a Snowflake service user, with
no password. Pick one sign-in for both:

- **Managed identity**, when DataLoader runs on Azure (a VM with
  `install.sh --managed-identity`, or Container Apps with the identity on).
  Snowflake trusts DataLoader's Azure identity through workload identity
  federation, so nothing is stored anywhere. Use it whenever you can.
- **Key pair**, when DataLoader runs outside Azure. The private key lives in
  Key Vault.

An OAuth token also works for a connection test, but it expires within hours,
so a schedule fails once it does. Don't use one for production loads.

### Managed identity

Find DataLoader's identity. **Settings, Key Vaults** shows it under "Managed
identity" with its object id, or ask Azure:

```bash
az vm identity show --name <vm-name> --resource-group <resource-group> --query principalId -o tsv
# or, on Container Apps:
az containerapp identity show --name <app-name> --resource-group <resource-group> --query principalId -o tsv
# and the tenant:
az account show --query tenantId -o tsv
```

The first prints `<dataloader-identity-object-id>`, the last `<tenant-id>`.
For a user-assigned identity, use `az identity show --name <identity-name>
--resource-group <resource-group> --query principalId -o tsv`. Skip the rest of
this step.

**Check**: the object id is a GUID, and it matches the one DataLoader shows.

### Key pair

DataLoader needs an unencrypted PKCS#8 private key.

```bash
openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out rsa_key.p8 -nocrypt
openssl rsa -in rsa_key.p8 -pubout -out rsa_key.pub
az keyvault secret set --vault-name <vault-name> --name <snowflake-key-secret> --file rsa_key.p8
```

Give the Snowflake admin `rsa_key.pub` (the public key is not a secret). Then
delete `rsa_key.p8` from disk. The private key lives only in the vault, never
in a file or a config.

If DataLoader's identity has Key Vault Secrets User on single secrets, grant it
on this secret too (Azure runbook, step 3).

**Check**:

```bash
az keyvault secret show --vault-name <vault-name> --name <snowflake-key-secret> --query name -o tsv
openssl rsa -pubin -in rsa_key.pub -outform DER | openssl dgst -sha256 -binary | openssl enc -base64
```

The first prints the secret name. The second prints the key's fingerprint:
keep it for the check in step 4.

## 2. Create the warehouse with a credit cap

**Applies to**: both. **Who**: Snowflake admin, as `ACCOUNTADMIN`.

```sql
USE ROLE ACCOUNTADMIN;

CREATE RESOURCE MONITOR IF NOT EXISTS DL_RM
  WITH CREDIT_QUOTA = <monthly-credits> FREQUENCY = MONTHLY START_TIMESTAMP = IMMEDIATELY
  TRIGGERS ON 90 PERCENT DO NOTIFY
           ON 100 PERCENT DO SUSPEND;

CREATE WAREHOUSE IF NOT EXISTS DL_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE INITIALLY_SUSPENDED = TRUE
  RESOURCE_MONITOR = DL_RM;
```

`SUSPEND` lets running queries finish and then stops the warehouse. Pick the
quota with the client; an X-Small warehouse uses 1 credit per running hour.
A client that runs the source and the destination on different budgets can
make one warehouse and monitor for each.

**Check**:

```sql
SHOW RESOURCE MONITORS LIKE 'DL_RM';
SHOW WAREHOUSES LIKE 'DL_WH';
```

The monitor shows the quota, and the warehouse's `resource_monitor` column
reads `DL_RM`.

## 3. Create the roles and grant least privilege

**Applies to**: see each part. **Who**: Snowflake admin, as `SECURITYADMIN`
(and the database owner for the grants on existing objects).

DataLoader uses one role per connection. Make a read role for the source and a
load role for the destination. A client that uses Snowflake as both source and
destination makes both roles; keep them separate, so the loader cannot read
more than it loads and the reader cannot write.

### Source: `DL_READER`

```sql
USE ROLE SECURITYADMIN;
CREATE ROLE IF NOT EXISTS DL_READER;
GRANT USAGE ON WAREHOUSE DL_WH TO ROLE DL_READER;
GRANT USAGE ON DATABASE <source-database> TO ROLE DL_READER;
-- Repeat for every schema DataLoader reads.
GRANT USAGE ON SCHEMA <source-database>.<source-schema> TO ROLE DL_READER;
GRANT SELECT ON ALL TABLES IN SCHEMA <source-database>.<source-schema> TO ROLE DL_READER;
GRANT SELECT ON ALL VIEWS IN SCHEMA <source-database>.<source-schema> TO ROLE DL_READER;
GRANT SELECT ON FUTURE TABLES IN SCHEMA <source-database>.<source-schema> TO ROLE DL_READER;
GRANT SELECT ON FUTURE VIEWS IN SCHEMA <source-database>.<source-schema> TO ROLE DL_READER;
```

The catalog, row counts and primary keys come from each database's
`INFORMATION_SCHEMA`, which shows only the objects the role can use. No other
grant is needed.

### Destination: `DL_LOADER`

```sql
USE ROLE SECURITYADMIN;
CREATE ROLE IF NOT EXISTS DL_LOADER;
GRANT USAGE ON WAREHOUSE DL_WH TO ROLE DL_LOADER;
GRANT USAGE ON DATABASE <target-database> TO ROLE DL_LOADER;

-- DataLoader creates a missing target schema only when the role has
-- CREATE SCHEMA on the database. Without that grant, create each target
-- schema first (as the database owner), then grant it. Repeat for every
-- target schema. To let a first run create them instead:
--   GRANT CREATE SCHEMA ON DATABASE <target-database> TO ROLE DL_LOADER;
CREATE SCHEMA IF NOT EXISTS <target-database>.<target-schema>;
GRANT USAGE, CREATE TABLE ON SCHEMA <target-database>.<target-schema> TO ROLE DL_LOADER;

-- The schema that holds the stage (step 5).
CREATE SCHEMA IF NOT EXISTS <target-database>.DATALOADER;
GRANT USAGE ON SCHEMA <target-database>.DATALOADER TO ROLE DL_LOADER;
```

`CREATE TABLE` covers the tables DataLoader creates and the transient
`DL_STG_*` tables it creates and drops during Full and Merge loads. The role
owns what it creates. For a table that already exists and DataLoader should
load, grant:

```sql
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLE <target-database>.<target-schema>.<table> TO ROLE DL_LOADER;
```

### Both

Run both parts above. Nothing else is shared, except the warehouse.

**Check**, per role:

```sql
SHOW GRANTS TO ROLE DL_READER;
SHOW GRANTS TO ROLE DL_LOADER;
```

`DL_READER` has `USAGE` and `SELECT` only. `DL_LOADER` has `USAGE` and
`CREATE TABLE`, plus the table grants you added, and no `SELECT` on the source
schemas.

## 4. Create the service users

**Applies to**: both. **Who**: Snowflake admin, as `SECURITYADMIN`.

Make `DL_LOADER_SVC` for the destination and `DL_READER_SVC` for the source,
with the sign-in you picked in step 1. `TYPE = SERVICE` means the user cannot
sign in with a password or through the browser.

### Managed identity

This sign-in names no user: Snowflake finds the user from the identity, so
DataLoader's identity backs one Snowflake user. When the client uses Snowflake
as both source and destination, make one user, `DL_SVC`, and grant it both
roles instead of making two users; each connection still sets its own role.

```sql
USE ROLE SECURITYADMIN;
CREATE USER IF NOT EXISTS DL_LOADER_SVC
  WORKLOAD_IDENTITY = (
    TYPE = AZURE
    ISSUER = 'https://login.microsoftonline.com/<tenant-id>/v2.0'
    SUBJECT = '<dataloader-identity-object-id>'
  )
  TYPE = SERVICE
  DEFAULT_ROLE = DL_LOADER
  DEFAULT_WAREHOUSE = DL_WH;
GRANT ROLE DL_LOADER TO USER DL_LOADER_SVC;
```

For a source alone, run the same with `DL_READER_SVC` and `DL_READER`. For
both source and destination, run this instead:

```sql
USE ROLE SECURITYADMIN;
CREATE USER IF NOT EXISTS DL_SVC
  WORKLOAD_IDENTITY = (
    TYPE = AZURE
    ISSUER = 'https://login.microsoftonline.com/<tenant-id>/v2.0'
    SUBJECT = '<dataloader-identity-object-id>'
  )
  TYPE = SERVICE
  DEFAULT_ROLE = DL_READER
  DEFAULT_WAREHOUSE = DL_WH;
GRANT ROLE DL_READER TO USER DL_SVC;
GRANT ROLE DL_LOADER TO USER DL_SVC;
```

Set **Role** to `DL_READER` on the source and `DL_LOADER` on the destination
(step 7), so each connection runs with its own role.

**Check**:

```sql
SHOW USER WORKLOAD IDENTITY AUTHENTICATION METHODS FOR USER DL_LOADER_SVC;
```

It lists one `AZURE` method whose subject is DataLoader's object id.

### Key pair

```sql
USE ROLE SECURITYADMIN;
CREATE USER IF NOT EXISTS DL_LOADER_SVC
  TYPE = SERVICE
  DEFAULT_ROLE = DL_LOADER
  DEFAULT_WAREHOUSE = DL_WH
  RSA_PUBLIC_KEY = '<contents of rsa_key.pub without the BEGIN and END lines>';
GRANT ROLE DL_LOADER TO USER DL_LOADER_SVC;
```

For the source, run the same with `DL_READER_SVC` and `DL_READER`. The two
users can share the public key, or you can make a second key pair in step 1.

**Check**:

```sql
DESC USER DL_LOADER_SVC;
```

`TYPE` is `SERVICE`, `HAS_PASSWORD` is `false`, and `RSA_PUBLIC_KEY_FP` is
`SHA256:` followed by the fingerprint from step 1.

## 5. Create the external stage

**Applies to**: destination. **Who**: Azure admin, Entra consent admin and
Snowflake admin, in the order below.

DataLoader loads Snowflake through an external stage: it uploads Parquet files
to the stage's container with its own credentials, then runs `COPY INTO`.
Snowflake reads the files through a storage integration. Internal stages are
not supported.

### Azure

1. **Storage account and container** (Azure admin). Use StorageV2 with
   hierarchical namespace on, in the Snowflake account's region. Turn off
   shared key access and public access.

   ```bash
   az storage account create --name <storage-account> --resource-group <resource-group> \
     --location <region> --kind StorageV2 --sku Standard_LRS --hns true \
     --allow-shared-key-access false --allow-blob-public-access false
   az storage container-rm create --storage-account <storage-account> --resource-group <resource-group> \
     --name <stage-container>
   ```

2. **Storage integration** (Snowflake admin, `ACCOUNTADMIN`):

   ```sql
   USE ROLE ACCOUNTADMIN;
   CREATE STORAGE INTEGRATION IF NOT EXISTS DL_STAGE_INT
     TYPE = EXTERNAL_STAGE
     STORAGE_PROVIDER = 'AZURE'
     ENABLED = TRUE
     AZURE_TENANT_ID = '<tenant-id>'
     STORAGE_ALLOWED_LOCATIONS = ('azure://<storage-account>.blob.core.windows.net/<stage-container>/');
   DESC STORAGE INTEGRATION DL_STAGE_INT;
   ```

   Note `AZURE_CONSENT_URL` and `AZURE_MULTI_TENANT_APP_NAME` from the output.

3. **Consent** (Entra consent admin). Open `AZURE_CONSENT_URL` and accept.
   This adds Snowflake's app to the tenant. `AZURE_MULTI_TENANT_APP_NAME`
   looks like `<name>_<number>`; the app's display name is `<name>`.

4. **Let Snowflake read the container** (Azure admin). Grant Snowflake's app
   Storage Blob Data Reader on the container only. It reads the staged files;
   DataLoader deletes them itself.

   ```bash
   az ad sp list --display-name <snowflake-app-name> --query "[].id" -o tsv   # <snowflake-sp-object-id>
   az role assignment create --role "Storage Blob Data Reader" \
     --assignee-object-id <snowflake-sp-object-id> --assignee-principal-type ServicePrincipal \
     --scope "$(az storage account show --name <storage-account> --query id -o tsv)/blobServices/default/containers/<stage-container>"
   ```

5. **Let DataLoader write the container** (Azure admin). DataLoader uploads
   and deletes staged files with its managed identity when the destination
   has no stage credentials. Grant the identity from step 1 Storage Blob Data
   Contributor on the container only:

   ```bash
   az role assignment create --role "Storage Blob Data Contributor" \
     --assignee-object-id <dataloader-identity-object-id> --assignee-principal-type ServicePrincipal \
     --scope "$(az storage account show --name <storage-account> --query id -o tsv)/blobServices/default/containers/<stage-container>"
   ```

   Nothing is stored, and the Azure fields on the destination stay blank.

   When DataLoader runs outside Azure, it has no managed identity. Make a
   service principal with the same role instead, and store its secret in Key
   Vault:

   ```bash
   az ad sp create-for-rbac --name <dataloader-stage-sp> --role "Storage Blob Data Contributor" \
     --scopes "$(az storage account show --name <storage-account> --query id -o tsv)/blobServices/default/containers/<stage-container>"
   az keyvault secret set --vault-name <vault-name> --name <stage-sp-secret> --value '<password from the output>'
   ```

   The output's `appId` is `<stage-sp-client-id>` and `tenant` is
   `<tenant-id>`. The destination form also takes a SAS token with read,
   write, delete and list. A user delegation SAS expires within 7 days, so use
   it for a first test only.

6. **The stage** (Snowflake admin, `ACCOUNTADMIN`):

   ```sql
   USE ROLE ACCOUNTADMIN;
   CREATE STAGE IF NOT EXISTS <target-database>.DATALOADER.DL_STAGE
     STORAGE_INTEGRATION = DL_STAGE_INT
     URL = 'azure://<storage-account>.blob.core.windows.net/<stage-container>/';
   GRANT USAGE ON STAGE <target-database>.DATALOADER.DL_STAGE TO ROLE DL_LOADER;
   ```

   The loader role gets `USAGE` on the stage only, not on the integration.

**Check**, as the loader:

```sql
USE ROLE DL_LOADER;
DESC STAGE <target-database>.DATALOADER.DL_STAGE;
LIST @<target-database>.DATALOADER.DL_STAGE;
```

`DESC` shows the `azure://` URL, and `LIST` returns without an error (no rows
on a new container). An access error from `LIST` means consent (3) or the
Reader role (4) is missing. Role assignments can take a few minutes to apply.

### S3

For a stage on S3, follow section 2b of the stage setup:
an IAM policy and role that Snowflake assumes with the integration's external
ID, and `s3:PutObject` and `s3:DeleteObject` on the bucket prefix for
DataLoader. Then create the stage as in part 6 above with the `s3://` URL, and
run the same check.

## 6. Check the source's sign-in user

**Applies to**: source. **Who**: Snowflake admin.

The source signs in the same way as the destination: with the managed
identity or the key pair from step 1, as the service user from step 4
(`DL_READER_SVC`, or `DL_SVC` when one identity serves both). DataLoader signs
in again for every request, so scheduled reads keep working.

**Check**: `SHOW GRANTS TO USER DL_READER_SVC;` (or `DL_SVC`) lists
`DL_READER`.

## 7. Add the destination in DataLoader

**Applies to**: destination. **Who**: DataLoader admin.

**Connections, + New destination, Snowflake**, shape **Components**:

| Field | Value |
|---|---|
| Account locator | `<org>-<account>` from "Before you start" |
| Sign in with | **Managed identity (Azure)**, or **Key pair** |
| User | Key pair only: `DL_LOADER_SVC` |
| Private key | Key pair only: `kv://<vault-name>/<snowflake-key-secret>` |
| Warehouse | `DL_WH` |
| Database | `<target-database>` |
| Role | `DL_LOADER` |
| External stage | `<target-database>.DATALOADER.DL_STAGE` |
| Stage storage | `ADLS` (or `S3`) |
| Azure tenant ID, client ID, client secret, SAS token | Blank with the managed identity. With a service principal: `<tenant-id>`, `<stage-sp-client-id>`, `kv://<vault-name>/<stage-sp-secret>` |

A new Snowflake destination starts on **Managed identity (Azure)** when
DataLoader has one, and on **Key pair** otherwise. For an S3 stage, fill **S3
region** instead, and the S3 keys, or leave the keys blank to use the host's
AWS credentials.

**Check**:

1. **Test Destination** says "Connected to Snowflake account `<org>-<account>`".
   This proves the sign-in, the user, the role and the warehouse. It does not
   touch the stage. When it fails, it says which sign-in Snowflake refused:
   - "the Snowflake user for this identity isn't set up": the user from step 4
     is missing, or its `SUBJECT` is not DataLoader's object id, or its
     `ISSUER` names another tenant.
   - "refused the key-pair sign-in": the public key on the user does not
     match the private key in the vault, or the account or user is wrong.
2. Load one table (step 8). That is the check for the stage.

## 8. Prove a read and a load

**Who**: DataLoader admin.

**Source** (if the client uses one): **Connections, + New source, Snowflake**,
shape **Components**, with **Account**, **Warehouse** (`DL_WH`), **Database**,
**Schema**, **Role** (`DL_READER`), and **Sign in with** as in step 7 (for a
key pair, **User** `DL_READER_SVC` and the private key's `kv://` reference).

- **Test connection** says "Connected to Snowflake account ...".
- **Catalog** on the connection lists the schema's tables. Open one and click
  **Preview 10 rows**: the rows appear.

**Destination**: add one small table from any source with the Snowflake
destination, and **Run now** in TEST.

- The run succeeds, and its rows written match the source.
- In Snowflake, as `DL_LOADER`:
  `SELECT COUNT(*) FROM <target-database>.<target-schema>.<table>;` returns
  that count.
- `LIST @<target-database>.DATALOADER.DL_STAGE;` is empty again: DataLoader
  deletes staged files after each chunk commits. Files left under `dl/` mean
  a chunk failed; the run log says why.

If the COPY fails with an access or "not authorized" error, Snowflake cannot
read the container: check consent and the Reader role in step 5. If the
upload fails, DataLoader's identity (or service principal) lacks Storage Blob
Data Contributor on the container; the error names the container. See the troubleshooting table in the stage setup.

---

## Final check

| Check | Step |
|---|---|
| The resource monitor caps `DL_WH` | 2 |
| `DL_READER` can only read; `DL_LOADER` can only load | 3 |
| The service users have no password, and carry DataLoader's identity or the right key fingerprint | 4 |
| `LIST` on the stage works as `DL_LOADER` | 5 |
| The destination's **Test Destination** passes | 7 |
| A TEST load lands the right row count, and the stage is empty after | 8 |
| The source's **Test connection** passes and **Preview 10 rows** shows rows, if the client uses a Snowflake source | 8 |

## Worksheet

Hand this to the SI. None of these are secrets; with a key pair, the private
key and any stage secret stay in the vault.

| Value | From step | Value |
|---|---|---|
| `<org>-<account>` | before you start | |
| Sign-in: managed identity (object id, tenant) or key pair | 1 | |
| Warehouse, resource monitor | 2 | |
| Source database and schemas, read role | 3 | |
| Target database and schemas, load role | 3 | |
| Service users | 4 | |
| Stage name and URL | 5 | |
| Stage upload: managed identity, or `<stage-sp-client-id>` and `<tenant-id>` | 5 | |
| `kv://` references for the private key and any stage secret | 1, 5 | |
