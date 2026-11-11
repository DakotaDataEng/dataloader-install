# Client runbook: Azure identity, Key Vault, SSO and Databricks

This runbook is for a client's Azure, Entra and Databricks admins. Follow it
before the system integrator (SI) arrives. When it is done, DataLoader runs on
an Azure VM as its own managed identity, reads secrets from Key Vault, signs
users in with Microsoft Entra ID, and loads into Databricks. It stores no
client secret and no personal access token to do any of that.

Every step names who runs it, what to run or click, and the check that proves
it worked. Do the steps in order: later steps use values that earlier steps
print. Keep those values in the worksheet at the end.

Replace every `<placeholder>`. Nothing in this page is a real name or ID,
except the Microsoft Graph IDs in step 9, which are the same in every tenant.

For the install itself, see [Install DataLoader on a Linux host](install-linux-host.md).
For every other runbook and the order they go in, see the runbook index.

## Who does what

| Role | Needed for | Minimum Azure or Databricks role |
|---|---|---|
| Azure admin | The Azure resources, the VM identity, Key Vault, role assignments (steps 0 to 5) | Contributor on the resource group, plus User Access Administrator (or Owner) to assign roles |
| Host admin | The install (step 2) | `sudo` on the VM |
| Entra admin | The SSO app registration (steps 6 to 8) | Application Administrator |
| Entra consent admin | Admin consent for a Microsoft Graph application permission (step 9) | Global Administrator or Privileged Role Administrator. Cloud Application Administrator and Application Administrator cannot grant Microsoft Graph application permissions. |
| DataLoader admin | Settings inside DataLoader (steps 4, 5, 10, 12) | The bootstrap admin from the install |
| Databricks admin | The service principal, warehouse and grants (step 11) | Workspace admin, plus ownership of (or `MANAGE` on) the catalog |

Book the Entra consent admin for step 9 ahead of time. It is the step most
often left waiting.

## Before you start

- An Azure subscription and resource group for DataLoader.
- A Linux VM (Ubuntu 22.04 or later) with Docker Engine 24+ and the
  `docker compose` plugin 2.24+, as [install-linux-host.md](install-linux-host.md) lists.
- A DNS name and a TLS certificate for DataLoader, for example
  `https://<dataloader-host>`. Microsoft sign-in only works over HTTPS.
- An Azure Databricks workspace with Unity Catalog and a SQL warehouse, if
  DataLoader loads into Databricks.
- The Azure CLI (`az`), signed in with `az login` to the client's tenant.

## 0. Provision the Azure resources with one command

**Who**: Azure admin.

`scripts/azure/provision.sh` creates the Azure resources DataLoader needs
into one resource group, and prints the values the later steps and the setup
use. It covers the identity half of step 1 (a user-assigned identity instead
of the VM's system-assigned one), all of step 3, and the fan-out resources.
Steps 2 and 4 to 12 are still done by hand.

| What it creates | Name | Notes |
|---|---|---|
| The resource group | `--resource-group` | Only when it does not exist yet |
| A user-assigned managed identity | `<prefix>-identity` | Attached to the VM with `--vm` |
| A TEST and a PROD Key Vault | `<prefix>-kv-<hash>`, `<prefix>-kvp-<hash>` | Azure RBAC authorization. Key Vault Secrets User for the identity on each. `--single-vault` makes one vault for both environments. |
| A container registry, Basic | `<prefix>acr<hash>` | About $5 a month. The `dataloader` and `dataloader-worker` images of `--tag` are imported from `acrdakotadataloader.azurecr.io`. AcrPull for the identity. |
| An Azure Container Apps environment | `<prefix>-aca-env` | Consumption plan: nothing is billed while no fan-out runs. No logs, unless `--log-analytics` also creates a Log Analytics workspace, billed per GB it takes in. |
| The fan-out job | `shared` | Manual trigger, 1 CPU and 2 GiB per partition, pulls from the registry as the identity. DataLoader 1.0 dispatches to this fixed name. |
| Role assignments | | Reader and Container Apps Jobs Contributor on the resource group, and Managed Identity Operator on the identity, for the identity and for `--arm-principal` when given |

`<prefix>` is `dataloader` unless you pass `--prefix`. `<hash>` is six
characters derived from the subscription and resource group: vault and
registry names are global across Azure, so this keeps clients apart and gives
a re-run the same names.

The Azure admin needs Contributor and User Access Administrator (or Owner) on
the resource group, or on the subscription when the script creates the
group.

Look first, with `--dry-run`. It runs the reads and prints every `az`
command it would run, without changing anything:

```bash
bash scripts/azure/provision.sh up --subscription <subscription-id> \
  --resource-group <resource-group> --location <region> --tag <release-tag> \
  --vm <vm-name> --dry-run
```

Then run it:

```bash
bash scripts/azure/provision.sh up --subscription <subscription-id> \
  --resource-group <resource-group> --location <region> --tag <release-tag> \
  --vm <vm-name>
```

It prints one line for each resource, then the outputs, and writes them to
`./dataloader-azure.json` (`--output` picks another file):

```json
{
  "tenant_id": "<tenant-id>",
  "location": "<region>",
  "vaults": {
    "test": { "name": "dataloader-kv-<hash>", "uri": "https://dataloader-kv-<hash>.vault.azure.net/" },
    "prod": { "name": "dataloader-kvp-<hash>", "uri": "https://dataloader-kvp-<hash>.vault.azure.net/" }
  },
  "managed_identity": {
    "client_id": "<identity-client-id>",
    "principal_id": "<identity-object-id>",
    "resource_id": "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/dataloader-identity"
  },
  "compute_backend": {
    "subscription_id": "<subscription-id>",
    "resource_group": "<resource-group>",
    "managed_identity_client_id": "<identity-client-id>",
    "container_image_tag": "<release-tag>",
    "container_registry_url": "dataloaderacr<hash>.azurecr.io"
  },
  "runtime": {
    "aca_subscription_id": "<subscription-id>",
    "aca_resource_group": "<resource-group>",
    "aca_environment_id": "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.App/managedEnvironments/dataloader-aca-env",
    "aca_worker_image": "dataloaderacr<hash>.azurecr.io/dataloader-worker:<release-tag>",
    "aca_managed_identity_resource_id": "/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.ManagedIdentity/userAssignedIdentities/dataloader-identity"
  },
  "aca_job_name": "shared"
}
```

Where the values go:

| Output | Used in |
|---|---|
| `vaults.test`, `vaults.prod` | Step 4: register each vault, and set the TEST vault's **PROD reads** to the PROD vault |
| `managed_identity.client_id` | Step 2: `AZURE_CLIENT_ID=<identity-client-id>` in `.env`, since the identity is user-assigned |
| `managed_identity.principal_id` | `<identity-object-id>` in steps 7 and 11. Read `<identity-app-id>` with `az ad sp show --id <identity-object-id> --query appId -o tsv` |
| `compute_backend` | The body of `PUT /api/v1/settings/compute-backend` |
| `runtime` | The body of `PATCH /api/v1/settings/runtime` |

**Fan-out sign-in to Azure.** DataLoader uses its managed identity by default when the host has one. Choose the sign-in in **Admin, Compute and fan-out**, under **Fan-out sign-in to Azure**. The saved choice applies to the next dispatch, Re-provision and Test without a restart. Use a service principal secret only when DataLoader runs on a host outside Azure or when retaining an existing saved choice. For that fallback, save the tenant ID, client ID and secret in Admin. The setup script does not create the service principal or secret. Pass its object ID as `--arm-principal <object-id>` when provisioning.

**Promotion and the PROD vault.** Promotion from TEST to PROD can copy a
missing secret into the PROD vault only when DataLoader has Key Vault Secrets
Officer on it. `--prod-vault-write` grants that on the PROD vault, nothing
else. Without it, promotion stops and says DataLoader is not allowed to write
secrets there, and an admin adds the secret by hand.

**Re-running** is safe: each step checks before it creates, so a second run
changes nothing. Run it again with a new `--tag` to import a new release's
images. If a run stops part way (a role assignment can take a few minutes to
apply), fix the cause and run the same command again.

**What it refuses**:

- The resource group `dakota_group1`.
- A Key Vault access policy. It never runs `az keyvault set-policy`, never
  turns RBAC authorization off, and stops on an existing vault of the same
  name that uses access policies.
- A vault or registry name already used by another resource group, or a
  soft-deleted vault of the same name. The message says how to recover or
  purge it, or pass `--vault-name`, `--prod-vault-name` or `--registry-name`.

A resource of the same name that already exists in the group is used as it
is. The plan says `exists, not created by this script`, and teardown keeps it.

**Check**: the second run prints `exists` on every line and creates nothing,
and `az resource list -g <resource-group> --query "[?tags.\"dataloader-provisioned\"!=null].[name,tags.\"dataloader-provisioned\"]" -o table`
lists what the script made.

The first `up` picks a run id and writes it to the group's
`dataloader-run-id` tag. A group that `up` creates also gets
`dataloader-rg-created-by=<run id>`. Each resource `up` creates is tagged
`dataloader-provisioned=provision.sh:<subscription>/<resource-group>/<run id>`,
and each role assignment it makes has the description
`dataloader-provisioned=provision.sh:<subscription>/<resource-group>/<run id>`.

### Teardown

`down` removes what `up` created and nothing else. It reads the run id from
the group, then deletes the role assignments with that exact description (on
the group and on each vault, registry and identity in it), the resources in
the group with that exact tag, and the group only when its
`dataloader-rg-created-by` tag is the run id and nothing else is left in it.
A group with no `dataloader-run-id` tag is left alone. The dry run makes the
same decision about the group: it prints `keep` when other resources remain.

```bash
bash scripts/azure/provision.sh down --subscription <subscription-id> \
  --resource-group <resource-group> --vm <vm-name> --dry-run
bash scripts/azure/provision.sh down --subscription <subscription-id> \
  --resource-group <resource-group> --vm <vm-name> --yes
```

`--vm` detaches the identity from the VM first. A deleted Key Vault stays
soft-deleted for its retention period, and its name stays taken, so a later
`up` with the same names stops on it. `--purge-vault` purges the vaults too.
Their secrets are then gone for good.

---

## 1. Turn on the VM's managed identity

**Who**: Azure admin.

If step 0 ran with `--vm`, the VM already has the user-assigned identity:
take `<identity-object-id>` from `managed_identity.principal_id` in its
outputs, read `<identity-app-id>` as below, and skip to step 2.

```bash
az vm identity assign --name <vm-name> --resource-group <resource-group>
```

This turns on the VM's system-assigned identity. A user-assigned identity also
works: attach it to the VM, and set `AZURE_CLIENT_ID=<identity-client-id>` in
DataLoader's `.env` in step 2.

Read the identity's two IDs. Both are needed later.

```bash
# The object ID (Azure calls it principalId): role assignments and the SSO federated credential use it.
az vm identity show --name <vm-name> --resource-group <resource-group> --query principalId -o tsv

# The application ID: Databricks uses it.
az ad sp show --id <identity-object-id> --query appId -o tsv
```

**Check**: both commands print a GUID. Write them in the worksheet as
`<identity-object-id>` and `<identity-app-id>`.

## 2. Install DataLoader with `--managed-identity`

**Who**: host admin.

On an Azure VM, DataLoader uses the VM's identity only when the installer is
told to. It never probes the metadata service to guess. Without the flag,
DataLoader has no identity, and every vault and Databricks sign-in fails.

```bash
TAG=<release-tag>
docker run --rm --entrypoint cat acrdakotadataloader.azurecr.io/dataloader:$TAG \
  /opt/dataloader/deploy/install.sh > install.sh
sudo bash install.sh --tag $TAG --bootstrap-admin-email <admin-email> --managed-identity \
  --key-vault <vault-name> \
  --check-endpoint <workspace-host>
```

The `--key-vault` and `--check-endpoint` flags are optional and repeatable.
They test DNS and HTTPS to each host before anything changes;
`login.microsoftonline.com` and the registry are always tested. Add
`--dry-run` to run only the checks. Put a TLS reverse proxy in front afterwards, as
[install-linux-host.md](install-linux-host.md) describes.

**A host already installed without the flag**: copy `install.sh` out of the
running image the same way and run it again with `--managed-identity`. The
re-run keeps `.env`, adds the key, refreshes the compose file and restarts
DataLoader.

**Check**:

```bash
sudo grep ^DL_AZURE_MANAGED_IDENTITY= /opt/dataloader/.env   # prints DL_AZURE_MANAGED_IDENTITY=imds
```

Then, signed in to DataLoader as the bootstrap admin: **Admin, Key vaults,
+ Register a vault**. With **Managed identity** picked, the form shows
`Object ID: <identity-object-id>`, the same GUID as step 1. If it says
"DataLoader has no managed identity on this host", the flag is missing or the
VM identity is off. Cancel the form; step 4 registers the vault.

## 3. Create the Key Vaults and grant the identity

**Who**: Azure admin.

For separate vaults, step 0 already made both with RBAC and granted the identity Key Vault
Secrets User on the whole of each. Skip to the check, unless the client wants
the role on single secrets instead.

DataLoader reads secrets (source passwords, the Snowflake private key) from
Key Vault by reference (`kv://<vault-name>/<secret-name>`). Use two vaults: one
that TEST runs read, and a prod counterpart that PROD runs read. A PROD run
never falls back to the TEST vault.

One vault can serve both environments when they share secrets. Grant the identity access to that vault and register it as **Both TEST and PROD** in step 4.

Create both with Azure RBAC, not access policies:

```bash
az keyvault create --name <test-vault-name> --resource-group <resource-group> \
  --location <region> --enable-rbac-authorization true
az keyvault create --name <prod-vault-name> --resource-group <resource-group> \
  --location <region> --enable-rbac-authorization true
```

Whoever adds secrets to the vaults needs **Key Vault Secrets Officer** on them.
That is a person or a pipeline, not DataLoader.

Grant DataLoader's identity **Key Vault Secrets User**. Pick one scope:

| Scope | What DataLoader can do | Trade-off |
|---|---|---|
| Each secret it needs | Read those secrets, nothing else | Least privilege. The vault's Test in DataLoader cannot list the vault, and the secret picker cannot show its secrets, so users type `kv://` references by hand. |
| The whole vault | Read and list every secret in it | The vault Test and the secret picker work. DataLoader can read secrets it does not use. |

```bash
# On one secret (repeat for each secret DataLoader needs):
az role assignment create --role "Key Vault Secrets User" \
  --assignee-object-id <identity-object-id> --assignee-principal-type ServicePrincipal \
  --scope "$(az keyvault show --name <test-vault-name> --query id -o tsv)/secrets/<secret-name>"

# Or on the whole vault:
az role assignment create --role "Key Vault Secrets User" \
  --assignee-object-id <identity-object-id> --assignee-principal-type ServicePrincipal \
  --scope "$(az keyvault show --name <test-vault-name> --query id -o tsv)"
```

Do the same on the prod vault. Promotion from TEST to PROD can copy a missing
secret into the prod vault. It needs **Key Vault Secrets Officer** on the prod
vault to do that. Without it, promotion stops and says DataLoader is not
allowed to write secrets there, and an admin adds the secret by hand. Grant
Officer only if the client wants promotion to copy secrets.

**Check**:

```bash
az role assignment list --assignee <identity-object-id> --all \
  --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

The list shows Key Vault Secrets User on each vault or secret you chose.
Role assignments can take a few minutes to apply.

## 4. Register the vaults in DataLoader

**Who**: DataLoader admin.

**Admin, Key vaults, + Register a vault** (**+ New vault** once one exists),
once per vault:

| Field | TEST vault | PROD vault |
|---|---|---|
| Name | `<test-vault-name>` (the handle in `kv://` references) | `<prod-vault-name>` |
| Vault URI | `https://<test-vault-name>.vault.azure.net` | `https://<prod-vault-name>.vault.azure.net` |
| Environment | TEST environment only | PROD environment only |
| Sign in with | Managed identity | Managed identity |

For one shared vault, register it once with Environment **Both TEST and PROD**. It needs no PROD counterpart.

Leave **User-assigned identity client ID** blank for the system-assigned
identity. Click **Register vault**.

For separate vaults, set the prod counterpart: in the TEST vault's row, set **PROD reads** to
`<prod-vault-name>`. PROD runs now read `kv://<test-vault-name>/<secret-name>`
from the prod vault. Secret names must match in both vaults.

**Check**: click **Test** on each row.

- A role on the whole vault: "Connected. DataLoader can read `<secret-name>`."
  (or "Connected. The vault has no secrets yet.").
- A role on single secrets: the Test says the identity cannot list secrets in
  this vault. That is expected. Prove the read instead with a connection that
  uses the reference: put `kv://<test-vault-name>/<secret-name>` in its
  password field and click **Test connection**.
- "Key Vault did not accept the token": the vault is in another tenant.

## 5. Allow the network paths

**Who**: Azure admin (network security groups, firewalls).

The VM needs outbound HTTPS (443) to `login.microsoftonline.com`, each vault
(`<vault-name>.vault.azure.net`), the Databricks workspace (`<workspace-host>`)
and the image registry.

If a source is Azure SQL and the VM is inside Azure, Azure SQL redirects each
login to a worker node on a port from 11000 to 11999. Allow outbound TCP 1433
and 11000 to 11999 to the database, or set the server's connection policy to
Proxy. See Azure SQL redirect.

**Check**: run the installer's preflight with `--key-vault` for each vault and
`--check-endpoint` for each other host
(`sudo bash /opt/dataloader/install.sh --dry-run --key-vault <vault-name> --check-endpoint <host>`,
with `HOST:PORT` for a port other than 443); each prints `PASS`. For Azure SQL, the source's **Test connection** says whether the
redirect target was reachable.

## 6. Register the SSO app in Entra

**Who**: Entra admin.

```bash
az ad app create --display-name "DataLoader" --sign-in-audience AzureADMyOrg \
  --web-redirect-uris https://<dataloader-host>/api/v1/auth/oidc/callback
az ad sp create --id <app-client-id>
```

`az ad app create` prints `appId`: that is `<app-client-id>`. `az ad sp create`
makes the app's service principal in the tenant, which step 9 needs.

In the portal the same is **Microsoft Entra ID, App registrations, New
registration**: single tenant, redirect URI of type Web. The redirect path
`/api/v1/auth/oidc/callback` is fixed and must match exactly, trailing slash
included.

Under **API permissions**, confirm the delegated Microsoft Graph permissions
`openid`, `profile` and `email` are present. Add `email` if it is missing.

**The client ID is the app's GUID.** Copy **Application (client) ID** from the
app's Overview page. Browsers save an email address into fields that look like
a user name. An email address in the client ID field breaks every new sign-in
with `AADSTS700016`. DataLoader refuses a client ID that is not a GUID, but
check the value you paste.

**Check**:

```bash
az ad app show --id <app-client-id> --query "{appId:appId, redirectUris:web.redirectUris}"
az ad sp show --id <app-client-id> --query id -o tsv
```

The first shows the GUID and the exact redirect URI. The second prints the
app's service principal object ID: write it down as `<app-sp-object-id>`.

## 7. Let DataLoader sign in as the app without a secret

**Who**: Entra admin, with values from the DataLoader admin.

DataLoader signs in to Entra as the app with its managed identity, through a
federated identity credential on the app. No client secret is created.

The DataLoader admin opens **Admin, Sign-in**, enters the **Issuer URL**
(`https://login.microsoftonline.com/<tenant-id>/v2.0`) and picks **Managed
identity (federated credential)** under **Sign in to Entra with**. The page
shows three values, each with a **Copy** button: **Issuer**, **Subject
identifier** (the identity's object ID) and **Audience**
(`api://AzureADTokenExchange`).

```bash
az ad app federated-credential create --id <app-client-id> --parameters '{
  "name": "dataloader-managed-identity",
  "issuer": "https://login.microsoftonline.com/<tenant-id>/v2.0",
  "subject": "<identity-object-id>",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

In the portal: the app, **Certificates & secrets, Federated credentials, Add
credential**, scenario **Other issuer**, and paste the three values.

**Check**:

```bash
az ad app federated-credential list --id <app-client-id> \
  --query "[].{issuer:issuer, subject:subject, audiences:audiences}"
```

The issuer, subject and audience match what **Admin, Sign-in** shows. Under
**Certificates & secrets, Client secrets**, the app has none.

## 8. Decide who may sign in

**Who**: Entra admin.

By default any user in the tenant can sign in, and DataLoader's **Allowed email
domains** field narrows that by domain. To limit sign-in to named people or a
group, set **Assignment required?** to Yes on the app's Enterprise application
and assign the users or groups.

**Check**: the Enterprise application's **Users and groups** lists the people
who should sign in, or assignment is off and the client is fine with any user
in the allowed domains.

## 9. Grant Microsoft Graph `User.Read.All` and admin consent

**Who**: Entra admin adds the permission. An Entra consent admin (Global
Administrator or Privileged Role Administrator) grants consent.

Every 15 minutes DataLoader asks Entra whether each Microsoft-signed-in user
still exists and is enabled, so a user disabled in Entra loses access within
minutes. That check needs the Microsoft Graph `User.Read.All` permission as an
**application** permission, not a delegated one. Without it nobody is signed
out, the check shows as failing, and every user has to sign in again once a
day.

The two GUIDs below are Microsoft's: Microsoft Graph's application ID and the
`User.Read.All` application role. They are the same in every tenant.

```bash
az ad app permission add --id <app-client-id> \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions df021288-bdef-4463-88db-98f22de89214=Role
az ad app permission admin-consent --id <app-client-id>
```

`admin-consent` can report success without granting an application role.
Always run the check.

**Check**:

```bash
az rest --method GET \
  --url https://graph.microsoft.com/v1.0/servicePrincipals/<app-sp-object-id>/appRoleAssignments \
  --query "value[].appRoleId"
```

The output lists `df021288-bdef-4463-88db-98f22de89214`. If it does not, grant
the role directly (consent admin):

```bash
az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv   # <graph-sp-object-id>
az rest --method POST \
  --url https://graph.microsoft.com/v1.0/servicePrincipals/<app-sp-object-id>/appRoleAssignments \
  --headers Content-Type=application/json \
  --body '{"principalId":"<app-sp-object-id>","resourceId":"<graph-sp-object-id>","appRoleId":"df021288-bdef-4463-88db-98f22de89214"}'
```

Run the check again. In the portal, the app's **API permissions** shows
`User.Read.All`, type Application, status "Granted for `<tenant>`".

`User.Read.All` also lets an admin add people from Entra before they sign in
(Admin, Users, **Add from Entra**). If the client will use **Roles from Entra
groups** (Admin, Sign-in), or Entra group sync, add `GroupMember.Read.All` as an
application permission the same way (portal: **API permissions, Add a
permission, Microsoft Graph, Application permissions**) and consent to it. Roles
from Entra groups searches for groups too, so add `Group.Read.All` the same way.
Without `GroupMember.Read.All`, no role changes: the session check shows as
failing and names the permission.

## 10. Configure sign-in in DataLoader

**Who**: DataLoader admin.

**Admin, Sign-in**:

| Field | Value |
|---|---|
| Issuer URL | `https://login.microsoftonline.com/<tenant-id>/v2.0` |
| Redirect URL | `https://<dataloader-host>/api/v1/auth/oidc/callback` |
| Client ID | `<app-client-id>`, pasted from the app's Overview page |
| Sign in to Entra with | Managed identity (federated credential) |
| User-assigned identity client ID | Blank for the system-assigned identity |
| Allowed email domains | The client's domains, comma separated, or blank for any |

Click **Save changes**, then **Test connection**.

**Check**:

1. **Test connection** passes. If Entra finds no matching federated credential,
   the result names the issuer, subject and audience to compare with step 7.
2. In a private browser window, open `https://<dataloader-host>`, click
   **Sign in with Microsoft** and sign in as a real user. The user lands in
   DataLoader as a viewer.
3. As the bootstrap admin, open **Admin, Users** and make that user an admin.
4. Within 15 minutes, the section **Check sessions against Entra** on
   **Admin, Sign-in** is tagged **OK** and reads "Last check ...: N checked".
   **FAILING** with a permission error means step 9 is not done.

Turn on the **Enforce SSO** toggle only after an admin has
signed in with Microsoft. Then disable the bootstrap admin in **Admin, Users**
and delete the two `DL_BOOTSTRAP_ADMIN_*` lines from `.env`. See
Auth for enforcement and break-glass.

## 11. Give the identity access to Databricks

**Who**: Databricks admin.

Skip this step if DataLoader does not load into Databricks.

1. **Add the identity as a service principal.** In the workspace: **Settings,
   Identity and access, Service principals, Add service principal, Add new**.
   Pick **Microsoft Entra ID managed** and enter `<identity-app-id>`, the
   application ID from step 1, not the object ID.
2. **Grant the SQL warehouse.** **SQL Warehouses, `<warehouse-name>`,
   Permissions**: give the service principal **Can use**. Copy the warehouse
   ID from **Connection details**.
3. **Create the target schemas and the staging volume**, and grant them. Run as
   the catalog owner in the SQL editor:

   ```sql
   -- DataLoader creates a missing target schema only when it has CREATE
   -- SCHEMA on the catalog. Without that grant, create each one first.
   CREATE SCHEMA IF NOT EXISTS <catalog>.<target-schema>;
   CREATE SCHEMA IF NOT EXISTS <catalog>.dataloader;
   CREATE VOLUME IF NOT EXISTS <catalog>.dataloader.staging;

   GRANT USE CATALOG ON CATALOG <catalog> TO `<identity-app-id>`;
   -- Repeat for every schema DataLoader loads into.
   GRANT USE SCHEMA, CREATE TABLE, SELECT, MODIFY ON SCHEMA <catalog>.<target-schema> TO `<identity-app-id>`;
   GRANT USE SCHEMA ON SCHEMA <catalog>.dataloader TO `<identity-app-id>`;
   GRANT READ VOLUME, WRITE VOLUME ON VOLUME <catalog>.dataloader.staging TO `<identity-app-id>`;
   ```

   Grant `CREATE SCHEMA` on the catalog as well if tables should load into
   schemas that do not exist yet, or dbt projects run through DataLoader
   build into them. A first run then creates the schema. Without the grant,
   a run into a missing schema fails and names the schema and this grant.

No personal access token and no OAuth secret is created.

**Check**, in the SQL editor:

```sql
SHOW GRANTS `<identity-app-id>` ON CATALOG <catalog>;
SHOW GRANTS `<identity-app-id>` ON SCHEMA <catalog>.<target-schema>;
SHOW GRANTS `<identity-app-id>` ON VOLUME <catalog>.dataloader.staging;
```

Then in DataLoader (DataLoader admin): **Connections, + New destination,
Databricks**:

| Field | Value |
|---|---|
| Workspace URL | `https://<workspace-host>` |
| Sign in with | Managed identity |
| SQL warehouse ID | `<warehouse-id>` |
| Catalog | `<catalog>` |
| Volume path | `/Volumes/<catalog>/dataloader/staging/dataloader` |

**Test Destination** says "Connected to Databricks at ...; staging volume ...
is writable". Otherwise it names the first thing missing: the service
principal or its **Can use** on the warehouse, `USE CATALOG`, or the volume
grants. More in Databricks destination.

## 12. Updates

**Who**: DataLoader admin, and the host admin when a re-run is needed.

**Admin, Updates** checks for new releases, and **Apply update** installs one
through the host update unit. In this release, Apply changes the image tag
but does not refresh the compose file. When a release's notes say the compose
file changed, update by re-running the installer from the new image instead:

```bash
TAG=<new-release-tag>
docker run --rm --entrypoint cat acrdakotadataloader.azurecr.io/dataloader:$TAG \
  /opt/dataloader/deploy/install.sh > install.sh
sudo bash install.sh --tag $TAG
```

The re-run keeps `--managed-identity` and the rest of `.env`. A later release
makes Apply refresh the compose file, and its notes will say so.

**Check**: **Admin, Updates** shows the new version as current, and
`sudo grep ^DL_AZURE_MANAGED_IDENTITY= /opt/dataloader/.env` still prints
`imds`. See Updates.

---

## Final check

DataLoader is ready for the SI when all of these pass:

| Check | Step |
|---|---|
| The vault register form shows the identity's object ID | 2 |
| Each vault's Test passes, or a connection reads a `kv://` secret | 4 |
| The TEST vault's **PROD reads** names the prod vault | 4 |
| **Sign in with Microsoft** works for a real user | 10 |
| **Check sessions against Entra** is tagged OK | 10 |
| The Databricks destination's **Test Destination** says the staging volume is writable | 11 |
| No client secret on the app registration, no Databricks token or OAuth secret | 7, 11 |

## Worksheet

Hand this to the SI. None of these are secrets.

| Value | From step | Value |
|---|---|---|
| `<tenant-id>` | before you start | |
| `<identity-object-id>` | 1 | |
| `<identity-app-id>` | 1 | |
| `<dataloader-host>` | 2 | |
| `<test-vault-name>`, `<prod-vault-name>` | 3 | |
| `<app-client-id>` | 6 | |
| `<app-sp-object-id>` | 6 | |
| `<workspace-host>`, `<warehouse-id>`, `<catalog>` | 11 | |
