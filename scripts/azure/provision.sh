#!/usr/bin/env bash
# DataLoader v2: provision a client's Azure resources with the az CLI (#1433).
#
# `up` creates, in one resource group:
#   - the resource group, when it does not exist yet
#   - a user-assigned managed identity for DataLoader
#   - two Key Vaults with Azure RBAC authorization, one that TEST runs read
#     and one that PROD runs read (or one, with --single-vault), and Key
#     Vault Secrets User for the identity on each
#   - a container registry (Basic), with the dataloader and
#     dataloader-worker images imported from acrdakotadataloader, and
#     AcrPull for the identity
#   - an Azure Container Apps environment and the `shared` fan-out job
#   - the roles the ACA Jobs backend needs (Reader and Container Apps Jobs
#     Contributor on the group, Managed Identity Operator on the identity)
# and writes the values the setup needs to a JSON file.
#
# Every step checks before it creates, so a re-run creates nothing new.
#
# The first `up` picks a run id and writes it to the group's
# dataloader-run-id tag (a group that already exists gets the tag merged
# in). When `up` creates the group, it also tags it
# dataloader-rg-created-by=<run id>. Every resource `up` creates carries
# dataloader-provisioned=provision.sh:<subscription>/<group>/<run id>, and
# every role assignment it makes has that same pair as its description.
#
# `down` reads the run id from the group and then:
#   - deletes the role assignments whose description is that exact pair,
#     listed on the group and on each vault, registry and identity in it
#   - deletes the resources in the group whose tag is that exact value
#   - deletes the group only when its dataloader-rg-created-by tag equals
#     the run id and nothing else is left in it
# A group with no run id tag is never touched. A resource or role with any
# other tag value or description, the old fixed provision.sh value
# included, is kept.
#
# Key Vault access is Azure RBAC only. The script refuses to run
# `az keyvault set-policy` or to turn RBAC off, and stops on an existing
# vault that uses access policies. It creates no service principal and no
# secret.
#
# --dry-run prints every az command. It runs the reads (show, list), so the
# plan reflects what exists, and prints the changes without running them.
#
# See docs/runbooks/client-azure-identity-vault-sso-databricks.md, step 0.

set -euo pipefail

TAG_KEY=dataloader-provisioned
RUN_TAG=dataloader-run-id
CREATED_TAG=dataloader-rg-created-by
# Set by set_tag_value once the run id is known.
TAG_VALUE=""
RUN_ID=""
RG_CREATED_BY=""
SOURCE_REGISTRY_DEFAULT=acrdakotadataloader.azurecr.io
IMAGES=(dataloader dataloader-worker)
# DataLoader 1.0 dispatches fan-out to a job with this fixed name (#1452).
JOB_NAME=shared
FORBIDDEN_RG=dakota_group1

ROLE_SECRETS_USER="Key Vault Secrets User"
ROLE_SECRETS_OFFICER="Key Vault Secrets Officer"
ROLE_ACR_PULL=AcrPull
ROLE_READER=Reader
ROLE_ACA_JOBS="Container Apps Jobs Contributor"
ROLE_MI_OPERATOR="Managed Identity Operator"

GUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

usage() {
    cat <<'EOF'
Usage: provision.sh [up|down] --subscription ID --resource-group NAME [options]

Commands:
  up      Create what is missing (the default). Safe to re-run.
  down    Remove what `up` created, found by its tag. Needs --yes.

Required:
  --subscription ID       Subscription ID (a GUID)
  --resource-group NAME   Resource group. dakota_group1 is refused.
  --location REGION       Azure region, for example eastus2 (up only)
  --tag TAG               DataLoader release tag to import, for example 1.0.0 (up only)

Options for up:
  --prefix P              Name prefix, 3 to 12 of a-z 0-9 and -, default dataloader
  --vault-name NAME       TEST Key Vault name (default: <prefix>-kv-<hash>)
  --prod-vault-name NAME  PROD Key Vault name (default: <prefix>-kvp-<hash>)
  --single-vault          One vault for both environments instead of two
  --prod-vault-write      Also grant Key Vault Secrets Officer on the PROD vault,
                          so promotion can copy a missing secret into it
  --registry-name NAME    Container registry name (default: <prefix>acr<hash>)
  --source-registry HOST  Registry to import from (default: acrdakotadataloader.azurecr.io)
  --arm-principal ID      Object ID of the principal DataLoader signs in to Azure
                          Resource Manager with, when that is not the identity.
                          Gets the same fan-out roles as the identity.
  --arm-principal-type T  ServicePrincipal (default), User or Group
  --vm NAME|ID            Attach the identity to this VM (a name in the resource
                          group, or a full resource ID)
  --log-analytics         Send the ACA environment's logs to a new Log Analytics
                          workspace (billed per GB ingested). Default: no logs.
  --job-timeout SECONDS   Longest a fan-out partition may run, default 14400
  --output FILE           Where to write the outputs, default ./dataloader-azure.json

Options for down:
  --vm NAME|ID            Detach the identity from this VM first
  --purge-vault           Purge the vault after deleting it. Its secrets are gone
                          for good. Without it the vault stays soft-deleted for
                          its retention period and its name stays taken.

Both:
  --dry-run               Print every az command; run only the reads
  --yes                   Do not ask before down deletes anything
  -h, --help              This help
EOF
}

say() { printf '%s\n' "$*"; }
die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}
refuse() {
    printf 'refused: %s\n' "$*" >&2
    exit 3
}
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
is_tty() { [[ -t 0 && -t 1 ]]; }

CMD=up
SUB=""
RG=""
LOCATION=""
IMAGE_TAG=""
PREFIX=dataloader
VAULT_NAME=""
PROD_VAULT_NAME=""
SINGLE_VAULT=0
PROD_VAULT_WRITE=0
ACR_NAME=""
SOURCE_REGISTRY=$SOURCE_REGISTRY_DEFAULT
ARM_PRINCIPAL=""
ARM_PRINCIPAL_TYPE=ServicePrincipal
VM=""
LOG_ANALYTICS=0
JOB_TIMEOUT=14400
OUTPUT=./dataloader-azure.json
PURGE_VAULT=0
DRY_RUN=0
ASSUME_YES=0

parse_args() {
    if [[ $# -gt 0 && ( "$1" == up || "$1" == down ) ]]; then
        CMD=$1
        shift
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --subscription) SUB=${2:-}; shift 2 ;;
            --resource-group) RG=${2:-}; shift 2 ;;
            --location) LOCATION=${2:-}; shift 2 ;;
            --tag) IMAGE_TAG=${2:-}; shift 2 ;;
            --prefix) PREFIX=${2:-}; shift 2 ;;
            --vault-name) VAULT_NAME=${2:-}; shift 2 ;;
            --prod-vault-name) PROD_VAULT_NAME=${2:-}; shift 2 ;;
            --single-vault) SINGLE_VAULT=1; shift ;;
            --prod-vault-write) PROD_VAULT_WRITE=1; shift ;;
            --registry-name) ACR_NAME=${2:-}; shift 2 ;;
            --source-registry) SOURCE_REGISTRY=${2:-}; shift 2 ;;
            --arm-principal) ARM_PRINCIPAL=${2:-}; shift 2 ;;
            --arm-principal-type) ARM_PRINCIPAL_TYPE=${2:-}; shift 2 ;;
            --vm) VM=${2:-}; shift 2 ;;
            --log-analytics) LOG_ANALYTICS=1; shift ;;
            --job-timeout) JOB_TIMEOUT=${2:-}; shift 2 ;;
            --output) OUTPUT=${2:-}; shift 2 ;;
            --purge-vault) PURGE_VAULT=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            --yes | -y) ASSUME_YES=1; shift ;;
            -h | --help) usage; exit 0 ;;
            *) die "unknown argument: $1 (see --help)" ;;
        esac
    done
}

validate_args() {
    [[ -n "$SUB" ]] || die "--subscription is required"
    [[ -n "$RG" ]] || die "--resource-group is required"
    [[ "$SUB" =~ $GUID_RE ]] || die "--subscription must be a subscription ID (a GUID), got: $SUB"
    [[ "$RG" =~ ^[A-Za-z0-9._()-]{1,90}$ && "$RG" != *. ]] || die "invalid --resource-group: $RG"
    if [[ "$(lower "$RG")" == "$FORBIDDEN_RG" ]]; then
        refuse "resource group $RG is off limits. Use a resource group of its own for DataLoader."
    fi
    [[ -z "$VM" || "$VM" =~ ^[A-Za-z0-9._/()-]+$ ]] || die "invalid --vm: $VM"
    [[ "$CMD" == up ]] || return 0

    [[ -n "$LOCATION" ]] || die "--location is required for up"
    [[ -n "$IMAGE_TAG" ]] || die "--tag is required for up (the DataLoader release to import)"
    [[ "$LOCATION" =~ ^[a-z0-9]+$ ]] || die "invalid --location: $LOCATION (for example eastus2)"
    [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || die "invalid --tag: $IMAGE_TAG"
    [[ "$PREFIX" =~ ^[a-z][a-z0-9-]{1,10}[a-z0-9]$ && "$PREFIX" != *--* ]] ||
        die "invalid --prefix: $PREFIX (3 to 12 of a-z, 0-9 and -, starting with a letter)"
    [[ "$SOURCE_REGISTRY" =~ ^[a-z0-9.-]+(:[0-9]+)?$ ]] || die "invalid --source-registry: $SOURCE_REGISTRY"
    [[ -z "$ARM_PRINCIPAL" || "$ARM_PRINCIPAL" =~ $GUID_RE ]] ||
        die "--arm-principal must be an object ID (a GUID), got: $ARM_PRINCIPAL"
    [[ "$ARM_PRINCIPAL_TYPE" =~ ^(ServicePrincipal|User|Group)$ ]] ||
        die "--arm-principal-type must be ServicePrincipal, User or Group"
    [[ "$JOB_TIMEOUT" =~ ^[0-9]+$ && "$JOB_TIMEOUT" -ge 60 ]] || die "--job-timeout must be a number of seconds, 60 or more"
    [[ -n "$OUTPUT" ]] || die "--output needs a file name"

    # Vault and registry names are global across Azure. The default adds a
    # hash of the subscription and group, so two clients' names differ and a
    # re-run finds the same names again.
    local hash
    hash=$(printf '%s/%s' "$(lower "$SUB")" "$(lower "$RG")" | cksum | cut -d' ' -f1)
    hash=$(printf '%08x' "$hash" | cut -c1-6)
    [[ -n "$VAULT_NAME" ]] || VAULT_NAME="$PREFIX-kv-$hash"
    [[ -n "$PROD_VAULT_NAME" ]] || PROD_VAULT_NAME="$PREFIX-kvp-$hash"
    [[ -n "$ACR_NAME" ]] || ACR_NAME="${PREFIX//-/}acr$hash"
    local v
    for v in "$VAULT_NAME" "$PROD_VAULT_NAME"; do
        [[ "$v" =~ ^[A-Za-z][A-Za-z0-9-]{1,22}[A-Za-z0-9]$ && "$v" != *--* ]] ||
            die "invalid vault name: $v (3 to 24 of letters, digits and -)"
    done
    if [[ "$SINGLE_VAULT" == 1 ]]; then
        [[ "$PROD_VAULT_WRITE" == 0 ]] ||
            die "--prod-vault-write needs a PROD vault of its own; with --single-vault it would let DataLoader write TEST secrets too"
    elif [[ "$(lower "$VAULT_NAME")" == "$(lower "$PROD_VAULT_NAME")" ]]; then
        die "the TEST and PROD vaults need different names (or pass --single-vault)"
    fi
    [[ "$ACR_NAME" =~ ^[A-Za-z0-9]{5,50}$ ]] || die "invalid --registry-name: $ACR_NAME (5 to 50 letters and digits)"
}

# --- az wrappers -------------------------------------------------------------

AZ_OUT=""
ERR_FILE=""

# print_cmd LABEL ARGS...: prints a command so it can be pasted, with the
# Log Analytics key blanked out. <placeholders> (values a dry run cannot
# know yet) print as they are.
print_cmd() {
    local label=$1 prev="" a out=""
    shift
    for a in "$@"; do
        [[ "$prev" != --logs-workspace-key ]] || a='<key>'
        if [[ "$a" =~ ^[A-Za-z0-9_./:=@,+\<\>-]+$ ]]; then
            out+="$a "
        else
            out+="$(printf '%q' "$a") "
        fi
        prev=$a
    done
    printf '    %-10s %s\n' "$label" "${out% }"
}

# full_cmd ARGS...: fills AZ_CMD with the az command plus the subscription
# and --only-show-errors, so every call names its subscription and never
# depends on `az account set`.
AZ_CMD=()
full_cmd() {
    AZ_CMD=(az "$@")
    [[ "$1" == extension ]] || AZ_CMD+=(--subscription "$SUB")
    AZ_CMD+=(--only-show-errors)
}

# guard_access_policy ARGS...: stops before any command that would create
# a Key Vault access policy or a vault without RBAC authorization.
guard_access_policy() {
    local prev="" a rbac=""
    if [[ "${1:-}" == keyvault && "${2:-}" == set-policy ]]; then
        refuse "az keyvault set-policy creates an access policy. DataLoader's Key Vaults use Azure RBAC authorization only: grant a role instead (az role assignment create --role \"$ROLE_SECRETS_USER\")."
    fi
    for a in "$@"; do
        if [[ "$prev" == --enable-rbac-authorization ]]; then rbac=$a; fi
        case "$a" in --enable-rbac-authorization=*) rbac=${a#*=} ;; esac
        prev=$a
    done
    if [[ -n "$rbac" && "$(lower "$rbac")" != true ]]; then
        refuse "turning Key Vault RBAC authorization off would bring back access policies. DataLoader's Key Vaults use Azure RBAC authorization only."
    fi
    if [[ "${1:-}" == keyvault && "${2:-}" == create && "$(lower "$rbac")" != true ]]; then
        refuse "a Key Vault must be created with --enable-rbac-authorization true."
    fi
}

# az_read ARGS...: runs a read. Returns 0 with the output in AZ_OUT, or 1
# when Azure says the thing does not exist. Any other failure stops.
az_read() {
    full_cmd "$@"
    [[ "$DRY_RUN" == 0 ]] || print_cmd check: "${AZ_CMD[@]}"
    local rc=0
    AZ_OUT=$("${AZ_CMD[@]}" 2>"$ERR_FILE") || rc=$?
    [[ "$rc" != 0 ]] || return 0
    # az exits 3 when a `show` finds nothing; some commands exit 1 and say so.
    if [[ "$rc" == 3 ]] || grep -qiE 'not ?found|could not be found|does not exist|is not installed' "$ERR_FILE"; then
        AZ_OUT=""
        return 1
    fi
    printf 'error: this command failed (exit %s):\n' "$rc" >&2
    print_cmd "" "${AZ_CMD[@]}" >&2
    cat "$ERR_FILE" >&2
    if grep -qiE 'az login|not logged in|AADSTS|expired' "$ERR_FILE"; then
        printf 'fix: sign in with "az login" to the tenant that holds subscription %s\n' "$SUB" >&2
    fi
    exit 1
}

# az_write ARGS...: runs a change, or only prints it in a dry run.
az_write() {
    guard_access_policy "$@"
    full_cmd "$@"
    AZ_OUT=""
    if [[ "$DRY_RUN" == 1 ]]; then
        print_cmd "would run:" "${AZ_CMD[@]}"
        return 0
    fi
    print_cmd run: "${AZ_CMD[@]}"
    local rc=0
    AZ_OUT=$("${AZ_CMD[@]}" 2>"$ERR_FILE") || rc=$?
    [[ "$rc" != 0 ]] || return 0
    printf 'error: this command failed (exit %s):\n' "$rc" >&2
    cat "$ERR_FILE" >&2
    printf 'Everything before it is in place. Fix the cause and run the same command again: it picks up where it stopped.\n' >&2
    exit 1
}

# item KIND NAME STATE: one line of the plan.
item() { printf '  %-18s %-30s %s\n' "$1" "$2" "$3"; }

# created_note TAG: the state word for a resource that exists.
created_note() {
    if [[ "$1" == "$TAG_VALUE" ]]; then
        printf 'exists'
    else
        printf 'exists, not created by this script (down keeps it)'
    fi
}

# --- up ----------------------------------------------------------------------

TENANT=""
RG_ID=""
RG_NEW=0
MI_NAME=""
MI_CLIENT=""
MI_PRINCIPAL=""
MI_ID=""
VAULT_ID=""
VAULT_URI=""
PROD_VAULT_ID=""
PROD_VAULT_URI=""
ACR_ID=""
ACR_LOGIN=""
ACR_NEW=0
ENV_NAME=""
ENV_ID=""
ENV_HAS_CONSUMPTION=0
LOGS_NAME=""
LOGS_CUSTOMER_ID=""
LOGS_NEW=0
# Scopes that do not exist yet in a dry run: role checks on them are skipped.
PLANNED=" "
EXT_PLANNED=0

planned() { [[ "$PLANNED" == *" $1 "* || "$1" == \<* ]]; }

check_account() {
    az_read account show --query tenantId -o tsv ||
        die "subscription $SUB was not found. Check the ID, and that \`az login\` used the right tenant."
    TENANT=$AZ_OUT
    RG_ID="/subscriptions/$SUB/resourceGroups/$RG"
}

ensure_extension() {
    if az_read extension show --name containerapp --query version -o tsv; then
        item extension containerapp "installed ($AZ_OUT)"
    else
        item extension containerapp "missing, installing"
        az_write extension add --name containerapp
        [[ "$DRY_RUN" == 0 ]] || EXT_PLANNED=1
    fi
}

ensure_providers() {
    local ns list=(Microsoft.ManagedIdentity Microsoft.KeyVault Microsoft.ContainerRegistry Microsoft.App)
    [[ "$LOG_ANALYTICS" == 0 ]] || list+=(Microsoft.OperationalInsights)
    for ns in "${list[@]}"; do
        az_read provider show --namespace "$ns" --query registrationState -o tsv || AZ_OUT=""
        if [[ "$AZ_OUT" == Registered ]]; then
            item provider "$ns" registered
        else
            item provider "$ns" "not registered, registering"
            az_write provider register --namespace "$ns" --wait
        fi
    done
}

# read_rg_tags: sets RUN_ID and RG_CREATED_BY from the group's tags. Two
# reads, so a missing tag cannot shift the other into its place.
read_rg_tags() {
    az_read group show --name "$RG" --query "tags.\"$RUN_TAG\"" -o tsv || AZ_OUT=""
    RUN_ID=$AZ_OUT
    az_read group show --name "$RG" --query "tags.\"$CREATED_TAG\"" -o tsv || AZ_OUT=""
    RG_CREATED_BY=$AZ_OUT
    # The run id goes into JMESPath queries, so it must be plain.
    [[ -z "$RUN_ID" || "$RUN_ID" =~ ^[A-Za-z0-9-]{1,64}$ ]] ||
        refuse "resource group $RG has an unexpected $RUN_TAG tag: $RUN_ID"
}

new_run_id() {
    RUN_ID="$(date -u +%Y%m%d%H%M%S)-$(printf '%04x%04x' "$RANDOM" "$RANDOM")"
}

# set_tag_value: the tag value and role description that name this
# deployment. Lower case, so a group name typed in another case still matches.
set_tag_value() {
    TAG_VALUE="provision.sh:$(lower "$SUB")/$(lower "$RG")/$RUN_ID"
}

ensure_rg() {
    az_read group exists --name "$RG" || AZ_OUT=false
    if [[ "$(lower "$AZ_OUT")" == true ]]; then
        read_rg_tags
        if [[ -z "$RUN_ID" ]]; then
            new_run_id
            set_tag_value
            item "resource group" "$RG" "exists, not created by this script (down keeps it)"
            item "run id" "$RUN_ID" "new, tag the group"
            az_write tag update --resource-id "$RG_ID" --operation Merge --tags "$RUN_TAG=$RUN_ID" -o none
            return
        fi
        set_tag_value
        if [[ "$RG_CREATED_BY" == "$RUN_ID" ]]; then
            item "resource group" "$RG" exists
        else
            item "resource group" "$RG" "exists, not created by this script (down keeps it)"
        fi
        item "run id" "$RUN_ID" "from the group"
    else
        new_run_id
        set_tag_value
        item "resource group" "$RG" create
        item "run id" "$RUN_ID" new
        az_write group create --name "$RG" --location "$LOCATION" \
            --tags "$RUN_TAG=$RUN_ID" "$CREATED_TAG=$RUN_ID" -o none
        RG_NEW=1
        [[ "$DRY_RUN" == 0 ]] || PLANNED+="$RG_ID "
    fi
}

# rg_planned: true in a dry run whose group does not exist yet, when every
# read inside it would only say "not found".
rg_planned() { [[ "$DRY_RUN" == 1 && "$RG_NEW" == 1 ]]; }

ensure_identity() {
    MI_NAME="$PREFIX-identity"
    MI_ID="$RG_ID/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$MI_NAME"
    local tag=""
    if ! rg_planned && az_read identity show --name "$MI_NAME" --resource-group "$RG" \
        --query "[clientId,principalId,id,tags.\"$TAG_KEY\"]" -o tsv; then
        read -r MI_CLIENT MI_PRINCIPAL MI_ID tag <<<"$(tr '\n' ' ' <<<"$AZ_OUT")"
        item identity "$MI_NAME" "$(created_note "$tag")"
        return
    fi
    item identity "$MI_NAME" create
    az_write identity create --name "$MI_NAME" --resource-group "$RG" --location "$LOCATION" \
        --tags "$TAG_KEY=$TAG_VALUE" --query "[clientId,principalId,id]" -o tsv
    if [[ "$DRY_RUN" == 1 ]]; then
        MI_CLIENT="<identity-client-id>"
        MI_PRINCIPAL="<identity-principal-id>"
        PLANNED+="$MI_ID "
    else
        read -r MI_CLIENT MI_PRINCIPAL MI_ID <<<"$(tr '\n' ' ' <<<"$AZ_OUT")"
    fi
}

# ensure_vault LABEL NAME FLAG: sets V_ID and V_URI. FLAG is the option
# that names this vault, for the messages.
V_ID=""
V_URI=""
ensure_vault() {
    local label=$1 name=$2 flag=$3 v_rg="" v_rbac="" tag=""
    V_ID="$RG_ID/providers/Microsoft.KeyVault/vaults/$name"
    V_URI="https://$name.vault.azure.net/"
    if az_read keyvault show --name "$name" \
        --query "[id,properties.vaultUri,resourceGroup,properties.enableRbacAuthorization,tags.\"$TAG_KEY\"]" -o tsv; then
        read -r V_ID V_URI v_rg v_rbac tag <<<"$(tr '\n' ' ' <<<"$AZ_OUT")"
        if [[ "$(lower "$v_rg")" != "$(lower "$RG")" ]]; then
            refuse "Key Vault $name already exists in resource group $v_rg. Pass $flag with another name."
        fi
        if [[ "$(lower "$v_rbac")" != true ]]; then
            refuse "Key Vault $name uses access policies. This script only uses Azure RBAC authorization and never creates an access policy. Switch the vault to RBAC (grant the roles first, then az keyvault update --name $name --enable-rbac-authorization true), or pass $flag for a new vault."
        fi
        item "$label" "$name" "$(created_note "$tag") (RBAC authorization)"
        return
    fi
    if az_read keyvault show-deleted --name "$name" --query id -o tsv; then
        refuse "Key Vault $name is soft-deleted, so its name is taken. Recover it with \`az keyvault recover --name $name\`, purge it with \`az keyvault purge --name $name\` (its secrets are gone for good), or pass $flag."
    fi
    item "$label" "$name" "create (RBAC authorization)"
    az_write keyvault create --name "$name" --resource-group "$RG" --location "$LOCATION" \
        --enable-rbac-authorization true --tags "$TAG_KEY=$TAG_VALUE" \
        --query "[id,properties.vaultUri]" -o tsv
    if [[ "$DRY_RUN" == 1 ]]; then
        PLANNED+="$V_ID "
    else
        read -r V_ID V_URI <<<"$(tr '\n' ' ' <<<"$AZ_OUT")"
    fi
}

ensure_vaults() {
    if [[ "$SINGLE_VAULT" == 1 ]]; then
        ensure_vault "key vault" "$VAULT_NAME" --vault-name
        VAULT_ID=$V_ID
        VAULT_URI=$V_URI
        return
    fi
    ensure_vault "key vault (test)" "$VAULT_NAME" --vault-name
    VAULT_ID=$V_ID
    VAULT_URI=$V_URI
    ensure_vault "key vault (prod)" "$PROD_VAULT_NAME" --prod-vault-name
    PROD_VAULT_ID=$V_ID
    PROD_VAULT_URI=$V_URI
}

ensure_registry() {
    ACR_ID="$RG_ID/providers/Microsoft.ContainerRegistry/registries/$ACR_NAME"
    ACR_LOGIN="$(lower "$ACR_NAME").azurecr.io"
    local a_rg="" tag=""
    if az_read acr show --name "$ACR_NAME" --query "[id,loginServer,resourceGroup,tags.\"$TAG_KEY\"]" -o tsv; then
        read -r ACR_ID ACR_LOGIN a_rg tag <<<"$(tr '\n' ' ' <<<"$AZ_OUT")"
        if [[ "$(lower "$a_rg")" != "$(lower "$RG")" ]]; then
            refuse "container registry $ACR_NAME already exists in resource group $a_rg. Pass --registry-name with another name."
        fi
        item registry "$ACR_NAME" "$(created_note "$tag")"
        return
    fi
    item registry "$ACR_NAME" "create (Basic)"
    az_write acr create --name "$ACR_NAME" --resource-group "$RG" --location "$LOCATION" --sku Basic \
        --admin-enabled false --tags "$TAG_KEY=$TAG_VALUE" --query "[id,loginServer]" -o tsv
    ACR_NEW=1
    if [[ "$DRY_RUN" == 1 ]]; then
        PLANNED+="$ACR_ID "
    else
        read -r ACR_ID ACR_LOGIN <<<"$(tr '\n' ' ' <<<"$AZ_OUT")"
    fi
}

import_images() {
    local repos="" repo
    if [[ "$ACR_NEW" == 0 ]]; then
        az_read acr repository list --name "$ACR_NAME" -o tsv || AZ_OUT=""
        repos=$AZ_OUT
    fi
    # An image already in the registry under the release tag is not imported
    # again. This assumes release tags are immutable: a tag that were
    # re-pushed with other content would not reach this registry.
    for repo in "${IMAGES[@]}"; do
        if grep -qx -- "$repo" <<<"$repos" &&
            az_read acr repository show-tags --name "$ACR_NAME" --repository "$repo" -o tsv &&
            grep -qx -- "$IMAGE_TAG" <<<"$AZ_OUT"; then
            item image "$repo:$IMAGE_TAG" "in $ACR_NAME"
            continue
        fi
        item image "$repo:$IMAGE_TAG" "import from $SOURCE_REGISTRY"
        az_write acr import --name "$ACR_NAME" --source "$SOURCE_REGISTRY/$repo:$IMAGE_TAG" --image "$repo:$IMAGE_TAG"
    done
}

ensure_logs() {
    [[ "$LOG_ANALYTICS" == 1 ]] || return 0
    LOGS_NAME="$PREFIX-logs"
    local tag=""
    if ! rg_planned && az_read monitor log-analytics workspace show --workspace-name "$LOGS_NAME" \
        --resource-group "$RG" --query "[customerId,tags.\"$TAG_KEY\"]" -o tsv; then
        read -r LOGS_CUSTOMER_ID tag <<<"$(tr '\n' ' ' <<<"$AZ_OUT")"
        item "log analytics" "$LOGS_NAME" "$(created_note "$tag")"
        return
    fi
    item "log analytics" "$LOGS_NAME" "create (billed per GB ingested)"
    az_write monitor log-analytics workspace create --workspace-name "$LOGS_NAME" --resource-group "$RG" \
        --location "$LOCATION" --tags "$TAG_KEY=$TAG_VALUE" --query customerId -o tsv
    LOGS_NEW=1
    LOGS_CUSTOMER_ID=${AZ_OUT:-<workspace-customer-id>}
}

ensure_aca_env() {
    ENV_NAME="$PREFIX-aca-env"
    ENV_ID="$RG_ID/providers/Microsoft.App/managedEnvironments/$ENV_NAME"
    local tag="" logs=(--logs-destination none) key
    if ! rg_planned && [[ "$EXT_PLANNED" == 0 ]] &&
        az_read containerapp env show --name "$ENV_NAME" --resource-group "$RG" \
            --query "[id,tags.\"$TAG_KEY\"]" -o tsv; then
        read -r ENV_ID tag <<<"$(tr '\n' ' ' <<<"$AZ_OUT")"
        item "aca environment" "$ENV_NAME" "$(created_note "$tag")"
        az_read containerapp env show --name "$ENV_NAME" --resource-group "$RG" \
            --query "properties.workloadProfiles[].name" -o tsv ||
            die "could not read the Container Apps environment workload profiles"
        if grep -qx Consumption <<<"$AZ_OUT"; then
            ENV_HAS_CONSUMPTION=1
        else
            item "aca environment" "$ENV_NAME" "Consumption-only environment cannot route egress through a firewall"
        fi
        return
    fi
    if [[ "$LOG_ANALYTICS" == 1 ]]; then
        key="<key>"
        if [[ "$DRY_RUN" == 0 || "$LOGS_NEW" == 0 ]]; then
            # The key goes straight to the create command and is never printed.
            az_read monitor log-analytics workspace get-shared-keys --workspace-name "$LOGS_NAME" \
                --resource-group "$RG" --query primarySharedKey -o tsv ||
                die "could not read the Log Analytics workspace key"
            key=$AZ_OUT
        fi
        logs=(--logs-destination log-analytics --logs-workspace-id "$LOGS_CUSTOMER_ID" --logs-workspace-key "$key")
    fi
    item "aca environment" "$ENV_NAME" "create (workload profiles with Consumption)"
    az_write containerapp env create --name "$ENV_NAME" --resource-group "$RG" --location "$LOCATION" \
        --enable-workload-profiles true "${logs[@]}" --tags "$TAG_KEY=$TAG_VALUE" --query id -o tsv
    if [[ "$DRY_RUN" == 1 ]]; then
        ENV_HAS_CONSUMPTION=1
        PLANNED+="$ENV_ID "
    else
        ENV_HAS_CONSUMPTION=1
        ENV_ID=$AZ_OUT
    fi
}

ensure_job() {
    local tag="" profile_args=()
    if ! rg_planned && [[ "$EXT_PLANNED" == 0 ]] &&
        az_read containerapp job show --name "$JOB_NAME" --resource-group "$RG" \
            --query "[id,tags.\"$TAG_KEY\"]" -o tsv; then
        read -r _ tag <<<"$(tr '\n' ' ' <<<"$AZ_OUT")"
        item "aca job" "$JOB_NAME" "$(created_note "$tag")"
        return
    fi
    if [[ "$ENV_HAS_CONSUMPTION" == 1 ]]; then
        item "aca job" "$JOB_NAME" "create (manual trigger, Consumption profile)"
        profile_args=(--workload-profile-name Consumption)
    else
        item "aca job" "$JOB_NAME" "create (manual trigger)"
    fi
    # One replica per execution, 1 CPU and 2 GiB, as DataLoader dispatches
    # each partition. The job pulls from the registry as the identity.
    az_write containerapp job create --name "$JOB_NAME" --resource-group "$RG" --environment "$ENV_ID" \
        --trigger-type Manual --parallelism 1 --replica-completion-count 1 --replica-retry-limit 0 \
        --replica-timeout "$JOB_TIMEOUT" --image "$ACR_LOGIN/dataloader-worker:$IMAGE_TAG" \
        --cpu 1.0 --memory 2.0Gi "${profile_args[@]}" --mi-user-assigned "$MI_ID" \
        --registry-server "$ACR_LOGIN" --registry-identity "$MI_ID" \
        --env-vars "AZURE_CLIENT_ID=$MI_CLIENT" \
        --tags "$TAG_KEY=$TAG_VALUE" -o none
}

# role_description: marks the role assignments `up` makes, so `down` can
# find them (role assignments take no tags). It names the subscription, the
# group and the run id.
role_description() { printf '%s=%s' "$TAG_KEY" "$TAG_VALUE"; }

# grant ROLE SCOPE PRINCIPAL TYPE LABEL
grant() {
    local role=$1 scope=$2 principal=$3 type=$4 label=$5 name
    name="$role ($label)"
    if ! planned "$scope" && ! planned "$principal" &&
        az_read role assignment list --scope "$scope" --role "$role" \
            --query "[?principalId=='$principal'].id" -o tsv && [[ -n "$AZ_OUT" ]]; then
        item role "$name" "on ${scope##*/}: exists"
        return
    fi
    item role "$name" "on ${scope##*/}: assign"
    az_write role assignment create --assignee-object-id "$principal" --assignee-principal-type "$type" \
        --role "$role" --scope "$scope" --description "$(role_description)" -o none
}

grant_registry_and_vault_roles() {
    grant "$ROLE_SECRETS_USER" "$VAULT_ID" "$MI_PRINCIPAL" ServicePrincipal identity
    if [[ "$SINGLE_VAULT" == 0 ]]; then
        grant "$ROLE_SECRETS_USER" "$PROD_VAULT_ID" "$MI_PRINCIPAL" ServicePrincipal identity
        # Promotion copies a missing secret into the PROD vault only with this.
        [[ "$PROD_VAULT_WRITE" == 0 ]] ||
            grant "$ROLE_SECRETS_OFFICER" "$PROD_VAULT_ID" "$MI_PRINCIPAL" ServicePrincipal identity
    fi
    grant "$ROLE_ACR_PULL" "$ACR_ID" "$MI_PRINCIPAL" ServicePrincipal identity
}

grant_fanout_roles() {
    local who=("$MI_PRINCIPAL|ServicePrincipal|identity") entry p t l
    [[ -z "$ARM_PRINCIPAL" ]] || who+=("$ARM_PRINCIPAL|$ARM_PRINCIPAL_TYPE|arm principal")
    for entry in "${who[@]}"; do
        IFS='|' read -r p t l <<<"$entry"
        grant "$ROLE_READER" "$RG_ID" "$p" "$t" "$l"
        grant "$ROLE_ACA_JOBS" "$RG_ID" "$p" "$t" "$l"
        grant "$ROLE_MI_OPERATOR" "$MI_ID" "$p" "$t" "$l"
    done
}

# vm_args: the az arguments that name the VM.
VM_ARGS=()
vm_args() {
    if [[ "$VM" == /subscriptions/* ]]; then
        VM_ARGS=(--ids "$VM")
    else
        VM_ARGS=(--name "$VM" --resource-group "$RG")
    fi
}

attach_vm() {
    [[ -n "$VM" ]] || return 0
    vm_args
    az_read vm identity show "${VM_ARGS[@]}" --query "keys(userAssignedIdentities || \`{}\`)" -o tsv ||
        die "VM $VM was not found"
    # Resource IDs compare without case: Azure returns them in either.
    if ! planned "$MI_ID" && [[ "$(lower "$AZ_OUT" | tr '\t' ' ') " == *"$(lower "$MI_ID") "* ]]; then
        item vm "${VM##*/}" "has the identity"
        return
    fi
    item vm "${VM##*/}" "attach the identity"
    az_write vm identity assign "${VM_ARGS[@]}" --identities "$MI_ID" -o none
}

json_str() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

outputs_json() {
    local worker="$ACR_LOGIN/dataloader-worker:$IMAGE_TAG" prod=null
    if [[ "$SINGLE_VAULT" == 0 ]]; then
        prod="{ \"name\": $(json_str "$PROD_VAULT_NAME"), \"uri\": $(json_str "$PROD_VAULT_URI") }"
    fi
    cat <<EOF
{
  "tenant_id": $(json_str "$TENANT"),
  "location": $(json_str "$LOCATION"),
  "vaults": {
    "test": { "name": $(json_str "$VAULT_NAME"), "uri": $(json_str "$VAULT_URI") },
    "prod": $prod
  },
  "managed_identity": {
    "client_id": $(json_str "$MI_CLIENT"),
    "principal_id": $(json_str "$MI_PRINCIPAL"),
    "resource_id": $(json_str "$MI_ID")
  },
  "compute_backend": {
    "subscription_id": $(json_str "$SUB"),
    "resource_group": $(json_str "$RG"),
    "managed_identity_client_id": $(json_str "$MI_CLIENT"),
    "container_image_tag": null,
    "container_registry_url": $(json_str "$ACR_LOGIN")
  },
  "runtime": {
    "aca_subscription_id": $(json_str "$SUB"),
    "aca_resource_group": $(json_str "$RG"),
    "aca_environment_id": $(json_str "$ENV_ID"),
    "aca_worker_image": $(json_str "$worker"),
    "aca_managed_identity_resource_id": $(json_str "$MI_ID")
  },
  "aca_job_name": $(json_str "$JOB_NAME")
}
EOF
}

write_outputs() {
    local json
    json=$(outputs_json)
    say ""
    if [[ "$DRY_RUN" == 1 ]]; then
        say "Outputs (dry run, not written; <...> values exist once up runs):"
        say "$json"
        say ""
        say "Dry run: nothing was changed."
        return
    fi
    printf '%s\n' "$json" >"$OUTPUT.tmp"
    mv "$OUTPUT.tmp" "$OUTPUT"
    say "Outputs, written to $OUTPUT:"
    say "$json"
    say ""
    if [[ "$SINGLE_VAULT" == 1 ]]; then
        say "  Key Vault:  register $VAULT_URI for both environments, Sign in with: Managed identity."
    else
        say "  Key Vaults: register $VAULT_URI for TEST and $PROD_VAULT_URI for PROD,"
        say "              Sign in with: Managed identity, then set the TEST vault's PROD reads to $PROD_VAULT_NAME."
    fi
    say "  Identity:   set AZURE_CLIENT_ID=$MI_CLIENT in DataLoader's .env and install with --managed-identity."
    say "  Fan-out:    PUT /api/v1/settings/compute-backend takes \"compute_backend\";"
    say "              PATCH /api/v1/settings/runtime takes \"runtime\"."
}

cmd_up() {
    say "DataLoader Azure provisioning: up"
    say "  subscription $SUB, resource group $RG, location $LOCATION, release $IMAGE_TAG"
    [[ "$DRY_RUN" == 0 ]] || say "  dry run: reads run, changes are printed and skipped"
    say ""
    check_account
    ensure_extension
    ensure_providers
    ensure_rg
    ensure_identity
    ensure_vaults
    ensure_registry
    import_images
    grant_registry_and_vault_roles
    ensure_logs
    ensure_aca_env
    ensure_job
    grant_fanout_roles
    attach_vm
    write_outputs
}

# --- down --------------------------------------------------------------------

# type_rank TYPE: delete order. A job goes before its environment, and the
# identity last, since the job uses it.
type_rank() {
    case "$(lower "$1")" in
        microsoft.app/jobs) echo 1 ;;
        microsoft.app/managedenvironments) echo 2 ;;
        microsoft.operationalinsights/workspaces) echo 3 ;;
        microsoft.containerregistry/registries) echo 4 ;;
        microsoft.keyvault/vaults) echo 5 ;;
        microsoft.managedidentity/userassignedidentities) echo 7 ;;
        *) echo 6 ;;
    esac
}

# list_our_roles: sets ROLES to "id<TAB>role<TAB>scope" lines for the role
# assignments this deployment made. `az role assignment list` cannot take
# --all with a scope, so it lists the group's own scope and each vault,
# registry and identity in the group, the only scopes `up` assigns on.
ROLES=""
list_our_roles() {
    local scopes s
    ROLES=""
    az_read resource list --resource-group "$RG" \
        --query "[?type=='Microsoft.KeyVault/vaults' || type=='Microsoft.ContainerRegistry/registries' || type=='Microsoft.ManagedIdentity/userAssignedIdentities'].id" \
        -o tsv || AZ_OUT=""
    scopes="$RG_ID"$'\n'"$AZ_OUT"
    while IFS= read -r s; do
        [[ -n "$s" ]] || continue
        az_read role assignment list --scope "$s" \
            --query "[?description=='$(role_description)'].[id,roleDefinitionName,scope]" -o tsv || AZ_OUT=""
        [[ -z "$AZ_OUT" ]] || ROLES+="$AZ_OUT"$'\n'
    done <<<"$scopes"
}

confirm_down() {
    [[ "$DRY_RUN" == 0 && "$ASSUME_YES" == 0 ]] || return 0
    if ! is_tty; then
        die "down deletes the resources listed above. Re-run with --yes."
    fi
    local answer=""
    read -r -p "Delete them? Type yes: " answer
    [[ "$answer" == yes ]] || die "nothing was changed"
}

cmd_down() {
    say "DataLoader Azure provisioning: down"
    say "  subscription $SUB, resource group $RG"
    [[ "$DRY_RUN" == 0 ]] || say "  dry run: reads run, changes are printed and skipped"
    say ""
    check_account
    az_read group exists --name "$RG" || AZ_OUT=false
    if [[ "$(lower "$AZ_OUT")" != true ]]; then
        say "Resource group $RG does not exist. Nothing to remove."
        return 0
    fi
    read_rg_tags
    if [[ -z "$RUN_ID" ]]; then
        item "resource group" "$RG" "keep (not created by this script)"
        say "Nothing in $RG was created by this script: the group has no $RUN_TAG tag."
        return 0
    fi
    set_tag_value
    local rg_ours=0
    if [[ "$RG_CREATED_BY" == "$RUN_ID" ]]; then rg_ours=1; fi
    az_read resource list --resource-group "$RG" \
        --query "[?tags.\"$TAG_KEY\"=='$TAG_VALUE'].[id,type,name]" -o tsv || AZ_OUT=""
    local resources=$AZ_OUT
    # What stays once ours are gone decides the group, in a dry run too.
    az_read resource list --resource-group "$RG" \
        --query "length([?tags.\"$TAG_KEY\"!='$TAG_VALUE'])" -o tsv || AZ_OUT=0
    local others=${AZ_OUT:-0}
    list_our_roles
    local roles=$ROLES

    local id type name role scope mi_id="" vaults=() sorted=""
    say "Run id $RUN_ID. To remove:"
    while IFS=$'\t' read -r id role scope; do
        [[ -n "$id" ]] || continue
        item role "$role" "on ${scope##*/}"
    done <<<"$roles"
    while IFS=$'\t' read -r id type name; do
        [[ -n "$id" ]] || continue
        item "${type##*/}" "$name" delete
        sorted+="$(type_rank "$type")"$'\t'"$id"$'\t'"$type"$'\t'"$name"$'\n'
        case "$(lower "$type")" in
            microsoft.managedidentity/userassignedidentities) mi_id=$id ;;
            microsoft.keyvault/vaults) vaults+=("$name") ;;
        esac
    done <<<"$resources"
    if [[ "$rg_ours" == 0 ]]; then
        item "resource group" "$RG" "keep (not created by this script)"
    elif [[ "$others" != 0 ]]; then
        item "resource group" "$RG" "keep (holds $others resource(s) this script did not create)"
    else
        item "resource group" "$RG" "delete (empty once the above are gone)"
    fi
    if [[ -z "$resources" && -z "$roles" && "$rg_ours" == 0 ]]; then
        say "Nothing in $RG was created by this script."
        return 0
    fi
    say ""
    confirm_down

    if [[ -n "$VM" && -n "$mi_id" ]]; then
        vm_args
        az_write vm identity remove "${VM_ARGS[@]}" --identities "$mi_id" -o none
    fi
    while IFS=$'\t' read -r id role scope; do
        [[ -z "$id" ]] || az_write role assignment delete --ids "$id"
    done <<<"$roles"
    while IFS=$'\t' read -r _ id type name; do
        [[ -n "$id" ]] || continue
        az_write resource delete --ids "$id"
    done < <(printf '%s' "$sorted" | sort -n -k1,1)
    for name in "${vaults[@]}"; do
        if [[ "$PURGE_VAULT" == 1 ]]; then
            az_write keyvault purge --name "$name"
        else
            say "  Key Vault $name is soft-deleted and keeps its name. Purge it with: az keyvault purge --name $name"
        fi
    done

    if [[ "$rg_ours" == 1 ]]; then
        # A real run counts again after the deletes, in case something
        # landed in the group meanwhile.
        if [[ "$DRY_RUN" == 0 && "$others" == 0 ]]; then
            az_read resource list --resource-group "$RG" --query "length(@)" -o tsv || AZ_OUT=0
            others=${AZ_OUT:-0}
        fi
        if [[ "$others" == 0 ]]; then
            az_write group delete --name "$RG" --yes
        elif [[ "$DRY_RUN" == 1 ]]; then
            say "  Would keep resource group $RG, because it holds resources this script did not create."
        else
            say "  Kept resource group $RG, because it holds resources this script did not create."
        fi
    fi
    say ""
    if [[ "$DRY_RUN" == 1 ]]; then say "Dry run: nothing was changed."; else say "Done."; fi
}

main() {
    parse_args "$@"
    validate_args
    command -v az >/dev/null 2>&1 || die "the Azure CLI (az) is not on PATH"
    ERR_FILE=$(mktemp)
    trap 'rm -f "$ERR_FILE"' EXIT
    case "$CMD" in
        up) cmd_up ;;
        down) cmd_down ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
