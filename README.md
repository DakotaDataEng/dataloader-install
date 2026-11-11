# DataLoader install

Release: v0.1.82

## Before you start

Use an x86_64 Linux host with Docker and sudo.

Install Node 18 or newer for verify.sh and the Claude Code skills.

Sign in with the Azure CLI when TAGS includes azure.

Gather the client's values listed by group in vars.example.env.

A Snowflake destination needs an external stage on S3 or ADLS Gen2 before its first load. See [section 5 of the Snowflake runbook](docs/runbooks/client-snowflake.md#5-create-the-external-stage).

## Four steps

1. Clone this repository at tag v0.1.82 to get the pinned installer, skills, and runbooks.

2. Copy vars.example.env to vars.env and fill in the client values; the installer uses this private file.

3. Run ./install.sh; a successful install prints the DataLoader URL.

4. Run ./verify.sh; a successful verification writes evidence/acceptance-client-<date>.

## On Windows

Use Git Bash and Docker Desktop.

In vars.env, set INSTALL_DIR to a folder under your home folder, for example /c/Users/you/dataloader, not /opt/dataloader.

Put MSYS_NO_PATHCONV=1 before any command that takes a /path argument, or Git Bash rewrites the path.

The admin password is the DL_BOOTSTRAP_ADMIN_PASSWORD line of <install dir>/.env.

## Afterward

Send Dakota the evidence/acceptance-client-<date> folder.

## Upgrade

Fetch the new tag, rerun install.sh, then run verify.sh.

## CLI and plugin SDK

Download dl-linux-x86_64, dl-windows-x86_64.exe, the dataloader_plugin_sdk wheel or source archive, and dl-checksums.txt from https://github.com/DakotaDataEng/dataloader-install/releases/tag/v0.1.82.

In the download directory, run sha256sum -c dl-checksums.txt to check all files.

## Help

Open Claude Code in this repository and say "diagnose".
