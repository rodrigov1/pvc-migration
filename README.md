# PVC Migration

Single Bash tool to migrate K8s PVC/PV data between NFS backends.

Supports multi-mount PVCs with different `subPath`s, backup/restore for `ReclaimPolicy: Delete` PVs, cross-host copy via tar-pipe over SSH, and progress display via `pv`.

## Requirements

- `bash` ≥ 4.3, `kubectl`, `ssh`, `jq`, `tar`, `find`, `awk`, `sed`, `grep`
- Optional: `pv` (progress), `tmux`/`screen` (persistent sessions)
- All must be on `$PATH`

## Quick start

### ReclaimPolicy: Retain (backup optional)

```bash
./pvc-migration.sh discover-old \
  --context prod --namespace app --migration myapp-2026-08 \
  --deploy myapp-old --pvc myapp-pvc
# deploy new chart
./pvc-migration.sh discover-new \
  --context prod --namespace app --migration myapp-2026-08 \
  --deploy myapp --pvc myapp-pvc
./pvc-migration.sh copy-data \
  --context prod --namespace app --migration myapp-2026-08
./pvc-migration.sh validate \
  --context prod --namespace app --migration myapp-2026-08
```

### ReclaimPolicy: Delete (backup before chart deploy)

```bash
./pvc-migration.sh discover-old \
  -c prod -n app -m myapp-2026-08 \
  --deploy myapp-old --pvc myapp-pvc
./pvc-migration.sh backup \
  -c prod -n app -m myapp-2026-08
# deploy new chart
./pvc-migration.sh discover-new \
  -c prod -n app -m myapp-2026-08 \
  --deploy myapp --pvc myapp-pvc
./pvc-migration.sh copy-data \
  -c prod -n app -m myapp-2026-08
./pvc-migration.sh validate \
  -c prod -n app -m myapp-2026-08
```

The long options are the recommended form. Short aliases are available for
the common options:

```text
--context   (-c)  kubectl context, for example: prod
--namespace (-n)  Kubernetes namespace, for example: app
--migration (-m)  local migration label/state name, for example: myapp-2026-08
```

The previous positional form is no longer supported. Use `help` or
`--help` for command-specific examples:

```bash
./pvc-migration.sh --help
./pvc-migration.sh help discover-new
```

## Subcommands

| Command | Description |
|---|---|
| `discover-old` | Discover old PVC/PV/NFS state and capture file manifests |
| `backup` | Create compressed `.tgz` backup tarballs on the old NFS host |
| `discover-new` | Discover new deployment/PVC/PV/NFS state after chart deploy |
| `copy-data` | Copy/restore data via tar-pipe SSH; auto-restores from backup if source is gone |
| `validate` | Scale new deployment, verify files inside pod against old manifests |
| `status` | Display current state file |

## Reclaim policy safety

`discover-old` reads the effective `persistentVolumeReclaimPolicy` from the
old PV and stores it as `RECLAIM_POLICY_OLD` in the migration state:

- `Retain`: the old PV/backend should remain after PVC deletion; backup is
  optional, but still recommended for critical data.
- `Delete`: run `backup` **before** deploying or syncing the new chart.
  Removing the old PVC may remove the PV and its backend data.
- Unknown or unsupported values: the tool treats the source as unsafe and
  recommends `backup`.

`discover-new` warns if the old policy was `Delete` (or unknown) and the state
does not record a completed backup. It does not block the command, since a
backup may have been performed externally.

## State files

Stored at `$HOME/.pvc-migration/state/<context>/<namespace>/<migration-id>.env`.

Each migration has its own state file with all discovered and computed values.
File manifests are stored alongside, numbered per mount (`.manifest.1`, `.manifest.2`, ...).

## Development

The tool is organized as:

```
commands/     — subcommand implementations
lib/          — shared helpers (args, state, kube, nfs, manifest, mounts, policy)
ui/           — logging, prompts, usage
tests/        — dispatcher and reclaim-policy tests
```

Only `pvc-migration.sh` is supported as the entrypoint. The former
`pvc_migration.sh` entrypoint was removed after the modular implementation
was completed.

Run the smoke tests with:

```bash
bash ./tests/run.sh
```

For static analysis, install ShellCheck and run:

```bash
shellcheck --shell=bash pvc-migration.sh commands/*.sh lib/*.sh ui/*.sh
```

## Security notes

- Always review the state file before running destructive operations
- Run `backup` BEFORE deploying a new chart when ReclaimPolicy is Delete
- Validate app functionality manually after `validate`
- Do not delete old PV/PVC until the migration is confirmed successful
