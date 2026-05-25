# ACS default policy cloner

This repo contains a Bash script that clones built-in/default Red Hat Advanced Cluster Security for Kubernetes policies into new custom policies with a suffix.

The default suffix is `-ABC`, so a policy named:

```text
Fixable Severity at least Important
```

is cloned as:

```text
Fixable Severity at least Important-ABC
```

The script is designed to be safe to re-run. It skips a default policy when a policy with the target clone name already exists.

## Why this exists

RHACS allows security policies to be exported and imported as JSON. Exporting a policy includes the policy contents, including cluster scopes, cluster exclusions, and configured notifications when used within the same Central instance. The RHACS portal does not export multiple policies at once, but the API can be used for multiple policy export operations.

This script uses that API-based workflow to clone the default policies in batches.

## Files

```text
clone-acs-default-policies.sh  # Main script
README.md                      # This file
```

## Requirements

Run the script from a workstation or jump host that can reach RHACS Central.

Required tools:

- `bash`
- `curl`
- `jq`

On Fedora/RHEL:

```bash
sudo dnf install -y curl jq
```

On Ubuntu/Debian:

```bash
sudo apt-get update
sudo apt-get install -y curl jq
```

## Required ACS permissions

Use an API token that can read, export, import, and create/modify policies.

A typical admin token will work. For a least-privilege setup, the token needs policy read/write permissions.

## Usage

Make the script executable:

```bash
chmod +x clone-acs-default-policies.sh
```

Set the ACS Central endpoint and API token:

```bash
export ROX_ENDPOINT="https://central-stackrox.apps.example.com"
export ROX_API_TOKEN="your-api-token"
```

Run the script:

```bash
./clone-acs-default-policies.sh
```

By default, cloned policies are created **disabled**. This avoids duplicate alerts or enforcement actions while you review the cloned policy set.

## Common options

### Use the default `-ABC` suffix

No extra setting is needed:

```bash
./clone-acs-default-policies.sh
```

### Use a different suffix

```bash
export SUFFIX="-CUSTOM"
./clone-acs-default-policies.sh
```

### Create enabled clones

The safer default is to create clones disabled. To create enabled clones:

```bash
export DISABLE_CLONES=false
./clone-acs-default-policies.sh
```

### Skip TLS verification

Use this only for lab environments or when Central uses a certificate your workstation does not trust:

```bash
export ROX_INSECURE=true
./clone-acs-default-policies.sh
```

### Change batch size

The script exports and imports policies in batches to avoid very large API payloads.

Default:

```bash
export BATCH_SIZE=25
```

For slower links, proxies, or smaller Central/API limits:

```bash
export BATCH_SIZE=10
./clone-acs-default-policies.sh
```

### Dry run

This generates the export/import payloads but does not import anything into ACS:

```bash
export DRY_RUN=true
./clone-acs-default-policies.sh
```

When `DRY_RUN=true`, the temporary work directory is kept and printed at the end.

### Keep temporary files for troubleshooting

```bash
export KEEP_WORKDIR=true
./clone-acs-default-policies.sh
```

The temporary directory contains JSON request and response files for each batch.

## Environment variables

| Variable | Default | Description |
|---|---:|---|
| `ROX_ENDPOINT` | required | URL for RHACS Central, for example `https://central-stackrox.apps.example.com` |
| `ROX_API_TOKEN` | required | API token used to call RHACS |
| `SUFFIX` | `-ABC` | Suffix appended to cloned policy names |
| `DISABLE_CLONES` | `true` | Create cloned policies disabled by default |
| `BATCH_SIZE` | `25` | Number of policies to export/import per batch |
| `ROX_INSECURE` | `false` | Set to `true` to pass `-k` to curl |
| `DRY_RUN` | `false` | Set to `true` to generate payloads without importing |
| `KEEP_WORKDIR` | `false` | Set to `true` to keep temporary JSON files |

## What the script does

1. Reads policies from `GET /v1/policies`.
2. Selects policies where `isDefault` is `true`.
3. Skips policies that already end with the configured suffix.
4. Skips policies whose target clone name already exists.
5. Exports selected policies using `POST /v1/policies/export`.
6. Updates each exported policy:
   - appends the suffix to `.name`
   - clears `.id`
   - marks the clone as non-default where those fields exist
   - unlocks criteria/MITRE lock fields where those fields exist
   - sets `.disabled` according to `DISABLE_CLONES`
7. Imports the modified policies using `POST /v1/policies/import`.

## Safety notes

The script defaults to creating disabled cloned policies. This is intentional.

Before enabling the cloned policies, review:

- policy enforcement settings
- notifier integrations
- cluster scopes
- cluster exclusions
- deployment/runtime lifecycle stages

Policy enforcement can affect applications. Enable cloned policies gradually, especially if the originals have enforcement enabled.

## Troubleshooting

### The script says no policies need cloning

This usually means one of the following:

- the clones already exist
- the Central version/API response does not mark built-in policies with `isDefault`
- your token cannot see the policies

Run with:

```bash
export KEEP_WORKDIR=true
./clone-acs-default-policies.sh
```

Then inspect the saved `policies.json` file.

### Import fails for some policies

Run again with:

```bash
export KEEP_WORKDIR=true
./clone-acs-default-policies.sh
```

Inspect the relevant files:

```text
import-request-<batch>.json
import-response-<batch>.json
```

Lowering the batch size may also help:

```bash
export BATCH_SIZE=5
./clone-acs-default-policies.sh
```

### Self-signed certificate errors

Use either a trusted CA bundle on your workstation or, for lab use:

```bash
export ROX_INSECURE=true
./clone-acs-default-policies.sh
```

## Recommended first run

For the first run in a production-like environment:

```bash
export ROX_ENDPOINT="https://central-stackrox.apps.example.com"
export ROX_API_TOKEN="your-api-token"
export DISABLE_CLONES=true
export BATCH_SIZE=10

./clone-acs-default-policies.sh
```

Then review the new `-ABC` policies in ACS before enabling them.
