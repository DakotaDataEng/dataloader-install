# Install DataLoader on a Linux host

Start with the public SI install repository at [DakotaDataEng/dataloader-install](https://github.com/DakotaDataEng/dataloader-install).

This runbook installs DataLoader from the published image on one Linux
host. The Docker installer is `scripts/install.sh` in the repo and
`/opt/dataloader/deploy/install.sh` in the image, so the
host needs no GitHub access and no registry credentials (the registry
allows anonymous pull, see ADR 0020).

For the systemd binary install (no Docker), use `deploy/install.sh` in the repo.

## Before you start

- Ubuntu 22.04+ or Debian 12+, x86_64, with Docker Engine 24+ and the
  `docker compose` v2 plugin (2.24+). The installer does not install Docker.
- `sudo`, or a user in the `docker` group who can write to the install
  directory (default `/opt/dataloader`). One-click updates need `sudo` and
  systemd; without them the install works and updates are by hand.
- Your own user in the `docker` group (`sudo usermod -aG docker $USER`),
  then sign in again. The install itself runs under `sudo`, but the checks
  you run afterwards, such as `docker version`, run as you and fail without it.
- Outbound HTTPS to `acrdakotadataloader.azurecr.io`, plus
  `login.microsoftonline.com` and each Key Vault if you will use Microsoft
  sign-in or Azure.
- The release tag to install, for example `1.0.0`, and the email for the
  first admin account.

## Install

```bash
TAG=1.0.0
docker run --rm --entrypoint cat acrdakotadataloader.azurecr.io/dataloader:$TAG \
  /opt/dataloader/deploy/install.sh > install.sh
sudo bash install.sh --tag $TAG --bootstrap-admin-email admin@client.example
```

The first command pulls the image and copies the installer out of it.
The installer then:

1. Runs the preflight checks below and stops, changing nothing, if any
   check fails.
2. Prints a plan and asks to proceed (`--yes` skips the prompt).
3. Copies `docker-compose.deploy.yml` out of the same image into the
   install directory, creates `license/` and `backups/`, and writes `.env`
   (mode 0600).
4. Sets up one-click updates (as root on a systemd host): creates
   `update/` owned by uid 10001 with mode 0750, copies the host update unit
   out of the image, and enables it. See [One-click updates](#one-click-updates).
5. On Ubuntu 23.10 and later, writes and loads the AppArmor profile the
   plugin sandbox needs. See [Ubuntu 23.10+ hosts](#ubuntu-2310-hosts-apparmor).
6. Runs `docker compose up -d` and waits for `GET /api/v1/health` to
   report `healthy`. First boot unpacks the embedded Postgres from the
   binary and runs the migrations, which usually takes under a minute
   (the default timeout is 600 seconds). Nothing is downloaded.
7. Prints the URL, the running version, the state volume name, a
   backup command and whether one-click updates are on.

Run `bash install.sh --help` for every flag. The common ones:

| Flag | Default | Use |
|---|---|---|
| `--tag` | none (required on a new install) | Image tag to install |
| `--install-dir` | `/opt/dataloader` | Holds the compose file, `.env`, `license/`, `backups/` |
| `--port` | `8080` | Host port |
| `--bind` | `127.0.0.1` | Host address. Keep loopback and put a TLS reverse proxy in front |
| `--bootstrap-admin-email` | none | First admin account |
| `--key-vault NAME\|HOST` | none | Tests DNS and HTTPS to a Key Vault. A bare name means `NAME.vault.azure.net`. Repeatable |
| `--check-endpoint HOST[:PORT]` | none | Extra reachability check for a source or a destination. Port 443 (the default) is tested over HTTPS, any other port with a TCP connect. Repeatable |
| `--managed-identity` | off; once set, a re-run keeps it | On an Azure VM with a managed identity: DataLoader signs in to Key Vault, storage and Databricks with it. Writes `DL_AZURE_MANAGED_IDENTITY=imds` to `.env`. See the [Azure client runbook](client-azure-identity-vault-sso-databricks.md) |
| `--auto-update on\|off` | `off`, or the last choice on a re-run | Daily automatic update to the newest release tag |
| `--remove-update-units` | | Take out the host update unit and the automatic update, then exit |
| `--repair` | | Same as a re-run: restores the update folder, the unit, the automatic update choice and, on Ubuntu 23.10+, the AppArmor profile |
| `--refresh-host-handler` | | Replace only the host update scripts and units and `install.sh` with the running image's copies, then exit; for a host set up before 0.1.62 (Updates) |
| `--dry-run` | off | Preflight and plan only |
| `--yes` | off | No prompts |

## Preflight checks

Each check prints `PASS`, `WARN` or `FAIL` with a one-line fix. Any `FAIL`
stops the run with exit code 1 before anything changes: no directory, no
`.env` edit, no backup, no pull. `--dry-run` runs the same checks and prints
the plan without a prompt.

Name the client's Key Vault, sources and destinations so the preflight tests
them from this host before the install:

```bash
sudo bash install.sh --dry-run --tag $TAG --key-vault contoso-kv \
  --check-endpoint sql01.corp.example:1433 --check-endpoint adb-123.azuredatabricks.net
```

| Check | FAIL when | WARN when |
|---|---|---|
| Operating system | | not Ubuntu or Debian, or not x86_64 |
| Docker daemon | not installed or not reachable | |
| Docker Engine | older than 24.0 | |
| Compose plugin | missing or older than 2.24 | |
| curl | missing | |
| Install dir | not writable | |
| Port | in use by something other than this install | |
| Disk (Docker data root and install dir) | under 5 GB free | under 20 GB free |
| Registry DNS and HTTPS | unreachable and the image is not already on the host | unreachable but the image is present |
| Entra ID (`login.microsoftonline.com`) | | unreachable |
| Postgres download (`api.github.com`, `github.com`, `release-assets.githubusercontent.com`) | | unreachable, and the image lacks the `dataloader.embedded-postgres` label (built before #1476) or is not on the host yet. Skipped when `DL_DATABASE_URL` is set in `.env` or an existing state volume already holds Postgres |
| Each `--key-vault` | | does not resolve or HTTPS does not connect |
| Each `--check-endpoint` | | does not resolve or does not connect |
| DNS tool | | none of `getent`, `host` or `nslookup` is installed, so names cannot be tested |
| One-click updates | | not root, no systemd, or an install dir a unit path can't hold. Apply on the Updates page stays off |
| AppArmor userns | the host restricts user namespaces and the run is not root, or `apparmor_parser` is missing | `.env` sets `DATALOADER_APPARMOR_PROFILE` by hand to another value on a restricted host |
| Existing install | | found, and this run will upgrade it |

## The .env file

A new `.env` holds `COMPOSE_PROJECT_NAME=dataloader`, `DATALOADER_TAG`,
`DATALOADER_BIND_ADDR`, `DATALOADER_PORT`, `DATALOADER_AUTO_UPDATE` and the
two `DL_BOOTSTRAP_ADMIN_*` keys, plus `DATALOADER_IMAGE_REPO` when `--image`
names a mirror of the image (the repository without a tag; a re-run keeps
it, see From a mirrored registry),
and `DATALOADER_APPARMOR_PROFILE` on Ubuntu 23.10+ hosts (see
[Ubuntu 23.10+ hosts](#ubuntu-2310-hosts-apparmor)). In a terminal you are asked for the admin
password (leave it blank to generate one). With `--yes` it is generated.
The installer never prints it. To read it:

```bash
sudo sed -n "s/^DL_BOOTSTRAP_ADMIN_PASSWORD='\(.*\)'$/\1/p" /opt/dataloader/.env
```

This prints the bare password. In `.env` the value sits inside single quotes
so Compose does not expand a `$`; the quotes are not part of the password, so
leave them out when you sign in.

Sign in, finish the setup wizard, then delete both `DL_BOOTSTRAP_ADMIN_*`
lines. The seed only runs when the database has no users, and a re-run of
the installer does not add them back.

An existing `.env` is never replaced. The installer only adds missing
`DATALOADER_TAG`, `DATALOADER_BIND_ADDR`, `DATALOADER_PORT` and
`DATALOADER_AUTO_UPDATE` lines (and `DATALOADER_APPARMOR_PROFILE` on a
restricted host),
changes the ones you pass by flag, and copies the old file to
`.env-backups/` (root only, mode 0700, newest 10 kept) before any edit. It
does not use `backups/`: that folder is mounted into the container, which
could plant a link there. It never adds `COMPOSE_PROJECT_NAME` to an existing file,
because that would rename the state volume.

## State and backups

State (`jwt.key`, `master.key`, the embedded Postgres) lives in the named
Docker volume `dataloader_dataloader-data`, not in the install directory.
Losing `master.key` means re-entering the SSO and Azure secrets. Back the
volume up before every upgrade:

```bash
cd /opt/dataloader
docker run --rm -v dataloader_dataloader-data:/data:ro -v "$PWD/backups:/backup" \
  alpine tar czf /backup/dataloader-data-$(date +%F).tgz -C /data .
```

Section 14 of the [client acceptance test plan](client-acceptance-test-plan.md)
covers the upgrade backup and rollback steps.

## Re-run, verify and upgrade

```bash
sudo bash /opt/dataloader/install.sh              # same tag: verify and report
sudo bash /opt/dataloader/install.sh --tag 1.0.1  # new tag: upgrade
```

The installer keeps a copy of itself in the install directory. For an
upgrade, fetch the new tag's installer the same way as a first install,
since it knows about the new compose file. The upgrade pulls the new image
first, then updates `DATALOADER_TAG`, replaces the compose file (the old
one goes to `.compose-backups/`, root only, newest 10 kept) and runs `docker compose up -d`. Migrations run on
boot. There is no downgrade migration, so a rollback means restoring the
volume backup and starting the old tag.

## One-click updates

Run as root on a systemd host, the installer sets up what **Apply update**
on Settings, Updates needs (#1626, #1627):

| What | Where | Owner and mode |
|---|---|---|
| Update folder, shared with the container at `/var/lib/dataloader-update` | `<install dir>/update/` | uid 10001, 0750 |
| Marker the Updates page reads to offer Apply | `<install dir>/update/host-unit` | root, 0644 |
| Host update script and the automatic update script | `/usr/local/lib/dataloader/` | root, 0755 |
| `dataloader-update-request.path` and `.service`, `dataloader-auto-update.service` and `.timer` | `/etc/systemd/system/` | root, 0644 |

The update folder is the only host path the container can write. It gets
no Docker socket and no write access to `.env`. When an admin clicks Apply,
the app writes `update/request.json`; the path unit starts the service,
which checks the request, pulls the tag, copies the new image's compose
file and seccomp profile in (the old ones go to `.compose-backups/`), sets
`DATALOADER_TAG`, restarts the stack and writes `update/result.json` for the
page. A failed start puts the old files and tag back. After a healthy start
it also refreshes `install.sh` in the install directory and the host update
scripts and units, so a host that only ever uses Apply stays on the current
version's files.
Updates lists every check it makes.

Daily automatic updates are off unless you pass `--auto-update on` (or say
yes at the prompt on a new install). With them on, the timer runs at 03:17
(plus up to 20 minutes) and asks the host update unit for the newest release
tag above `DATALOADER_TAG` in the registry the install pulls from. It never
asks for an older tag. The choice is `DATALOADER_AUTO_UPDATE` in `.env`, and
a re-run keeps it.

```bash
systemctl status dataloader-update-request.path     # the unit that applies requests
journalctl -u dataloader-update-request.service     # what it did
journalctl -t dataloader-auto-update                # what the daily check did
sudo bash /opt/dataloader/install.sh --auto-update on
sudo bash /opt/dataloader/install.sh --remove-update-units
```

A re-run (or `--repair`) restores the folder's owner, the units and the
marker, and leaves one copy of each.

## Ubuntu 23.10+ hosts (AppArmor)

Ubuntu 23.10 and later set `kernel.apparmor_restrict_unprivileged_userns = 1`.
The kernel then denies a user namespace to any process that is not under an
AppArmor profile granting `userns`, so bwrap in the container fails with
`setting up uid map: Permission denied` and no plugin starts (#1690).

When AppArmor is on (`/sys/module/apparmor/parameters/enabled` reads `Y`)
and that sysctl reads `1`, the installer:

1. writes `/etc/apparmor.d/dataloader-container` (root, 0644) under a temp
   name in the same directory and renames it into place;
2. loads it with `apparmor_parser -r`;
3. sets `DATALOADER_APPARMOR_PROFILE=dataloader-container` in `.env`, which
   the compose file passes as `apparmor=dataloader-container`.

The profile is `flags=(unconfined)` plus one rule, `userns`, so the
container is no more confined than with `apparmor=unconfined`. Local rules
go in `/etc/apparmor.d/local/dataloader-container`; the installer rewrites
the main file on every run. AppArmor loads the file again at boot.

On any other host the variable stays out of `.env`, nothing is written, and
the container runs with `apparmor=unconfined`. A value you set in `.env` by
hand is kept and shown in the preflight. The preflight fails, changing
nothing, when the profile is needed but the run is not root or
`apparmor_parser` is missing (`sudo apt-get install -y apparmor`). If
`apparmor_parser` rejects the profile the run stops before `.env` changes.

Apply on the Updates page and the daily automatic update run compose with
the same `.env`, so the value carries through updates and rollbacks.

```bash
sudo aa-status | grep dataloader-container          # the profile is loaded
sysctl kernel.apparmor_restrict_unprivileged_userns # 1 on Ubuntu 23.10+
cd /opt/dataloader && docker compose -f docker-compose.deploy.yml exec dataloader plugin-selftest
```

## After the install

1. Sign in as the bootstrap admin.
2. Finish the setup wizard (workspace, license, optional SSO), or
   [set up from a file](#set-up-from-a-file).
3. Set up [private network access](#on-a-private-network) if other machines need access.
4. Run the [client acceptance test plan](client-acceptance-test-plan.md).

### On a private network

The installer binds to `127.0.0.1` by default. Put a TLS proxy on the host and use the client's certificate. See HTTPS termination. Alternatively, install with `--bind 0.0.0.0` and restrict the host port to the corporate network range with a network rule. Give the host no public IP.

## Set up from a file

`dl setup` brings a new instance to the state a YAML file describes, through the same routes the wizard and the Admin pages use. Keep the file with the client's other deployment notes: it holds no secrets, only the names of where they are. Use it instead of clicking through the wizard, or to make a second instance match the first.

The file has these sections, all optional except `version: 1`: `workspace`, `license`, `compute`, `vaults`, `sso`, `connections`, `destinations`, `tables` and `complete`. A working example for the dev stack is `deploy/dl-setup.dev.yml`. A secret is written as `env:NAME` (read from the environment of the computer running `dl`) or `kv://vault/secret` (a Key Vault secret the instance reads itself). A literal value under a password, token, secret or connection string key is refused before anything is sent. An SSO secret and the license key take `env:NAME` only. The license can also be `file: path`, relative to the setup file.

`compute` uses the fields on Admin, Compute backend: subscription, resource group, managed identity, image tag, registry URL, location and infrastructure subnet. Give only the fields to set; the others stay as they are. A vault entry can pair its TEST vault with a PROD vault in `prod_counterpart`. The top-level vault is TEST, the nested vault is PROD, and `dl setup` links the pair through the vault API. Its nested `name` must not name another vault entry in the file.

Set `sso.enforce: true` to turn on SSO enforcement. After all other setup sections are applied, `dl setup` runs SSO Test against the saved configuration. It enables enforcement only when that test passes; otherwise it stops and reports the test failure in plain words. `false` disables enforcement and is always allowed for recovery.

Tables also accept `incremental_column`, `incremental_type`, `merge_keys`, `read_options`, `read_batch_rows`, and the TEST-only row limit pair `test_row_limit_mode` (`default`, `none` or `number`) and `test_row_limit` (a positive number when the mode is `number`). `read_options` are plugin fields and are checked by the same secret-reference rule as connection settings. The merge key list maps to the table's primary key columns.

With `--force`, connection and destination config objects merge recursively: keys present in the file replace their stored values, while omitted keys stay. No stored setting is silently discarded.

### Where `dl` is

The image carries `dl` at `/app/bin/dl` and links it onto the container's PATH, so it runs at the version the image runs. There are two ways to use it.

**Inside the container.** Nothing to install. Run it from the install directory (the one with `docker-compose.deploy.yml`). The container reaches its own server at `http://127.0.0.1:8080`, and the bootstrap admin's password is already in its environment as `DL_BOOTSTRAP_ADMIN_PASSWORD`, so name that variable with `--password-env`. The setup file has to be inside the container too, so copy it in first:

```bash
docker compose -f docker-compose.deploy.yml cp setup.yml dataloader:/tmp/setup.yml
docker compose -f docker-compose.deploy.yml exec -T dataloader dl --version
docker compose -f docker-compose.deploy.yml exec -T dataloader dl setup plan /tmp/setup.yml --url http://127.0.0.1:8080 --email admin@client.example --password-env DL_BOOTSTRAP_ADMIN_PASSWORD
docker compose -f docker-compose.deploy.yml exec -T dataloader dl setup apply /tmp/setup.yml --url http://127.0.0.1:8080 --email admin@client.example --password-env DL_BOOTSTRAP_ADMIN_PASSWORD
```

An `env:NAME` secret in the file is read from the container's environment, not the host's, and a `license: file:` path is relative to `/tmp`. Use the host copy below when the file refers to either.

**On the host.** Take the binary out of the image, so it matches the running version:

```bash
TAG=1.0.0
docker run --rm --entrypoint cat acrdakotadataloader.azurecr.io/dataloader:$TAG /app/bin/dl > dl
chmod +x dl
./dl --version
```

### Point `dl` at the instance and sign in

`dl` finds the instance from `--url` (or `DL_URL`), the address people open in a browser, for example `https://dataloader.client.example`. It reads its sign-in from the environment, never from a flag. Use the first that fits:

- **First run on a new instance:** `--email` with the bootstrap admin's email, and its password in the variable `--password-env` names (`DL_SETUP_PASSWORD` by default). The password is the `DL_BOOTSTRAP_ADMIN_PASSWORD` line of `.env` in the install directory.
- **Later runs:** `DL_TOKEN`, an API token an admin made on their Profile page in the app, or `DL_CLIENT_ID` and `DL_CLIENT_SECRET`, an OAuth client from Admin settings. The token or client needs the admin scope. A `dl login` sign-in does not have it.

```bash
export DL_SETUP_PASSWORD='<the bootstrap admin password>'   # the DL_BOOTSTRAP_ADMIN_PASSWORD line of .env
dl setup plan  setup.yml --url https://dataloader.client.example --email admin@client.example
dl setup apply setup.yml --url https://dataloader.client.example --email admin@client.example
```

```yaml
compute:
  subscription_id: 11111111-1111-1111-1111-111111111111
  resource_group: rg-dataloader-prod
  container_registry_url: https://acrdakotadataloader.azurecr.io

vaults:
  - name: source-test
    uri: https://source-test.vault.azure.net
    env_tag: test
    prod_counterpart:
      name: source-prod
      uri: https://source-prod.vault.azure.net
      auth_method: managed_identity

sso:
  issuer_url: https://login.microsoftonline.com/<tenant>/v2.0
  client_id: <application-id>
  redirect_url: https://dataloader.client.example/api/v1/auth/oidc/callback
  enforce: true

tables:
  - connection: source
    destination: lake
    source_schema: public
    source_table: orders
    dest_schema: gold
    dest_table: orders
    load_strategy: merge
    incremental_column: updated_at
    incremental_type: timestamp
    merge_keys: [order_id]
    read_options:
      fetch_size: 5000
    test_row_limit_mode: number
    test_row_limit: 1000
```

`plan` reads the instance and prints what `apply` would do, and changes nothing. `apply` creates what is missing and leaves what already matches. Where something exists and differs from the file, it prints each difference and leaves it as it is, then exits with 2 so a pipeline notices. Add `--force` to make the file win. A second `apply` of the same file changes nothing and prints `no changes`. A secret that was stored cannot be read back, so it never counts as a difference: rotate one in Admin, not here.

The first run on a new instance signs in as the bootstrap admin: `--email` plus the password in the environment variable `--password-env` names (`DL_SETUP_PASSWORD` by default). The password is never taken from a flag. Once Microsoft sign-in is on and the bootstrap admin is gone, use an OAuth client with the admin scope (`DL_CLIENT_ID` and `DL_CLIENT_SECRET`) or an admin's API token (`DL_TOKEN`). A `dl login` sign-in has no admin scope, and `dl setup` says so.

`complete: true` finishes setup only while it is still open, and only when no step the file asks for is missing. It refuses, and names the step, when the Microsoft session check fails for want of the `User.Read.All` permission, or when a vault uses the managed identity and the host has none. The `--json` flag prints the report as JSON.

## Troubleshooting

- **Health wait times out.** The installer exits 1 and names the URL it
  polled and the last answer (`no answer`, or a status such as `degraded`),
  then prints the last 40 log lines. `.env` and the compose file are in
  place and the container is left running. Read the rest with
  `cd /opt/dataloader && docker compose -f docker-compose.deploy.yml logs dataloader`,
  fix the cause, and re-run the installer: it keeps `.env`. A slow first
  boot can take a longer `--health-timeout`.
- **`the image ... has no /opt/dataloader/deploy/docker-compose.deploy.yml`.**
  The tag predates the installer (#1432). Pass a compose file from a
  checkout of that tag with `--compose-file`.
- **`the image ... has no /opt/dataloader/deploy/seccomp-bwrap.json`.**
  The tag predates the unified image (#1417). Install a newer tag; the
  compose file needs that profile for the plugin sandbox (ADR 0027).
- **Plugins fail with a bwrap namespace error.** Run
  `cd /opt/dataloader && docker compose -f docker-compose.deploy.yml exec dataloader plugin-selftest`.
  It names the likely cause (seccomp profile, AppArmor, or
  `kernel.apparmor_restrict_unprivileged_userns` on Ubuntu 23.10+).
  `setting up uid map: Permission denied` means the AppArmor profile is not
  loaded or not in `.env`; `Can't mount proc` means the compose file lacks
  `systempaths=unconfined` (images before #1690). `sudo bash install.sh --repair`
  restores both; see [Ubuntu 23.10+ hosts](#ubuntu-2310-hosts-apparmor).
- **`not running in a terminal`.** Add `--yes`, and pass `--tag` and
  `--bootstrap-admin-email` as flags.
