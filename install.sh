#!/usr/bin/env bash
# DataLoader v2: one-command installer for a Linux host with Docker (#1432).
#
# Checks the host, writes `.env`, starts DataLoader from the published
# image with `docker-compose.deploy.yml`, waits for /api/v1/health and
# prints the URL.
#
# The script and the compose file ship inside the image at
# /opt/dataloader/deploy/, so a host needs neither GitHub access nor
# registry credentials (the registry allows anonymous pull, ADR 0020):
#
#   docker run --rm --entrypoint cat \
#     acrdakotadataloader.azurecr.io/dataloader:<tag> \
#     /opt/dataloader/deploy/install.sh > install.sh
#   sudo bash install.sh --tag <tag>
#
# The installer then copies the compose file out of the same image, so
# the files on the host always match the tag being installed.
#
# Re-running is safe. With the same tag it verifies and reports. With a
# new --tag it upgrades (pull, then up -d). An existing `.env` is never
# replaced: missing keys are added and the changes are listed.
#
# One-click updates (#1626, #1627): run as root on a systemd host, the
# installer creates <install dir>/update/ for uid 10001 (the only host path
# the container can write), installs the host update unit that applies
# requests from the Updates page, and turns the daily automatic update on
# or off (--auto-update, default off, kept across re-runs). A re-run
# restores all of it; --remove-update-units takes the units out.
#
# A managed identity (#1712): on an Azure VM, --managed-identity writes
# DL_AZURE_MANAGED_IDENTITY=imds to `.env`, so DataLoader signs in to Key
# Vault and storage with the VM's identity. The installer never probes IMDS
# to guess; the operator says so.
#
# A mirrored registry (#1662): --image REPO installs from a copy of the
# image in the client's own registry. The repository goes into `.env` as
# DATALOADER_IMAGE_REPO and a re-run keeps it, so Apply and the daily
# automatic update move the tag within that repository.
#
# Ubuntu 23.10+ hosts (#1690): when AppArmor is on and the kernel sets
# apparmor_restrict_unprivileged_userns=1, the installer writes and loads
# the host profile /etc/apparmor.d/dataloader-container (it grants userns)
# and sets DATALOADER_APPARMOR_PROFILE in `.env`, so the plugin sandbox can
# start. Other hosts get neither. A re-run and --repair restore both.
#
# The systemd binary install is a separate script, `deploy/install.sh`.
#
# Run `bash install.sh --help` for the flags.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# --- Constants ---------------------------------------------------------------

DEFAULT_IMAGE_REPO="acrdakotadataloader.azurecr.io/dataloader"
IMAGE_DEPLOY_DIR="/opt/dataloader/deploy"
COMPOSE_NAME="docker-compose.deploy.yml"
COMPOSE_OVERRIDE_NAME="docker-compose.override.yml"
# Relative to the install dir; must match security_opt in the compose file.
SECCOMP_NAME="deploy/seccomp-bwrap.json"
HEALTH_PATH="/api/v1/health"

# One-click updates (#1626, #1627). The container user owns the update
# folder; root owns the scripts and units that act on it.
UPDATE_DIR_NAME="update"
CONTAINER_UID=10001
UPDATE_MARKER="host-unit"
UPDATE_SCRIPTS=(dataloader-update-request.sh dataloader-auto-update.sh)
UPDATE_UNITS=(dataloader-update-request.path dataloader-update-request.service
    dataloader-auto-update.service dataloader-auto-update.timer)
# The self-test points these at a scratch dir; nothing else sets them.
SYSTEMD_DIR=${DL_SYSTEMD_DIR:-/etc/systemd/system}
SYSTEMD_RUNTIME_DIR=${DL_SYSTEMD_RUNTIME_DIR:-/run/systemd/system}
UPDATE_LIB_DIR=${DL_UPDATE_LIB_DIR:-/usr/local/lib/dataloader}
# The release the host update scripts came from, beside them, and the
# previous copy of every host file a run replaces (root, 0700). The host
# update script uses the same names.
HANDLER_VERSION_NAME="handler-version"
HOST_BACKUPS=".host-backups"
ENTRA_HOST="login.microsoftonline.com"
# A bare --key-vault name gets this suffix (Azure public cloud).
KEY_VAULT_SUFFIX="vault.azure.net"
# The self-test points this at a faked file. The file is only read for its
# ID, ID_LIKE and PRETTY_NAME values, never sourced, so a stray value on a
# real host can't run anything.
OS_RELEASE_FILE=${DL_OS_RELEASE_FILE:-/etc/os-release}

# Ubuntu 23.10+ hosts (#1690). The kernel denies unprivileged user
# namespaces to unconfined processes when the sysctl reads 1, so bwrap in
# the container needs a loaded profile that grants userns. The self-test
# points these paths at faked files; nothing else sets them.
APPARMOR_ENABLED_FILE=${DL_APPARMOR_ENABLED_FILE:-/sys/module/apparmor/parameters/enabled}
USERNS_RESTRICT_FILE=${DL_USERNS_RESTRICT_FILE:-/proc/sys/kernel/apparmor_restrict_unprivileged_userns}
APPARMOR_DIR=${DL_APPARMOR_DIR:-/etc/apparmor.d}
APPARMOR_PROFILE="dataloader-container"
APPARMOR_KEY="DATALOADER_APPARMOR_PROFILE"

# Images that carry the embedded Postgres in the binary set this label to
# its version (#1476). Images without it download Postgres on the first
# boot of a new state volume: the GitHub API lists the releases, github.com
# serves the asset, and the download redirects to the asset host.
PG_LABEL="dataloader.embedded-postgres"
PG_DOWNLOAD_HOSTS=(api.github.com github.com release-assets.githubusercontent.com)

# Docker Engine 24 is the oldest release the deploy docs and the client
# acceptance plan (CAT-HEALTH-01) support. Older engines are end of life
# upstream and untested here.
MIN_DOCKER_VERSION="24.0.0"
# The compose file uses the long `env_file` form (`path:` plus
# `required: false`), which Compose added in 2.24.0. Older plugins reject
# the file.
MIN_COMPOSE_VERSION="2.24.0"

# Disk thresholds, in GB, for the Docker data root and the install dir.
# FAIL below 5: the image is about 1 to 2 GB unpacked, an upgrade keeps the
# old and new images side by side until pruned, and first boot unpacks the
# embedded Postgres (about 0.3 GB) into the state volume.
# WARN below 20: room for months of metadata growth, the capped container
# logs (5 x 10 MB) and a few state backups in ./backups. The acceptance
# plan sizes a host at 40 GB total.
DISK_FAIL_GB=5
DISK_WARN_GB=20

# --- Settings (flags override) -----------------------------------------------

TAG=""
INSTALL_REPO_VERSION="0.1.82"
VARS_FILE=""
EXPECTED_VERSION=""
IMAGE_REPO="$DEFAULT_IMAGE_REPO"
INSTALL_DIR="/opt/dataloader"
PORT=""
BIND=""
ADMIN_EMAIL=""
COMPOSE_SRC=""
HEALTH_TIMEOUT=600
DRY_RUN=0
ASSUME_YES=0
EXTRA_ENDPOINTS=()
KEY_VAULTS=()
AUTO_UPDATE=""
REMOVE_UPDATE_UNITS=0
REFRESH_HOST_HANDLER=0
# --managed-identity (#1712): the VM's managed identity signs DataLoader in
# to Key Vault and storage through IMDS. Kept in .env across re-runs.
MANAGED_IDENTITY=0
MI_KEY=DL_AZURE_MANAGED_IDENTITY

# Which settings came from flags, so a re-run only changes what was asked.
PORT_FROM_FLAG=0
BIND_FROM_FLAG=0
IMAGE_FROM_FLAG=0

# Filled in while the script runs.
ENV_FILE=""
ENV_EXISTS=0
EXISTING_TAG=""
EXISTING_IMAGE=""
EXISTING_IMAGE_REPO=""
EXISTING_AUTO_UPDATE=""
# Set by the preflight when this host can take the host update unit.
UNITS_OK=0
# Set by the preflight (#1690): none, unrestricted or restricted; the value
# the container will run with; whether it came from the existing .env; and
# whether this run writes and loads the host profile.
AA_STATE=""
AA_VALUE=""
AA_FROM_ENV=0
AA_LOAD=0
ADMIN_PASSWORD=""
PASSWORD_GENERATED=0
MODE=""
FAILS=0
WARNS=0
declare -a ENV_ADDED=()
declare -a ENV_CHANGED=()

# --- Output helpers ------------------------------------------------------------

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 2; }

# check_result LEVEL NAME DETAIL [HINT]
# Prints one aligned preflight line and counts FAIL and WARN results.
check_result() {
    local level=$1 name=$2 detail=$3 hint=${4:-}
    printf '  %-4s  %-22s %s\n' "$level" "$name" "$detail"
    if [[ -n "$hint" && "$level" != "PASS" ]]; then
        printf '        %-22s fix: %s\n' "" "$hint"
    fi
    case "$level" in
        FAIL) FAILS=$((FAILS + 1)) ;;
        WARN) WARNS=$((WARNS + 1)) ;;
    esac
}

usage() {
    cat <<EOF
Usage: bash install.sh --tag TAG [options]

Installs or upgrades DataLoader from the published image on this host.

Options:
  --tag TAG                 Image tag to install, for example 1.0.0. Required
                            on a new install; on a re-run it defaults to the
                            tag in the existing .env. A different tag upgrades.
  --install-dir DIR         Where the compose file, .env, license/ and backups/
                            live (default: /opt/dataloader).
  --port PORT               Host port for the web app (default: 8080).
  --bind ADDR               Host address to bind (default: 127.0.0.1). Use
                            0.0.0.0 only on a private network or behind a proxy.
  --bootstrap-admin-email E First admin account, seeded on first boot only.
  --bootstrap-admin-password P Password for that first account.
  --vars FILE               Read IMAGE_TAG, EXPECTED_VERSION, INSTALL_DIR,
                            ADMIN_EMAIL and ADMIN_PASSWORD from a vars.env file.
  --check-endpoint HOST[:PORT]
                            Extra endpoint to test for DNS and reachability,
                            for example a source or a destination.
                            Repeatable. Port 443 (the default) is tested over
                            HTTPS, other ports with a TCP connect.
  --key-vault NAME|HOST     Key Vault to test for DNS and HTTPS. A bare name
                            means NAME.$KEY_VAULT_SUFFIX. Repeatable.
  --image REPO             Image repository without a tag, for a copy of the
                            image in your own registry (default:
                            $DEFAULT_IMAGE_REPO). Saved in .env as
                            DATALOADER_IMAGE_REPO; a re-run keeps it.
  --compose-file PATH       Use this compose file instead of the copy inside
                            the image (for testing a local checkout).
  --health-timeout SECONDS  How long to wait for $HEALTH_PATH (default: 600).
                            First boot sets up the embedded Postgres.
  --auto-update on|off      Daily automatic update to the newest release tag
                            (default: off; a re-run keeps the last choice).
  --managed-identity        This is an Azure VM with a managed identity: DataLoader
                            signs in to Key Vault and storage with it and stores
                            no secret. Saved in .env as
                            DL_AZURE_MANAGED_IDENTITY=imds; a re-run keeps it.
  --repair                  Same as a re-run: restores the update folder, the
                            host update unit, the automatic update choice and,
                            on Ubuntu 23.10+, the AppArmor profile plugins need.
  --remove-update-units     Take out the host update unit and the daily
                            automatic update, then exit. Apply on the Updates
                            page stays off until the next install run.
  --refresh-host-handler    Replace only the host update scripts and units and
                            install.sh with the copies in the image this
                            install runs, then exit. For an install whose host
                            update scripts are too old to refresh themselves
                            on Apply. Changes no .env, compose file, volume or
                            container. Try it with --dry-run first.
  --dry-run                 Run the preflight checks and print the plan only.
                            Changes nothing.
  --yes, -y                 Do not prompt. Needed when stdin is not a terminal.
  --help, -h                Show this help.

Bootstrap on a new host (no GitHub access needed):
  docker run --rm --entrypoint cat $DEFAULT_IMAGE_REPO:TAG \\
    $IMAGE_DEPLOY_DIR/install.sh > install.sh
  sudo bash install.sh --tag TAG
EOF
}

# --- Small utilities -------------------------------------------------------------

# version_ge A B: true when version A >= version B. Tolerates a leading "v"
# and suffixes like "-ce" or "+azure-1".
version_ge() {
    local a=${1#v} b=${2#v} i
    a=${a%%[-+~]*}
    b=${b%%[-+~]*}
    local -a av bv
    IFS=. read -r -a av <<<"$a"
    IFS=. read -r -a bv <<<"$b"
    for i in 0 1 2; do
        local x=${av[i]:-0} y=${bv[i]:-0}
        x=${x//[!0-9]/}
        y=${y//[!0-9]/}
        x=${x:-0}
        y=${y:-0}
        if ((10#$x > 10#$y)); then return 0; fi
        if ((10#$x < 10#$y)); then return 1; fi
    done
    return 0
}

is_tty() { [[ -t 0 && -t 1 ]]; }

# gen_secret: 24 random alphanumeric characters (about 140 bits).
gen_secret() {
    local raw
    raw=$(head -c 48 /dev/urandom | base64 | tr -d '\n/+=')
    printf '%s' "${raw:0:24}"
}

# env_get FILE KEY: prints the value of KEY in a dotenv file, or nothing.
# The last assignment wins, the same as compose. Surrounding quotes are
# stripped.
env_get() {
    local file=$1 key=$2 line value=""
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}=(.*)$ ]] || continue
        value=${BASH_REMATCH[2]}
        value=${value#\"}
        value=${value%\"}
        value=${value#\'}
        value=${value%\'}
    done <"$file"
    printf '%s' "$value"
}

# env_has FILE KEY: true when KEY is assigned (even to an empty value).
env_has() {
    [[ -f "$1" ]] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?$2=" "$1"
}

# env_set FILE KEY VALUE: replaces an existing assignment in place, or
# appends one. Values are validated before they get here, so they never
# contain newlines or the sed delimiter.
env_set() {
    local file=$1 key=$2 value=$3
    if env_has "$file" "$key"; then
        local tmp="$file.tmp.$$"
        sed -E "s|^[[:space:]]*(export[[:space:]]+)?$key=.*$|$key=$value|" "$file" >"$tmp"
        cat "$tmp" >"$file"
        rm -f "$tmp"
    else
        printf '%s=%s\n' "$key" "$value" >>"$file"
    fi
}

# compose_project: the compose project name compose will use for INSTALL_DIR.
compose_project() {
    local p
    # A new .env pins the name (see write_new_env).
    if [[ "$ENV_EXISTS" == 0 ]]; then
        printf 'dataloader'
        return
    fi
    p=$(env_get "$ENV_FILE" COMPOSE_PROJECT_NAME)
    if [[ -z "$p" ]]; then
        p=$(basename "$INSTALL_DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')
    fi
    printf '%s' "$p"
}

volume_name() { printf '%s_dataloader-data' "$(compose_project)"; }

image_ref() {
    if [[ -n "$EXISTING_IMAGE" ]]; then
        printf '%s' "$EXISTING_IMAGE"
    else
        printf '%s:%s' "$IMAGE_REPO" "$TAG"
    fi
}

registry_host() {
    local ref first
    ref=$(image_ref)
    # A name without a slash (`dataloader:local`) has no registry part.
    [[ "$ref" == */* ]] || return 0
    first=${ref%%/*}
    if [[ "$first" == *.* || "$first" == *:* || "$first" == localhost ]]; then
        printf '%s' "${first%%:*}"
    fi
}

# The host address to probe for health. 0.0.0.0 means every interface, so
# probe loopback.
probe_host() {
    local b=${BIND:-127.0.0.1}
    if [[ "$b" == "0.0.0.0" ]]; then b=127.0.0.1; fi
    printf '%s' "$b"
}

# compose ARGS...: runs docker compose against the install dir so compose
# reads the right .env and derives the right project name. A site's own
# docker-compose.override.yml (an extra mount, for example) goes on every
# call, as the host update script passes it: an explicit -f turns off
# compose's automatic override, so leaving it out would recreate the
# container without the site's additions.
compose() {
    local -a files=(-f "$COMPOSE_NAME")
    [[ ! -f "$INSTALL_DIR/$COMPOSE_OVERRIDE_NAME" ]] || files+=(-f "$COMPOSE_OVERRIDE_NAME")
    (cd "$INSTALL_DIR" && docker compose "${files[@]}" "$@")
}

# --- Argument parsing and validation -----------------------------------------------

parse_args() {
    if [[ $# == 0 && -f "$SCRIPT_DIR/vars.env" ]]; then
        load_install_vars "$SCRIPT_DIR/vars.env"
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tag) TAG=${2:-}; shift 2 ;;
            --tag=*) TAG=${1#*=}; shift ;;
            --install-dir) INSTALL_DIR=${2:-}; shift 2 ;;
            --install-dir=*) INSTALL_DIR=${1#*=}; shift ;;
            --port) PORT=${2:-}; PORT_FROM_FLAG=1; shift 2 ;;
            --port=*) PORT=${1#*=}; PORT_FROM_FLAG=1; shift ;;
            --bind) BIND=${2:-}; BIND_FROM_FLAG=1; shift 2 ;;
            --bind=*) BIND=${1#*=}; BIND_FROM_FLAG=1; shift ;;
            --bootstrap-admin-email) ADMIN_EMAIL=${2:-}; shift 2 ;;
            --bootstrap-admin-email=*) ADMIN_EMAIL=${1#*=}; shift ;;
            --bootstrap-admin-password) ADMIN_PASSWORD=${2:-}; shift 2 ;;
            --bootstrap-admin-password=*) ADMIN_PASSWORD=${1#*=}; shift ;;
            --vars) load_install_vars "${2:-}"; shift 2 ;;
            --vars=*) load_install_vars "${1#*=}"; shift ;;
            --check-endpoint) EXTRA_ENDPOINTS+=("${2:-}"); shift 2 ;;
            --check-endpoint=*) EXTRA_ENDPOINTS+=("${1#*=}"); shift ;;
            --key-vault) KEY_VAULTS+=("${2:-}"); shift 2 ;;
            --key-vault=*) KEY_VAULTS+=("${1#*=}"); shift ;;
            --image) IMAGE_REPO=${2:-}; IMAGE_FROM_FLAG=1; shift 2 ;;
            --image=*) IMAGE_REPO=${1#*=}; IMAGE_FROM_FLAG=1; shift ;;
            --compose-file) COMPOSE_SRC=${2:-}; shift 2 ;;
            --compose-file=*) COMPOSE_SRC=${1#*=}; shift ;;
            --health-timeout) HEALTH_TIMEOUT=${2:-}; shift 2 ;;
            --health-timeout=*) HEALTH_TIMEOUT=${1#*=}; shift ;;
            --auto-update) AUTO_UPDATE=${2:-}; shift 2 ;;
            --auto-update=*) AUTO_UPDATE=${1#*=}; shift ;;
            --repair) shift ;;
            --remove-update-units) REMOVE_UPDATE_UNITS=1; shift ;;
            --refresh-host-handler) REFRESH_HOST_HANDLER=1; shift ;;
            --managed-identity) MANAGED_IDENTITY=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes | -y) ASSUME_YES=1; shift ;;
            --help | -h) usage; exit 0 ;;
            *) usage >&2; die "unknown argument: $1" ;;
        esac
    done
    [[ -n "$INSTALL_DIR" ]] || die "--install-dir needs a value"
    INSTALL_DIR=${INSTALL_DIR%/}
    ENV_FILE="$INSTALL_DIR/.env"
}

load_install_vars() {
    local file=$1 key value
    [[ -n "$file" && -f "$file" ]] || die "vars file not found: ${file:-<empty>}"
    VARS_FILE=$file
    local -a required=(IMAGE_TAG EXPECTED_VERSION INSTALL_DIR ADMIN_EMAIL ADMIN_PASSWORD)
    for key in "${required[@]}"; do
        value=$(env_get "$VARS_FILE" "$key")
        [[ -n "$value" ]] || die "missing required value: $key in $VARS_FILE"
    done
    TAG=$(env_get "$VARS_FILE" IMAGE_TAG)
    EXPECTED_VERSION=$(env_get "$VARS_FILE" EXPECTED_VERSION)
    INSTALL_DIR=$(env_get "$VARS_FILE" INSTALL_DIR)
    ADMIN_EMAIL=$(env_get "$VARS_FILE" ADMIN_EMAIL)
    ADMIN_PASSWORD=$(env_get "$VARS_FILE" ADMIN_PASSWORD)
    (( ${#ADMIN_PASSWORD} >= 12 )) || die "ADMIN_PASSWORD must be at least 12 characters"
    COMPOSE_SRC="$SCRIPT_DIR/docker-compose.deploy.yml"
    ASSUME_YES=1
    [[ "$TAG" == "$EXPECTED_VERSION" ]] || die "IMAGE_TAG and EXPECTED_VERSION must match the version in this install repo"
    [[ -z "$INSTALL_REPO_VERSION" || "$TAG" == "$INSTALL_REPO_VERSION" ]] || die "IMAGE_TAG must match this install repo release $INSTALL_REPO_VERSION"
    [[ "$ADMIN_PASSWORD" != *$'\n'* && "$ADMIN_PASSWORD" != *$'\r'* ]] || die "ADMIN_PASSWORD must be a single line"
}

valid_tag() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; }
valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_bind() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_email() { [[ "$1" =~ ^[^[:space:]@|\"\']+@[^[:space:]@|\"\']+\.[^[:space:]@|\"\']+$ ]]; }
valid_image() { [[ "$1" =~ ^[a-z0-9][a-z0-9._/:-]*$ ]]; }
# A repository: an image name with no tag. A colon may only come before the
# first slash, as a registry port. The host update scripts copy this rule.
valid_image_repo() { valid_image "$1" && [[ "${1##*/}" != *:* ]]; }

validate_settings() {
    [[ -z "$TAG" ]] || valid_tag "$TAG" || die "invalid --tag: $TAG"
    valid_port "$PORT" || die "invalid --port: $PORT"
    valid_bind "$BIND" || die "invalid --bind (IPv4 address expected): $BIND"
    [[ -z "$ADMIN_EMAIL" ]] || valid_email "$ADMIN_EMAIL" || die "invalid --bootstrap-admin-email: $ADMIN_EMAIL"
    if ! valid_image_repo "$IMAGE_REPO"; then
        [[ "$IMAGE_FROM_FLAG" == 1 ]] || die "invalid DATALOADER_IMAGE_REPO in $ENV_FILE: $IMAGE_REPO"
        die "invalid --image (a repository without a tag, for example registry.example.com/team/dataloader; the tag goes in --tag): $IMAGE_REPO"
    fi
    [[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || die "invalid --health-timeout: $HEALTH_TIMEOUT"
    [[ -z "$COMPOSE_SRC" || -f "$COMPOSE_SRC" ]] || die "--compose-file not found: $COMPOSE_SRC"
    [[ "$AUTO_UPDATE" == on || "$AUTO_UPDATE" == off ]] || die "invalid --auto-update (on or off): $AUTO_UPDATE"
    local kv
    for kv in "${KEY_VAULTS[@]+"${KEY_VAULTS[@]}"}"; do
        valid_key_vault "$kv" || die "invalid --key-vault (a vault name or host, for example contoso-kv or contoso-kv.$KEY_VAULT_SUFFIX): $kv"
    done
}

# A vault name or host: letters, digits, dots and dashes, starting with a
# letter or digit. Azure checks the name itself; this only keeps the value safe.
valid_key_vault() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{1,252}$ ]]; }

# key_vault_host NAME|HOST: a name without a dot gets the public suffix.
key_vault_host() {
    if [[ "$1" == *.* ]]; then
        printf '%s' "$1"
    else
        printf '%s.%s' "$1" "$KEY_VAULT_SUFFIX"
    fi
}

# --- Settings resolution: existing .env, prompts, defaults ---------------------------

load_existing_env() {
    if [[ -f "$ENV_FILE" ]]; then
        ENV_EXISTS=1
        EXISTING_TAG=$(env_get "$ENV_FILE" DATALOADER_TAG)
        EXISTING_IMAGE=$(env_get "$ENV_FILE" DATALOADER_IMAGE)
        EXISTING_IMAGE_REPO=$(env_get "$ENV_FILE" DATALOADER_IMAGE_REPO)
        # A re-run keeps the repository unless --image says otherwise.
        if [[ "$IMAGE_FROM_FLAG" == 0 && -n "$EXISTING_IMAGE_REPO" ]]; then IMAGE_REPO=$EXISTING_IMAGE_REPO; fi
        EXISTING_AUTO_UPDATE=$(env_get "$ENV_FILE" DATALOADER_AUTO_UPDATE)
        if [[ "$PORT_FROM_FLAG" == 0 ]]; then PORT=$(env_get "$ENV_FILE" DATALOADER_PORT); fi
        if [[ "$BIND_FROM_FLAG" == 0 ]]; then BIND=$(env_get "$ENV_FILE" DATALOADER_BIND_ADDR); fi
    fi
}

prompt() {
    local question=$1 default=$2 answer
    read -r -p "$question [$default]: " answer </dev/tty
    printf '%s' "${answer:-$default}"
}

# Interactive prompts, only for a new install in a terminal without --yes.
# Flags always win; prompts only fill gaps.
resolve_settings() {
    local interactive=0
    if [[ "$ENV_EXISTS" == 0 && "$ASSUME_YES" == 0 && "$DRY_RUN" == 0 ]] && is_tty; then
        interactive=1
    fi

    if [[ -z "$TAG" && -n "$EXISTING_TAG" ]]; then TAG=$EXISTING_TAG; fi
    if [[ -z "$TAG" && "$ENV_EXISTS" == 1 && -z "$EXISTING_IMAGE" ]]; then
        # An old .env without DATALOADER_TAG runs the compose default.
        TAG=stable
    fi
    if [[ -z "$TAG" && "$interactive" == 1 ]]; then
        TAG=$(prompt "Image tag to install (pin a release, for example 1.0.0)" "")
    fi

    if [[ "$interactive" == 1 ]]; then
        [[ "$BIND_FROM_FLAG" == 1 ]] || BIND=$(prompt "Bind address" "127.0.0.1")
        [[ "$PORT_FROM_FLAG" == 1 ]] || PORT=$(prompt "Host port" "8080")
        if [[ -z "$ADMIN_EMAIL" ]]; then
            ADMIN_EMAIL=$(prompt "Bootstrap admin email" "")
        fi
        if [[ -n "$ADMIN_EMAIL" ]]; then
            local pw=""
            read -r -s -p "Bootstrap admin password (at least 12 characters, blank to generate): " pw </dev/tty
            printf '\n'
            if [[ -n "$pw" ]]; then
                ((${#pw} >= 12)) || die "the password must be at least 12 characters"
                [[ "$pw" != *\'* ]] || die "the password cannot contain a single quote"
                ADMIN_PASSWORD=$pw
            fi
        fi
    fi

    if [[ -z "$AUTO_UPDATE" && "$interactive" == 1 ]]; then
        case "$(prompt "Enable daily automatic updates to the newest release? (y/N)" "n")" in
            [yY] | [yY][eE][sS] | on) AUTO_UPDATE=on ;;
            *) AUTO_UPDATE=off ;;
        esac
    fi
    # A re-run keeps the last choice unless --auto-update says otherwise.
    AUTO_UPDATE=${AUTO_UPDATE:-${EXISTING_AUTO_UPDATE:-off}}

    PORT=${PORT:-8080}
    BIND=${BIND:-127.0.0.1}

    if [[ "$ENV_EXISTS" == 0 && -n "$ADMIN_EMAIL" && -z "$ADMIN_PASSWORD" ]]; then
        ADMIN_PASSWORD=$(gen_secret)
        PASSWORD_GENERATED=1
    fi

    if [[ -z "$TAG" && -z "$EXISTING_IMAGE" ]]; then
        die "--tag is required for a new install (for example --tag 1.0.0)"
    fi
    if [[ "$ENV_EXISTS" == 0 && -z "$ADMIN_EMAIL" && "$DRY_RUN" == 0 ]]; then
        die "--bootstrap-admin-email is required for a new install; it is the first account that can sign in"
    fi
    validate_settings
}

# --- Mode: fresh install, verify, or upgrade ----------------------------------------

# repo_changed: an existing install that --image moves to another repository.
repo_changed() {
    [[ "$ENV_EXISTS" == 1 && -z "$EXISTING_IMAGE" && "$IMAGE_REPO" != "${EXISTING_IMAGE_REPO:-$DEFAULT_IMAGE_REPO}" ]]
}

decide_mode() {
    if [[ "$ENV_EXISTS" == 0 ]]; then
        MODE=install
    elif [[ -n "$EXISTING_IMAGE" ]]; then
        MODE=verify
    elif [[ "$TAG" == "${EXISTING_TAG:-stable}" ]] && ! repo_changed; then
        MODE=verify
    else
        MODE=upgrade
    fi
}

# --- Preflight checks ------------------------------------------------------------------

# os_release_value KEY: one value from the os-release file, quotes removed.
os_release_value() {
    sed -nE 's/^'"$1"'="?([^"]*)"?$/\1/p' "$OS_RELEASE_FILE" | head -n 1
}

check_os() {
    local id="" pretty="" arch
    arch=$(uname -m 2>/dev/null || echo unknown)
    if [[ -r "$OS_RELEASE_FILE" ]]; then
        id="$(os_release_value ID) $(os_release_value ID_LIKE)"
        pretty=$(os_release_value PRETTY_NAME)
        pretty=${pretty:-unknown}
    fi
    if [[ "$id" == *ubuntu* || "$id" == *debian* ]]; then
        check_result PASS "operating system" "$pretty ($arch)"
    else
        check_result WARN "operating system" "${pretty:-$(uname -s 2>/dev/null)} ($arch) is not Ubuntu or Debian" \
            "supported hosts are Ubuntu 22.04+ and Debian 12+; other Linux distros usually work"
    fi
    case "$arch" in
        x86_64 | amd64) ;;
        *) check_result WARN "cpu architecture" "$arch" \
            "the release image may be amd64 only; check with: docker manifest inspect $(image_ref)" ;;
    esac
}

# Sets DOCKER_OK=1 when the daemon answers, so later checks can use it.
DOCKER_OK=0
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        check_result FAIL "docker cli" "docker is not installed" \
            "install Docker Engine: https://docs.docker.com/engine/install/ (curl -fsSL https://get.docker.com | sh)"
        return
    fi
    local server
    if ! server=$(docker version --format '{{.Server.Version}}' 2>/dev/null) || [[ -z "$server" ]]; then
        check_result FAIL "docker daemon" "cannot reach the Docker daemon" \
            "start it (sudo systemctl start docker), or run as root, or add your user to the docker group and log in again"
        return
    fi
    DOCKER_OK=1
    check_result PASS "docker daemon" "reachable"
    if version_ge "$server" "$MIN_DOCKER_VERSION"; then
        check_result PASS "docker engine" "$server (need $MIN_DOCKER_VERSION or later)"
    else
        check_result FAIL "docker engine" "$server is older than $MIN_DOCKER_VERSION" \
            "upgrade Docker Engine: https://docs.docker.com/engine/install/"
    fi
    local cv
    if ! cv=$(docker compose version --short 2>/dev/null) || [[ -z "$cv" ]]; then
        check_result FAIL "compose plugin" "docker compose v2 is not installed" \
            "install the plugin: sudo apt-get install docker-compose-plugin (the old docker-compose v1 is not supported)"
    elif version_ge "$cv" "$MIN_COMPOSE_VERSION"; then
        check_result PASS "compose plugin" "$cv (need $MIN_COMPOSE_VERSION or later)"
    else
        check_result FAIL "compose plugin" "$cv is older than $MIN_COMPOSE_VERSION" \
            "upgrade: sudo apt-get install --only-upgrade docker-compose-plugin"
    fi
}

check_tools() {
    if command -v curl >/dev/null 2>&1; then
        check_result PASS "curl" "present"
    else
        check_result FAIL "curl" "curl is not installed" "sudo apt-get install -y curl"
    fi
}

# nearest_existing PATH: PATH or its closest existing parent.
nearest_existing() {
    local p=$1
    while [[ ! -e "$p" && "$p" != "/" && "$p" != "." ]]; do p=$(dirname "$p"); done
    printf '%s' "$p"
}

check_install_dir() {
    local target
    target=$(nearest_existing "$INSTALL_DIR")
    if [[ -w "$target" ]]; then
        check_result PASS "install dir" "$INSTALL_DIR is writable"
    else
        check_result FAIL "install dir" "cannot write to $target" \
            "re-run with sudo, or pick a writable path with --install-dir"
    fi
}

# port_listening HOST PORT: true when something accepts TCP connections.
port_listening() {
    local host=$1 port=$2
    if command -v ss >/dev/null 2>&1; then
        [[ -n "$(ss -Hltn "sport = :$port" 2>/dev/null)" ]]
        return
    fi
    timeout 2 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null
}

check_port() {
    if ! port_listening "$(probe_host)" "$PORT"; then
        check_result PASS "port $PORT" "free on $BIND"
    elif [[ "$ENV_EXISTS" == 1 && "$DOCKER_OK" == 1 ]] && [[ -n "$(compose ps -q 2>/dev/null || true)" ]]; then
        check_result PASS "port $PORT" "in use by this DataLoader install"
    else
        check_result FAIL "port $PORT" "already in use" \
            "stop the process on port $PORT (sudo ss -ltnp 'sport = :$PORT'), or pick another with --port"
    fi
}

# free_gb PATH: free space in whole GB on the filesystem holding PATH.
free_gb() {
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }'
}

mount_of() {
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $6 }'
}

check_disk_path() {
    local label=$1 path=$2 gb
    gb=$(free_gb "$path")
    if [[ -z "$gb" ]]; then
        check_result WARN "$label" "could not read free space for $path" "check by hand with: df -h $path"
    elif ((gb < DISK_FAIL_GB)); then
        check_result FAIL "$label" "${gb} GB free at $path (need ${DISK_FAIL_GB} GB)" \
            "free space (docker system prune) or grow the disk"
    elif ((gb < DISK_WARN_GB)); then
        check_result WARN "$label" "${gb} GB free at $path (${DISK_WARN_GB} GB recommended)" \
            "plan for metadata growth and backups; grow the disk when you can"
    else
        check_result PASS "$label" "${gb} GB free at $path"
    fi
}

check_disk() {
    local root=""
    if [[ "$DOCKER_OK" == 1 ]]; then
        root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
    fi
    # Docker Desktop reports a path inside its VM; fall back to the usual
    # location, then to the filesystem root.
    [[ -n "$root" && -d "$root" ]] || root=/var/lib/docker
    [[ -d "$root" ]] || root=/
    local install_path
    install_path=$(nearest_existing "$INSTALL_DIR")
    check_disk_path "disk (docker data)" "$root"
    if [[ "$(mount_of "$root")" != "$(mount_of "$install_path")" ]]; then
        check_disk_path "disk (install dir)" "$install_path"
    fi
}

# resolve_host HOST: 0 when HOST resolves, 1 when it does not, 3 when no
# lookup tool exists. (getent itself exits 2 for "not found".)
resolve_host() {
    local host=$1
    if command -v getent >/dev/null 2>&1; then
        getent hosts "$host" >/dev/null 2>&1 || return 1
    elif command -v host >/dev/null 2>&1; then
        host "$host" >/dev/null 2>&1 || return 1
    elif command -v nslookup >/dev/null 2>&1; then
        # nslookup exits 0 on some platforms even when the lookup fails, so
        # look for an answer instead.
        nslookup "$host" 2>/dev/null | grep -Eq '^(Name|Address(es)?):' &&
            ! nslookup "$host" 2>&1 | grep -qiE "can't find|NXDOMAIN" || return 1
    else
        return 3
    fi
}

# https_code HOST: prints the HTTP status of https://HOST/ (000 on failure).
# Any status means TLS and the network path work; a 401 from a registry or
# a 404 from a login page is still reachable.
https_code() {
    curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 -m 15 "https://$1/" 2>/dev/null || true
}

# check_endpoint LABEL HOST[:PORT] LEVEL_ON_FAIL HINT
check_endpoint() {
    local label=$1 target=$2 fail_level=$3 hint=$4
    local host=${target%%:*} port=443
    [[ "$target" == *:* ]] && port=${target##*:}
    local rc=0
    # An IPv4 literal has nothing to resolve.
    valid_bind "$host" || resolve_host "$host" || rc=$?
    if ((rc == 3)); then
        check_result WARN "$label" "$host: no DNS tool (getent, host or nslookup) to test with" "install libc-bin or dnsutils"
    elif ((rc != 0)); then
        check_result "$fail_level" "$label" "$host does not resolve" \
            "check /etc/resolv.conf and the corporate DNS; $hint"
        return
    fi
    if [[ "$port" == 443 ]]; then
        local code
        code=$(https_code "$host")
        if [[ -n "$code" && "$code" != 000 ]]; then
            check_result PASS "$label" "https://$host reachable (HTTP $code)"
        else
            check_result "$fail_level" "$label" "cannot open https://$host" \
                "allow outbound HTTPS to $host in the firewall or proxy; $hint"
        fi
    elif timeout 5 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
        check_result PASS "$label" "$host:$port accepts TCP connections"
    else
        check_result "$fail_level" "$label" "cannot connect to $host:$port" \
            "allow outbound TCP $port to $host; $hint"
    fi
}

check_network() {
    local reg
    reg=$(registry_host)
    if [[ -z "$reg" ]]; then
        check_result PASS "registry" "local image $(image_ref), no registry needed"
    elif [[ "$DOCKER_OK" == 1 ]] && docker image inspect "$(image_ref)" >/dev/null 2>&1; then
        check_endpoint "registry" "$reg" WARN "the image is already on this host, so install can continue"
    else
        check_endpoint "registry" "$reg" FAIL "the image is pulled from $reg"
    fi
    check_endpoint "entra id" "$ENTRA_HOST" WARN "needed for Microsoft sign-in (SSO) and Azure access"
    local ep kv
    for kv in "${KEY_VAULTS[@]+"${KEY_VAULTS[@]}"}"; do
        check_endpoint "key vault" "$(key_vault_host "$kv")" WARN \
            "DataLoader cannot read secrets from this vault until this is fixed"
    done
    for ep in "${EXTRA_ENDPOINTS[@]+"${EXTRA_ENDPOINTS[@]}"}"; do
        [[ -n "$ep" ]] || continue
        check_endpoint "endpoint" "$ep" WARN "DataLoader will not reach $ep until this is fixed"
    done
}

# image_pg_label: prints the image's embedded Postgres label, or nothing
# when the image has none. Fails when the image is not on this host.
image_pg_label() {
    local out
    out=$(docker image inspect -f "{{ index .Config.Labels \"$PG_LABEL\" }}" "$(image_ref)" 2>/dev/null) || return 1
    [[ "$out" != "<no value>" ]] || out=""
    printf '%s' "$out"
}

# check_pg_download: images before #1476 download the embedded Postgres
# from GitHub on the first boot of a new state volume, so a site that
# blocks GitHub never gets a healthy container. Tests those hosts only when
# that download can happen.
check_pg_download() {
    local label="" why host hosts
    if [[ -n "$(env_get "$ENV_FILE" DL_DATABASE_URL)" ]]; then
        check_result PASS "embedded postgres" "not used: DL_DATABASE_URL is set in $ENV_FILE"
        return
    fi
    # Without a daemon the docker check has already failed.
    [[ "$DOCKER_OK" == 1 ]] || return 0
    hosts="${PG_DOWNLOAD_HOSTS[0]}, ${PG_DOWNLOAD_HOSTS[1]} and ${PG_DOWNLOAD_HOSTS[2]}"
    if label=$(image_pg_label); then
        if [[ -n "$label" ]]; then
            check_result PASS "embedded postgres" "$label is built into the image, first boot downloads nothing"
            return
        fi
        why="$(image_ref) downloads the embedded Postgres from $hosts on first boot"
    else
        why="$(image_ref) is not on this host yet, and images before #1476 download the embedded Postgres from $hosts on first boot"
    fi
    if [[ "$MODE" != install ]] && docker volume inspect "$(volume_name)" >/dev/null 2>&1; then
        check_result PASS "embedded postgres" "already unpacked in the state volume $(volume_name)"
        return
    fi
    for host in "${PG_DOWNLOAD_HOSTS[@]}"; do
        check_endpoint "postgres download" "$host" WARN \
            "$why; or set DL_DATABASE_URL in $ENV_FILE to use an external Postgres"
    done
}

# units_supported: root on a host that runs systemd.
units_supported() {
    [[ "$(id -u)" == 0 ]] && command -v systemctl >/dev/null 2>&1 && [[ -d "$SYSTEMD_RUNTIME_DIR" ]]
}

check_update_units() {
    if ! units_supported; then
        check_result WARN "one-click updates" "needs root and systemd, so Apply on the Updates page stays off" \
            "re-run with sudo on a host that runs systemd; updates by hand still work"
    elif [[ ! "$INSTALL_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        check_result WARN "one-click updates" "the install dir $INSTALL_DIR has characters a systemd unit path cannot hold" \
            "use an --install-dir of letters, digits, '.', '_', '-' and '/'"
    else
        UNITS_OK=1
        check_result PASS "one-click updates" "host update unit in $SYSTEMD_DIR, daily automatic update $AUTO_UPDATE"
    fi
}

# apparmor_state: none when AppArmor is off, restricted when the kernel
# denies unprivileged user namespaces to unconfined processes (Ubuntu 23.10
# and later), unrestricted otherwise.
apparmor_state() {
    local enabled="" restrict=""
    if [[ -r "$APPARMOR_ENABLED_FILE" ]]; then
        enabled=$(head -c 1 -- "$APPARMOR_ENABLED_FILE" 2>/dev/null || true)
    fi
    if [[ "$enabled" != Y ]]; then
        printf none
        return
    fi
    if [[ -r "$USERNS_RESTRICT_FILE" ]]; then
        restrict=$(tr -d '[:space:]' <"$USERNS_RESTRICT_FILE" 2>/dev/null || true)
    fi
    if [[ "$restrict" == 1 ]]; then printf restricted; else printf unrestricted; fi
}

# check_apparmor: works out the AppArmor profile the container runs with
# (#1690). A value already in .env is kept, whatever it is.
check_apparmor() {
    local name="apparmor userns"
    AA_STATE=$(apparmor_state)
    AA_VALUE=""
    AA_FROM_ENV=0
    AA_LOAD=0
    if env_has "$ENV_FILE" "$APPARMOR_KEY"; then
        AA_VALUE=$(env_get "$ENV_FILE" "$APPARMOR_KEY")
        AA_FROM_ENV=1
    elif [[ "$AA_STATE" == restricted ]]; then
        AA_VALUE=$APPARMOR_PROFILE
    fi
    if [[ "$AA_FROM_ENV" == 1 && "$AA_VALUE" != "$APPARMOR_PROFILE" ]]; then
        if [[ "$AA_STATE" == restricted ]]; then
            check_result WARN "$name" "kept $APPARMOR_KEY=${AA_VALUE:-(empty)} from .env; this host restricts user namespaces, so plugins need a profile that grants userns" \
                "remove $APPARMOR_KEY from $ENV_FILE and re-run to load $APPARMOR_PROFILE"
        else
            check_result PASS "$name" "kept $APPARMOR_KEY=${AA_VALUE:-(empty)} from .env"
        fi
        return
    fi
    if [[ "$AA_VALUE" != "$APPARMOR_PROFILE" ]]; then
        case "$AA_STATE" in
            none) check_result PASS "$name" "not needed: AppArmor is not enabled" ;;
            *) check_result PASS "$name" "not needed: the kernel does not restrict unprivileged user namespaces" ;;
        esac
        return
    fi
    if [[ "$AA_STATE" == none ]]; then
        check_result WARN "$name" "kept $APPARMOR_KEY=$APPARMOR_PROFILE from .env, but AppArmor is not enabled" \
            "remove $APPARMOR_KEY from $ENV_FILE"
        return
    fi
    local why="kept from .env"
    [[ "$AA_STATE" != restricted ]] || why="kernel.apparmor_restrict_unprivileged_userns=1"
    if [[ "$(id -u)" != 0 ]]; then
        check_result FAIL "$name" "the profile $APPARMOR_PROFILE must be loaded ($why), which needs root" \
            "re-run with sudo; without the profile no plugin can start"
    elif ! command -v apparmor_parser >/dev/null 2>&1; then
        check_result FAIL "$name" "the profile $APPARMOR_PROFILE must be loaded ($why), but apparmor_parser is not installed" \
            "sudo apt-get install -y apparmor, then re-run"
    else
        AA_LOAD=1
        check_result PASS "$name" "profile $APPARMOR_PROFILE will be loaded into $APPARMOR_DIR ($why)"
    fi
}

check_existing() {
    case "$MODE" in
        install)
            check_result PASS "existing install" "none in $INSTALL_DIR" ;;
        verify)
            if [[ -n "$EXISTING_IMAGE" ]]; then
                check_result WARN "existing install" "found; .env pins DATALOADER_IMAGE=$EXISTING_IMAGE, so --tag is ignored" \
                    "to change versions, edit or remove DATALOADER_IMAGE in $ENV_FILE"
            else
                check_result PASS "existing install" "found at tag ${EXISTING_TAG:-stable}; this run verifies it"
            fi ;;
        upgrade)
            if repo_changed; then
                check_result WARN "existing install" "found at ${EXISTING_IMAGE_REPO:-$DEFAULT_IMAGE_REPO}:${EXISTING_TAG:-stable}; this run moves it to $(image_ref)" \
                    "back up the state volume first (see the plan below)"
            else
                check_result WARN "existing install" "found at tag ${EXISTING_TAG:-stable}; this run upgrades to $TAG" \
                    "back up the state volume first (see the plan below)"
            fi ;;
    esac
}

run_preflight() {
    step "Preflight checks"
    check_os
    check_docker
    check_tools
    check_install_dir
    check_port
    check_disk
    check_network
    check_pg_download
    check_update_units
    check_apparmor
    check_existing
    say ""
    say "  $FAILS failed, $WARNS warnings"
}

# --- Plan ------------------------------------------------------------------------------

# aa_env_needed: this run adds DATALOADER_APPARMOR_PROFILE to .env. Only a
# restricted host without the key gets it; a value already there is kept.
aa_env_needed() { [[ "$AA_FROM_ENV" == 0 && "$AA_VALUE" == "$APPARMOR_PROFILE" ]]; }

# Works out the .env changes without touching the file, so the plan and the
# real run agree. Fills ENV_ADDED and ENV_CHANGED with key names only.
plan_env_changes() {
    ENV_ADDED=()
    ENV_CHANGED=()
    if [[ "$ENV_EXISTS" == 0 ]]; then
        ENV_ADDED=(COMPOSE_PROJECT_NAME DATALOADER_TAG DATALOADER_BIND_ADDR DATALOADER_PORT DATALOADER_AUTO_UPDATE)
        if [[ "$IMAGE_REPO" != "$DEFAULT_IMAGE_REPO" ]]; then
            ENV_ADDED+=(DATALOADER_IMAGE_REPO)
        fi
        if aa_env_needed; then
            ENV_ADDED+=("$APPARMOR_KEY")
        fi
        if [[ "$MANAGED_IDENTITY" == 1 ]]; then
            ENV_ADDED+=("$MI_KEY")
        fi
        if [[ -n "$ADMIN_EMAIL" ]]; then
            ENV_ADDED+=(DL_BOOTSTRAP_ADMIN_EMAIL DL_BOOTSTRAP_ADMIN_PASSWORD)
        fi
        return
    fi
    if aa_env_needed; then
        ENV_ADDED+=("$APPARMOR_KEY")
    fi
    # --managed-identity on an existing install; without the flag the key
    # stays as it is.
    if [[ "$MANAGED_IDENTITY" == 1 ]]; then
        if ! env_has "$ENV_FILE" "$MI_KEY"; then
            ENV_ADDED+=("$MI_KEY")
        elif [[ "$(env_get "$ENV_FILE" "$MI_KEY")" != imds ]]; then
            ENV_CHANGED+=("$MI_KEY")
        fi
    fi
    # Existing .env: add missing keys that only restate the defaults, and
    # change keys the operator asked to change. Never add
    # COMPOSE_PROJECT_NAME (it would rename the state volume) or the
    # bootstrap admin keys (a missing password means the operator removed
    # it on purpose).
    if [[ -z "$EXISTING_IMAGE" ]]; then
        if ! env_has "$ENV_FILE" DATALOADER_TAG; then
            ENV_ADDED+=(DATALOADER_TAG)
        elif [[ "$TAG" != "$EXISTING_TAG" ]]; then
            ENV_CHANGED+=(DATALOADER_TAG)
        fi
        if repo_changed; then
            if env_has "$ENV_FILE" DATALOADER_IMAGE_REPO; then
                ENV_CHANGED+=(DATALOADER_IMAGE_REPO)
            else
                ENV_ADDED+=(DATALOADER_IMAGE_REPO)
            fi
        fi
    fi
    local key value
    for key in DATALOADER_BIND_ADDR DATALOADER_PORT DATALOADER_AUTO_UPDATE; do
        case "$key" in
            DATALOADER_PORT) value=$PORT ;;
            DATALOADER_AUTO_UPDATE) value=$AUTO_UPDATE ;;
            *) value=$BIND ;;
        esac
        if ! env_has "$ENV_FILE" "$key"; then
            ENV_ADDED+=("$key")
        elif [[ "$(env_get "$ENV_FILE" "$key")" != "$value" ]]; then
            ENV_CHANGED+=("$key")
        fi
    done
}

print_plan() {
    step "Plan"
    local ref
    ref=$(image_ref)
    say "  Mode:          $MODE"
    say "  Image:         $ref"
    say "  Install dir:   $INSTALL_DIR"
    say "  URL:           http://$(probe_host):$PORT/"
    say "  State volume:  $(volume_name) (named Docker volume)"
    say ""
    say "  Steps:"
    case "$MODE" in
        install)
            say "    1. Create $INSTALL_DIR with license/ and backups/"
            say "    2. Pull $ref"
            say "    3. Copy $COMPOSE_NAME, $SECCOMP_NAME and install.sh out of the image"
            say "    4. Write $ENV_FILE (mode 0600): ${ENV_ADDED[*]}"
            say "    5. docker compose up -d"
            say "    6. Wait up to ${HEALTH_TIMEOUT}s for $HEALTH_PATH" ;;
        verify)
            say "    1. Keep $ENV_FILE$(describe_env_changes)"
            say "    2. Refresh $COMPOSE_NAME and $SECCOMP_NAME from the image if they differ (old compose goes to .compose-backups/)"
            say "    3. docker compose up -d (no-op when already running)"
            say "    4. Check $HEALTH_PATH and report" ;;
        upgrade)
            say "    0. Recommended first: back up the state volume (stops nothing):"
            say "       $(backup_command)"
            say "    1. Copy $ENV_FILE to .env-backups/, then update it$(describe_env_changes)"
            say "    2. Pull $ref"
            say "    3. Replace $COMPOSE_NAME and $SECCOMP_NAME with the copies from the new image (old compose goes to .compose-backups/)"
            say "    4. docker compose up -d (recreates the container; migrations run on boot)"
            say "    5. Wait up to ${HEALTH_TIMEOUT}s for $HEALTH_PATH" ;;
    esac
    say ""
    if [[ "$UNITS_OK" == 1 ]]; then
        say "  One-click updates: $INSTALL_DIR/$UPDATE_DIR_NAME for uid $CONTAINER_UID (mode 0750), the host update"
        say "  unit in $SYSTEMD_DIR, daily automatic update $AUTO_UPDATE."
    else
        say "  One-click updates: off on this run (see the preflight). $INSTALL_DIR/$UPDATE_DIR_NAME is still created."
    fi
    if [[ "$AA_LOAD" == 1 ]]; then
        say "  AppArmor: write $APPARMOR_DIR/$APPARMOR_PROFILE, load it with apparmor_parser -r, and run the"
        say "  container with apparmor=$APPARMOR_PROFILE ($APPARMOR_KEY in .env), so plugins can start."
    elif [[ "$AA_FROM_ENV" == 1 ]]; then
        say "  AppArmor: keep $APPARMOR_KEY=${AA_VALUE:-(empty)} from .env; no profile written."
    else
        say "  AppArmor: no host profile needed; the container runs with apparmor=unconfined."
    fi
    if [[ "$MANAGED_IDENTITY" == 1 ]]; then
        say "  Managed identity: DataLoader signs in to Key Vault and storage with this VM's identity ($MI_KEY=imds)."
    fi
    if [[ "$PASSWORD_GENERATED" == 1 ]]; then
        say ""
        say "  A bootstrap admin password will be generated and stored in $ENV_FILE only."
    elif [[ "$MODE" == install && -z "$ADMIN_EMAIL" ]]; then
        say ""
        say "  The real run needs --bootstrap-admin-email (or a terminal to prompt in)."
    fi
}

describe_env_changes() {
    local out=""
    ((${#ENV_ADDED[@]} == 0)) || out+=", add: ${ENV_ADDED[*]}"
    ((${#ENV_CHANGED[@]} == 0)) || out+=", change: ${ENV_CHANGED[*]}"
    [[ -n "$out" ]] || out=", no changes"
    printf '%s' "$out"
}

backup_command() {
    # The $(date) is printed for the operator to run, not expanded here.
    # shellcheck disable=SC2016
    printf 'docker run --rm -v %s:/data:ro -v %s/backups:/backup alpine tar czf /backup/dataloader-data-$(date +%%F).tgz -C /data .' \
        "$(volume_name)" "$INSTALL_DIR"
}

confirm() {
    if [[ "$ASSUME_YES" == 1 ]]; then return 0; fi
    if ! is_tty; then
        die "not running in a terminal; re-run with --yes to proceed without a prompt"
    fi
    local answer
    read -r -p "Proceed? [y/N]: " answer </dev/tty
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || { say "Aborted, nothing changed."; exit 1; }
}

# --- Apply -------------------------------------------------------------------------------

write_new_env() {
    local escaped_password
    escaped_password=${ADMIN_PASSWORD//\\/\\\\}
    escaped_password=${escaped_password//\'/\\\'}
    # umask in a subshell so the file is never readable by others, even
    # for a moment.
    (
        umask 077
        {
            say "# DataLoader deploy settings, written by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)."
            say "# See docs/runbooks/install-linux-host.md and docs/admin-guide/deploy.md."
            say ""
            say "# Keeps the state volume named dataloader_dataloader-data wherever this"
            say "# directory lives. Do not change it on an existing install."
            say "COMPOSE_PROJECT_NAME=dataloader"
            if [[ "$IMAGE_REPO" != "$DEFAULT_IMAGE_REPO" ]]; then
                say "# The registry copy this install runs (install.sh --image). Apply and"
                say "# the daily automatic update change DATALOADER_TAG within it."
                say "DATALOADER_IMAGE_REPO=$IMAGE_REPO"
            fi
            say "DATALOADER_TAG=$TAG"
            say "DATALOADER_BIND_ADDR=$BIND"
            say "DATALOADER_PORT=$PORT"
            say "# Daily automatic update to the newest release (on or off). install.sh"
            say "# reads it on a re-run; change it with install.sh --auto-update on|off."
            say "DATALOADER_AUTO_UPDATE=$AUTO_UPDATE"
            if aa_env_needed; then
                say "# This host restricts unprivileged user namespaces (Ubuntu 23.10+), so the"
                say "# container runs under the host AppArmor profile install.sh loads. It grants"
                say "# the plugin sandbox its user namespace. Unset means apparmor=unconfined."
                say "$APPARMOR_KEY=$APPARMOR_PROFILE"
            fi
            if [[ "$MANAGED_IDENTITY" == 1 ]]; then
                say "# This VM's managed identity signs DataLoader in to Key Vault and storage"
                say "# through IMDS (install.sh --managed-identity), with no stored secret."
                say "$MI_KEY=imds"
            fi
            if [[ -n "$ADMIN_EMAIL" ]]; then
                say ""
                say "# First-boot admin. Read once, when the database has no users."
                say "# Delete both lines after the first sign-in."
                say "DL_BOOTSTRAP_ADMIN_EMAIL=$ADMIN_EMAIL"
                # Single quotes stop compose from expanding a `$` in the value.
                say "DL_BOOTSTRAP_ADMIN_PASSWORD='$escaped_password'"
            fi
            say ""
            say "# RUST_LOG=info,dataloader=info"
        } >"$ENV_FILE"
    )
    chmod 600 "$ENV_FILE"
}

# root_backup FILE SUBDIR NAME: copies FILE to <install dir>/SUBDIR/NAME and
# prints the path. SUBDIR is root-only (0700) and mounted into no container.
# backups/ is mounted into the container, so a predictable name there could
# be a planted symlink that cp would write through. NAME ends in the
# timestamp, so sorting the copies that share NAME's prefix finds the
# newest BACKUP_KEEP to keep. The prefix matters in .compose-backups/, which
# also holds the seccomp profile's copies from one-click updates (#1792).
BACKUP_KEEP=10
root_backup() {
    local src=$1 bdir="$INSTALL_DIR/$2" name=$3 tmp old prefix
    prefix=${name%[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].bak}
    [[ ! -L "$bdir" ]] || die "$bdir is a symlink; remove it and re-run"
    mkdir -p -m 0700 -- "$bdir"
    chmod 0700 -- "$bdir"
    tmp=$(mktemp "$bdir/.new.XXXXXX")
    cat -- "$src" >"$tmp"
    chmod 0600 -- "$tmp"
    mv -fT -- "$tmp" "$bdir/$name"
    while IFS= read -r old; do
        rm -f -- "$bdir/$old"
    done < <(ls -1 -- "$bdir" | grep -E "^${prefix//./\\.}[0-9]{8}-[0-9]{6}\.bak$" | sort -r | tail -n +$((BACKUP_KEEP + 1)))
    printf '%s' "$bdir/$name"
}

apply_env() {
    if [[ "$ENV_EXISTS" == 0 ]]; then
        write_new_env
        say "  wrote $ENV_FILE (mode 0600), keys: ${ENV_ADDED[*]}"
        return
    fi
    if ((${#ENV_ADDED[@]} + ${#ENV_CHANGED[@]} > 0)); then
        local backup
        backup=$(root_backup "$ENV_FILE" .env-backups "env-$(date +%Y%m%d-%H%M%S).bak")
        say "  copied the old .env to $backup"
        # Existing files may lack a trailing newline; appending would glue
        # the new key onto the last line.
        [[ -z "$(tail -c 1 "$ENV_FILE")" ]] || printf '\n' >>"$ENV_FILE"
    fi
    local key
    for key in "${ENV_ADDED[@]+"${ENV_ADDED[@]}"}" "${ENV_CHANGED[@]+"${ENV_CHANGED[@]}"}"; do
        case "$key" in
            DATALOADER_TAG) env_set "$ENV_FILE" "$key" "$TAG" ;;
            DATALOADER_IMAGE_REPO) env_set "$ENV_FILE" "$key" "$IMAGE_REPO" ;;
            DATALOADER_PORT) env_set "$ENV_FILE" "$key" "$PORT" ;;
            DATALOADER_BIND_ADDR) env_set "$ENV_FILE" "$key" "$BIND" ;;
            DATALOADER_AUTO_UPDATE) env_set "$ENV_FILE" "$key" "$AUTO_UPDATE" ;;
            "$APPARMOR_KEY") env_set "$ENV_FILE" "$key" "$APPARMOR_PROFILE" ;;
            "$MI_KEY") env_set "$ENV_FILE" "$key" imds ;;
        esac
    done
    chmod 600 "$ENV_FILE"
    say "  kept $ENV_FILE$(describe_env_changes)"
}

# Copies a file out of the image without starting the app.
image_cat() {
    # MSYS_NO_PATHCONV stops Git Bash on Windows from rewriting the
    # container path; Linux ignores it.
    MSYS_NO_PATHCONV=1 docker run --rm --entrypoint cat "$(image_ref)" "$1"
}

# check_compose_reads_repo: compose files before #1662 ignore
# DATALOADER_IMAGE_REPO, so a mirrored install would start the default
# repository. Runs before .env changes, so a stop leaves the install as it was.
check_compose_reads_repo() {
    [[ -z "$EXISTING_IMAGE" && "$IMAGE_REPO" != "$DEFAULT_IMAGE_REPO" ]] || return 0
    local src
    if [[ -n "$COMPOSE_SRC" ]]; then
        src=$(cat -- "$COMPOSE_SRC")
    else
        src=$(image_cat "$IMAGE_DEPLOY_DIR/$COMPOSE_NAME" 2>/dev/null) || src=""
    fi
    # An image without the compose file stops later with its own message.
    [[ -z "$src" || "$src" == *'${DATALOADER_IMAGE_REPO'* ]] ||
        die "the $COMPOSE_NAME in $(image_ref) does not read DATALOADER_IMAGE_REPO (images before #1662), so it would run $DEFAULT_IMAGE_REPO; install a newer tag or pass --compose-file"
}

# The compose file runs the container with this seccomp profile so the
# plugin sandbox (bubblewrap) can create namespaces (ADR 0027). Compose
# refuses to start without it, so a missing profile is fatal.
install_seccomp_profile() {
    local dst="$INSTALL_DIR/$SECCOMP_NAME" tmp="$INSTALL_DIR/.seccomp.new"
    mkdir -p "$(dirname "$dst")"
    if ! image_cat "$IMAGE_DEPLOY_DIR/$(basename "$SECCOMP_NAME")" >"$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        die "the image $(image_ref) has no $IMAGE_DEPLOY_DIR/$(basename "$SECCOMP_NAME") (images before #1417 lack it)"
    fi
    if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        return
    fi
    mv "$tmp" "$dst"
    say "  installed $dst"
}

install_compose_file() {
    local dst="$INSTALL_DIR/$COMPOSE_NAME" tmp="$INSTALL_DIR/.$COMPOSE_NAME.new"
    install_seccomp_profile
    if [[ -n "$COMPOSE_SRC" ]]; then
        cp "$COMPOSE_SRC" "$tmp"
    elif ! image_cat "$IMAGE_DEPLOY_DIR/$COMPOSE_NAME" >"$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        die "the image $(image_ref) has no $IMAGE_DEPLOY_DIR/$COMPOSE_NAME (images before #1432 lack it); pass --compose-file"
    fi
    if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
        rm -f "$tmp"
        say "  $COMPOSE_NAME is current"
        return
    fi
    if [[ -f "$dst" ]]; then
        local backup
        backup=$(root_backup "$dst" .compose-backups "$COMPOSE_NAME.$(date +%Y%m%d-%H%M%S).bak")
        say "  copied the old $COMPOSE_NAME to $backup"
    fi
    mv "$tmp" "$dst"
    say "  installed $dst"
    # Keep a copy of the matching installer for later re-runs. Optional.
    if [[ -z "$COMPOSE_SRC" ]] && image_cat "$IMAGE_DEPLOY_DIR/install.sh" >"$INSTALL_DIR/install.sh.new" 2>/dev/null &&
        [[ -s "$INSTALL_DIR/install.sh.new" ]]; then
        mv "$INSTALL_DIR/install.sh.new" "$INSTALL_DIR/install.sh"
    else
        rm -f "$INSTALL_DIR/install.sh.new"
    fi
}

# The host AppArmor profile the container runs under on a restricted host
# (#1690). flags=(unconfined) keeps the container as free as
# apparmor=unconfined; the one rule it adds is userns, which the kernel
# checks before it lets bwrap create a user namespace.
# .github/workflows/demo-e2e.yml loads a copy of this profile on the hosted
# runner; keep the two profile texts the same.
apparmor_profile_text() {
    cat <<EOF
# Written by DataLoader install.sh (#1690). The DataLoader container runs
# under this profile so the plugin sandbox (bwrap) can create a user
# namespace on hosts that set kernel.apparmor_restrict_unprivileged_userns=1.
# install.sh rewrites this file on every run; put local rules in
# local/$APPARMOR_PROFILE.
abi <abi/4.0>,
include <tunables/global>

profile $APPARMOR_PROFILE flags=(unconfined) {
  userns,

  include if exists <local/$APPARMOR_PROFILE>
}
EOF
}

# install_apparmor_profile: writes the profile and loads it. Runs before
# .env changes and compose up, so a failure leaves the install as it was.
# The file is written under a temp name in the same root-only directory
# and renamed into place, so the profile path is never opened for writing.
install_apparmor_profile() {
    [[ "$AA_LOAD" == 1 ]] || return 0
    local dst="$APPARMOR_DIR/$APPARMOR_PROFILE" tmp out
    [[ -d "$APPARMOR_DIR" ]] || die "$APPARMOR_DIR does not exist; install AppArmor (sudo apt-get install -y apparmor) and re-run"
    tmp=$(mktemp "$APPARMOR_DIR/.$APPARMOR_PROFILE.XXXXXX")
    apparmor_profile_text >"$tmp"
    chmod 0644 -- "$tmp"
    if [[ -f "$dst" && ! -L "$dst" ]] && cmp -s "$tmp" "$dst"; then
        rm -f -- "$tmp"
    else
        mv -fT -- "$tmp" "$dst"
        say "  wrote $dst"
    fi
    if ! out=$(apparmor_parser -r "$dst" 2>&1); then
        die "apparmor_parser could not load $dst: ${out:-no output}. The profile needs AppArmor 4 (abi 4.0, as in Ubuntu 24.04). Check with: sudo aa-status; sudo journalctl -k | grep -i apparmor. Nothing else was changed."
    fi
    say "  loaded the AppArmor profile $APPARMOR_PROFILE (grants the plugin sandbox its user namespace)"
}

# check_compose_reads_apparmor: compose files before #1690 hard-code
# apparmor=unconfined, so the loaded profile would not be used.
check_compose_reads_apparmor() {
    [[ "$AA_VALUE" == "$APPARMOR_PROFILE" && "$AA_STATE" != none ]] || return 0
    grep -qF "\${$APPARMOR_KEY" "$INSTALL_DIR/$COMPOSE_NAME" 2>/dev/null && return 0
    say "  WARN: the $COMPOSE_NAME in $(image_ref) does not read $APPARMOR_KEY (images before #1690), so plugins will not start on this host; install a newer tag"
}

# setup_update_folder: <install dir>/update, owned by the container user,
# so Apply can write requests there. Runs before compose up: a missing bind
# source would be created root-owned by Docker and the app could not write.
setup_update_folder() {
    local dir="$INSTALL_DIR/$UPDATE_DIR_NAME"
    [[ ! -L "$dir" ]] || die "$dir is a symlink; remove it and re-run"
    mkdir -p "$dir"
    if [[ "$(id -u)" == 0 ]]; then
        chown "$CONTAINER_UID:$CONTAINER_UID" "$dir"
        chmod 0750 "$dir"
        say "  update folder $dir (uid $CONTAINER_UID, mode 0750)"
    else
        say "  created $dir; run as root to hand it to uid $CONTAINER_UID"
    fi
}

# write_marker: tells the Updates page the unit is installed. The folder
# belongs to the container, which can swap any name in it for a symlink, so
# root never opens, chmods or chowns a path inside it. The marker is written
# in a root-only dir on the same filesystem and renamed in; the rename
# replaces the directory entry without following it.
write_marker() {
    local stage
    stage=$(mktemp -d "$INSTALL_DIR/.marker.XXXXXX")
    printf 'installed by install.sh on %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$stage/marker"
    chmod 0644 "$stage/marker"
    mv -fT -- "$stage/marker" "$INSTALL_DIR/$UPDATE_DIR_NAME/$UPDATE_MARKER"
    rm -rf -- "$stage"
}

# release_of TAG: TAG without its v when it is a release tag (X.Y.Z), else
# nothing. A moving tag such as stable names no version.
release_of() {
    local v=${1#v}
    [[ ! "$v" =~ ^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]] || printf '%s' "$v"
}

# write_handler_version VERSION: puts the release the host update scripts
# came from in the update folder, where the Updates page reads it. The copy
# beside the scripts goes in with them (host_handler_plan). Nothing for an
# empty VERSION. The folder copy goes in as write_marker does.
write_handler_version() {
    local version=$1 stage
    [[ -n "$version" ]] || return 0
    stage=$(mktemp -d "$INSTALL_DIR/.marker.XXXXXX")
    printf '%s\n' "$version" >"$stage/host-handler"
    chmod 0644 "$stage/host-handler"
    mv -fT -- "$stage/host-handler" "$INSTALL_DIR/$UPDATE_DIR_NAME/host-handler"
    rm -rf -- "$stage"
}

# stage_host_handler STAGE: copies install.sh and the host update scripts
# and units out of the image into STAGE, with each unit rendered for this
# install's paths. Nothing copied is run. Sets MISSING to the names the
# image lacks.
MISSING=()
stage_host_handler() {
    local stage=$1 f
    MISSING=()
    image_cat "$IMAGE_DEPLOY_DIR/install.sh" >"$stage/install.sh" 2>/dev/null || true
    [[ -s "$stage/install.sh" ]] || MISSING+=(install.sh)
    for f in "${UPDATE_SCRIPTS[@]}"; do
        image_cat "$IMAGE_DEPLOY_DIR/$f" >"$stage/$f" 2>/dev/null || true
        [[ -s "$stage/$f" ]] || MISSING+=("$f")
    done
    for f in "${UPDATE_UNITS[@]}"; do
        image_cat "$IMAGE_DEPLOY_DIR/systemd/$f" >"$stage/$f.image" 2>/dev/null || true
        if [[ -s "$stage/$f.image" ]]; then
            sed -e "s|/usr/local/lib/dataloader|$UPDATE_LIB_DIR|g" -e "s|/opt/dataloader|$INSTALL_DIR|g" \
                "$stage/$f.image" >"$stage/$f"
        else
            MISSING+=("$f")
        fi
    done
}

# host_handler_plan STAGE VERSION WITH_INSTALLER: fills PLAN with SRC DST
# MODE triples for the staged host files: install.sh when WITH_INSTALLER is
# 1, the update scripts, the handler-version file when VERSION is set, and
# the units.
PLAN=()
host_handler_plan() {
    local stage=$1 version=$2 f
    PLAN=()
    [[ "$3" != 1 ]] || PLAN+=("$stage/install.sh" "$INSTALL_DIR/install.sh" 0644)
    for f in "${UPDATE_SCRIPTS[@]}"; do
        PLAN+=("$stage/$f" "$UPDATE_LIB_DIR/$f" 0755)
    done
    if [[ -n "$version" ]]; then
        printf '%s\n' "$version" >"$stage/$HANDLER_VERSION_NAME"
        PLAN+=("$stage/$HANDLER_VERSION_NAME" "$UPDATE_LIB_DIR/$HANDLER_VERSION_NAME" 0644)
    fi
    for f in "${UPDATE_UNITS[@]}"; do
        PLAN+=("$stage/$f" "$SYSTEMD_DIR/$f" 0644)
    done
}

# install_host_files STAGE: replaces every PLAN destination whose content
# differs, all of them or none, as the host update script does on Apply.
# The previous copies go to <install dir>/.host-backups/ (root, 0700,
# mounted nowhere) first. Each new copy is written to a temp file beside
# its destination; only when all are written are they renamed in, so a
# running script keeps its inode and no file is ever half written. A rename
# that fails puts the ones already renamed back. Sets CHANGED to the
# destinations replaced. Returns 1 with nothing changed on any failure.
CHANGED=()
install_host_files() {
    local stage=$1 i n tmp backup
    local -a srcs=() dsts=() modes=() tmps=()
    CHANGED=()
    for ((i = 0; i < ${#PLAN[@]}; i += 3)); do
        cmp -s -- "${PLAN[i]}" "${PLAN[i + 1]}" && continue
        srcs+=("${PLAN[i]}")
        dsts+=("${PLAN[i + 1]}")
        modes+=("${PLAN[i + 2]}")
    done
    n=${#srcs[@]}
    ((n > 0)) || return 0
    [[ ! -L "$INSTALL_DIR/$HOST_BACKUPS" ]] || { say "  $INSTALL_DIR/$HOST_BACKUPS is a symlink; remove it and re-run"; return 1; }
    mkdir -p -- "$UPDATE_LIB_DIR" "$SYSTEMD_DIR" "$stage/old" || return 1
    for ((i = 0; i < n; i++)); do
        [[ -f "${dsts[i]}" ]] || continue
        backup=$(root_backup "${dsts[i]}" "$HOST_BACKUPS" "${dsts[i]##*/}.$(date +%Y%m%d-%H%M%S).bak") || return 1
        cat -- "${dsts[i]}" >"$stage/old/$i" || return 1
        say "  kept the previous ${dsts[i]##*/} as $backup"
    done
    for ((i = 0; i < n; i++)); do
        tmp=""
        if ! {
            tmp=$(mktemp "$(dirname -- "${dsts[i]}")/.$(basename -- "${dsts[i]}").XXXXXX") &&
                cat -- "${srcs[i]}" >"$tmp" && chmod "${modes[i]}" -- "$tmp" &&
                { [[ "$(id -u)" != 0 ]] || chown 0:0 -- "$tmp"; }
        }; then
            [[ -z "$tmp" ]] || rm -f -- "$tmp"
            rm -f -- "${tmps[@]+"${tmps[@]}"}"
            return 1
        fi
        tmps+=("$tmp")
    done
    for ((i = 0; i < n; i++)); do
        if mv -fT -- "${tmps[i]}" "${dsts[i]}"; then
            CHANGED+=("${dsts[i]}")
            continue
        fi
        say "  could not replace ${dsts[i]}; putting back the ones already replaced"
        rm -f -- "${tmps[@]:i}"
        while ((i-- > 0)); do
            if [[ -e "$stage/old/$i" ]]; then
                if ! { cat -- "$stage/old/$i" >"${dsts[i]}.restore" && chmod "${modes[i]}" -- "${dsts[i]}.restore" &&
                    mv -fT -- "${dsts[i]}.restore" "${dsts[i]}"; }; then
                    say "  could not put ${dsts[i]} back; the previous copy is in $INSTALL_DIR/$HOST_BACKUPS"
                fi
            else
                rm -f -- "${dsts[i]}"
            fi
        done
        CHANGED=()
        return 1
    done
}

# install_update_units: copies the host update unit and the daily automatic
# update out of the image, points them at this install dir and enables them.
# Files that changed are replaced all or none, the previous copies kept in
# .host-backups/, so a re-run leaves one copy of each.
install_update_units() {
    [[ "$UNITS_OK" == 1 ]] || return 0
    local stage f
    stage=$(mktemp -d "$INSTALL_DIR/.units.XXXXXX")
    stage_host_handler "$stage"
    for f in "${MISSING[@]+"${MISSING[@]}"}"; do
        [[ "$f" != install.sh ]] || continue
        rm -rf -- "$stage"
        say "  WARN: $(image_ref) has no host update unit (images before #1626 lack it); one-click updates stay off"
        return 0
    done
    host_handler_plan "$stage" "$(release_of "$TAG")" 0
    if ! install_host_files "$stage"; then
        rm -rf -- "$stage"
        die "could not replace the host update scripts and units; they are as they were"
    fi
    rm -rf -- "$stage"
    write_marker
    write_handler_version "$(release_of "$TAG")"
    systemctl daemon-reload
    systemctl enable --now dataloader-update-request.path >/dev/null
    if [[ "$AUTO_UPDATE" == on ]]; then
        systemctl enable --now dataloader-auto-update.timer >/dev/null
    else
        systemctl disable --now dataloader-auto-update.timer >/dev/null 2>&1 || true
    fi
    say "  installed the host update unit; daily automatic update $AUTO_UPDATE"
}

# remove_update_units: --remove-update-units. Leaves the update folder, so
# the compose mount still resolves; the page reads it as not set up.
remove_update_units() {
    [[ "$(id -u)" == 0 ]] || die "--remove-update-units needs root (use sudo)"
    local f
    if command -v systemctl >/dev/null 2>&1; then
        systemctl disable --now dataloader-update-request.path dataloader-auto-update.timer >/dev/null 2>&1 || true
    fi
    for f in "${UPDATE_UNITS[@]}"; do rm -f -- "$SYSTEMD_DIR/$f"; done
    for f in "${UPDATE_SCRIPTS[@]}"; do rm -f -- "$UPDATE_LIB_DIR/$f"; done
    rm -f -- "$UPDATE_LIB_DIR/handler-version"
    rm -f -- "$INSTALL_DIR/$UPDATE_DIR_NAME/$UPDATE_MARKER" "$INSTALL_DIR/$UPDATE_DIR_NAME/host-handler"
    if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
    say "Removed the host update unit and the daily automatic update."
    say "Apply on the Updates page is off until you re-run install.sh."
}

# refresh_host_handler: --refresh-host-handler. A host set up before the
# update script refreshed itself keeps its first copy for good: Apply runs
# that copy, and it never replaces the host files. This puts the image's
# install.sh and host update scripts and units in place, all or none, with
# the previous copies in .host-backups/, as Apply does now. The image is the
# one .env names, already on the host. It changes nothing else: no .env, no
# compose file, no seccomp or AppArmor profile, no volume, no license, and
# it runs no compose command, so the running container stays as it is. The
# next Apply refreshes the compose file with its own checks and roll back.
refresh_host_handler() {
    local ref stage version body i f
    say "DataLoader installer: refresh the host update handler in $INSTALL_DIR"
    [[ "$(id -u)" == 0 ]] || die "--refresh-host-handler needs root (use sudo)"
    units_supported || die "--refresh-host-handler needs a host that runs systemd; Apply is not set up here"
    [[ "$INSTALL_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
        die "the install dir $INSTALL_DIR has characters a systemd unit path cannot hold"
    [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] ||
        die "there is no .env in $INSTALL_DIR, so this is not a DataLoader install folder; pass --install-dir"
    [[ -d "$INSTALL_DIR/$UPDATE_DIR_NAME" && ! -L "$INSTALL_DIR/$UPDATE_DIR_NAME" ]] ||
        die "there is no update folder in $INSTALL_DIR; run install.sh --repair to set up Apply"
    load_existing_env
    # The image this install runs, so the scripts match the running version.
    [[ -z "$TAG" || "$TAG" == "${EXISTING_TAG:-stable}" ]] ||
        die "--refresh-host-handler uses the tag in $ENV_FILE (${EXISTING_TAG:-stable}); leave out --tag"
    TAG=${EXISTING_TAG:-stable}
    PORT=${PORT:-8080}
    [[ -n "$EXISTING_IMAGE" ]] || valid_image_repo "$IMAGE_REPO" ||
        die "invalid DATALOADER_IMAGE_REPO in $ENV_FILE: $IMAGE_REPO"
    ref=$(image_ref)
    docker image inspect "$ref" >/dev/null 2>&1 ||
        die "the image $ref is not on this host. Nothing was changed. Run docker compose pull in $INSTALL_DIR first, or check DATALOADER_TAG in $ENV_FILE."

    version=$(release_of "$TAG")
    if [[ -z "$version" ]] && body=$(health_json); then
        version=$(release_of "$(printf '%s' "$body" | sed -nE 's/.*"version":"([^"]*)".*/\1/p')")
    fi

    stage=$(mktemp -d "$INSTALL_DIR/.units.XXXXXX")
    # shellcheck disable=SC2064 # expand now: stage is local
    trap "rm -rf -- '$stage'" EXIT
    stage_host_handler "$stage"
    ((${#MISSING[@]} == 0)) ||
        die "$ref carries no ${MISSING[*]}. Nothing was changed."
    for f in install.sh "${UPDATE_SCRIPTS[@]}"; do
        bash -n -- "$stage/$f" 2>/dev/null || die "$f from $ref does not parse. Nothing was changed."
    done
    host_handler_plan "$stage" "$version" 1

    step "Plan"
    say "  Image:            $ref"
    say "  Handler version:  ${version:-not recorded ($TAG is not a release tag)}"
    say ""
    for ((i = 0; i < ${#PLAN[@]}; i += 3)); do
        if cmp -s -- "${PLAN[i]}" "${PLAN[i + 1]}"; then
            say "    unchanged  ${PLAN[i + 1]}"
        elif [[ -e "${PLAN[i + 1]}" ]]; then
            say "    replace    ${PLAN[i + 1]}"
        else
            say "    add        ${PLAN[i + 1]}"
        fi
    done
    say ""
    say "  Every file above is replaced or none is. The previous copies go to $INSTALL_DIR/$HOST_BACKUPS/."
    say "  Not touched: $ENV_FILE, $COMPOSE_NAME, the seccomp and AppArmor profiles, the state volume,"
    say "  the license and the running container. The next Apply refreshes the compose file."
    if [[ "$DRY_RUN" == 1 ]]; then
        say ""
        say "Dry run: nothing was changed."
        exit 0
    fi
    confirm

    step "Applying"
    install_host_files "$stage" || die "could not replace the host update files; they are as they were"
    write_marker
    write_handler_version "$version"
    systemctl daemon-reload
    systemctl enable --now dataloader-update-request.path >/dev/null
    say ""
    if ((${#CHANGED[@]} == 0)); then
        say "The host update handler was already current${version:+ ($version)}. Nothing was changed."
    else
        say "Refreshed ${#CHANGED[@]} host update files${version:+ to $version}. The next Apply runs on them."
    fi
}

# health_json: prints the health body, or fails.
health_json() {
    curl -fsS -m 5 "http://$(probe_host):$PORT$HEALTH_PATH" 2>/dev/null
}

wait_for_health() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT)) body="" status last="no answer" remaining
    local url
    url="http://$(probe_host):$PORT$HEALTH_PATH"
    say "  waiting for $url (first boot sets up the embedded Postgres, allow a few minutes)"
    # Always probe once before sleeping. Setup overhead can consume a short
    # timeout before this function reaches its first health check.
    while :; do
        if body=$(health_json); then
            if [[ "$body" == *'"status":"healthy"'* && ( -z "$EXPECTED_VERSION" || "$body" == *"\"version\":\"$EXPECTED_VERSION\""* ) ]]; then
                HEALTH_BODY=$body
                say "  healthy after $((HEALTH_TIMEOUT - (deadline - SECONDS)))s"
                return 0
            fi
            if [[ -n "$EXPECTED_VERSION" && "$body" == *'"status":"healthy"'* ]]; then
                last="version mismatch (expected $EXPECTED_VERSION)"
            else
                last=$(printf '%s' "$body" | sed -nE 's/.*"status":"([^"]*)".*/\1/p')
                last="status ${last:-unknown}"
            fi
        else
            last="no answer"
        fi
        status=$(compose ps --format '{{.Status}}' 2>/dev/null | head -n 1 || true)
        printf '  ... %3ss  container: %s\n' "$((HEALTH_TIMEOUT - (deadline - SECONDS)))" "${status:-not started}"
        if [[ "$status" == *Restarting* ]]; then
            say "  the container is restarting; last log lines:"
            compose logs --no-color --tail 30 dataloader 2>&1 | sed 's/^/    /' || true
        fi
        ((SECONDS < deadline)) || break
        remaining=$((deadline - SECONDS))
        if ((remaining > 10)); then remaining=10; fi
        sleep "$remaining"
    done
    say ""
    say "  timed out after ${HEALTH_TIMEOUT}s: DataLoader did not report healthy at $url (last check: $last)."
    say "  Last 40 log lines:"
    compose logs --no-color --tail 40 dataloader 2>&1 | sed 's/^/    /' || true
    say ""
    say "  $ENV_FILE and $COMPOSE_NAME are in place and the container was left running."
    say "  fix: read the full log with: cd $INSTALL_DIR && docker compose -f $COMPOSE_NAME$([[ ! -f "$INSTALL_DIR/$COMPOSE_OVERRIDE_NAME" ]] || printf ' -f %s' "$COMPOSE_OVERRIDE_NAME") logs dataloader"
    say "       then re-run this installer (it keeps .env), or wait longer with --health-timeout SECONDS"
    return 1
}

HEALTH_BODY=""
apply() {
    step "Applying"
    mkdir -p "$INSTALL_DIR/license" "$INSTALL_DIR/backups"
    # Pull before touching .env, so a failed pull leaves an upgrade
    # un-started and the running install on its old tag.
    if [[ "$MODE" != verify ]] || ! docker image inspect "$(image_ref)" >/dev/null 2>&1; then
        say "  pulling $(image_ref)"
        docker pull "$(image_ref)" >/dev/null
    fi
    check_compose_reads_repo
    install_apparmor_profile
    apply_env
    install_compose_file
    check_compose_reads_apparmor
    setup_update_folder
    install_update_units
    say "  starting: docker compose up -d"
    compose up -d
    wait_for_health || exit 1
}

print_summary() {
    local version
    version=$(printf '%s' "$HEALTH_BODY" | sed -nE 's/.*"version":"([^"]*)".*/\1/p')
    local vol
    vol=$(docker volume ls -q --filter "label=com.docker.compose.project=$(compose_project)" \
        --filter "label=com.docker.compose.volume=dataloader-data" 2>/dev/null | head -n 1 || true)
    [[ -n "$vol" ]] || vol=$(volume_name)
    step "DataLoader is running"
    say "  URL:           http://$(probe_host):$PORT/"
    say "  Version:       ${version:-unknown}"
    say "  Install dir:   $INSTALL_DIR"
    say "  State volume:  $vol (holds jwt.key, master.key and the embedded Postgres)"
    say "  Back it up:    docker run --rm -v $vol:/data:ro -v $INSTALL_DIR/backups:/backup alpine tar czf /backup/dataloader-data-\$(date +%F).tgz -C /data ."
    say "                 (see section 14, Upgrade and rollback, of the client acceptance test plan)"
    if [[ "$UNITS_OK" == 1 ]]; then
        say "  Updates:       one click from Settings, Updates; daily automatic update $AUTO_UPDATE"
    else
        say "  Updates:       by hand (docker compose pull, then up -d); re-run with sudo for one click"
    fi
    if [[ "$BIND" == 127.0.0.1 ]]; then
        say "  Note:          bound to localhost. Put a reverse proxy with TLS in front for other machines."
    fi
    say ""
    say "Next steps:"
    local n=1
    if [[ "$MODE" == install && -n "$ADMIN_EMAIL" ]]; then
        say "  $n. Sign in as $ADMIN_EMAIL. The password is in $ENV_FILE:"
        say "       sudo sed -n \"s/^DL_BOOTSTRAP_ADMIN_PASSWORD='\(.*\)'\$/\1/p\" $ENV_FILE"
        say "     That prints the bare password. The single quotes in .env are not part of it."
        say "     After the first sign-in, delete both DL_BOOTSTRAP_ADMIN_* lines from .env."
        n=$((n + 1))
    fi
    say "  $n. Finish the setup wizard in the browser (workspace, license, optional SSO)."
    n=$((n + 1))
    say "  $n. Run the client acceptance test plan: docs/runbooks/client-acceptance-test-plan.md"
    n=$((n + 1))
    say "  $n. Re-run this installer any time to verify; pass a new --tag to upgrade."
}

# --- Main ----------------------------------------------------------------------------------

main() {
    parse_args "$@"
    if [[ "$REMOVE_UPDATE_UNITS" == 1 ]]; then
        remove_update_units
        exit 0
    fi
    if [[ "$REFRESH_HOST_HANDLER" == 1 ]]; then
        refresh_host_handler
        exit 0
    fi
    load_existing_env
    resolve_settings
    decide_mode
    say "DataLoader installer: $MODE, $(image_ref) into $INSTALL_DIR"
    run_preflight
    if ((FAILS > 0)); then
        say ""
        say "Preflight failed. Nothing was changed. Fix the FAIL lines above and re-run."
        exit 1
    fi
    plan_env_changes
    print_plan
    if [[ "$DRY_RUN" == 1 ]]; then
        say ""
        say "Dry run: nothing was changed."
        exit 0
    fi
    confirm
    apply
    print_summary
}

# Sourcing the file (the tests do) loads the functions without running.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
