# PVC Migration

Single Bash tool to migrate K8s PVC/PV data between NFS backends.

Supports multi-mount PVCs with different `subPath`s, backup/restore for `ReclaimPolicy: Delete` PVs, cross-host copy via tar-pipe over SSH, and progress display via `pv`.

## Requirements

- `bash` ≥ 4.0, `kubectl`, `ssh`, `jq`, `tar`, `find`, `awk`, `sed`, `grep`
- Optional: `pv` (progress), `tmux`/`screen` (persistent sessions)
- All must be on `$PATH`

## Quick start

### ReclaimPolicy: Retain (no backup needed)

```bash
./pvc-migration.sh discover-old prod app myapp --deploy myapp-old --pvc myapp-pvc
# deploy new chart
./pvc-migration.sh discover-new prod app myapp --deploy myapp
./pvc-migration.sh copy-data prod app myapp
./pvc-migration.sh validate prod app myapp
```

### ReclaimPolicy: Delete (backup before chart deploy)

```bash
./pvc-migration.sh discover-old prod app myapp --deploy myapp-old --pvc myapp-pvc
./pvc-migration.sh backup prod app myapp
# deploy new chart
./pvc-migration.sh discover-new prod app myapp --deploy myapp
./pvc-migration.sh copy-data prod app myapp
./pvc-migration.sh validate prod app myapp
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

## State files

Stored at `$HOME/.pvc-migration/state/<context>/<namespace>/<migration-id>.env`.

Each migration has its own state file with all discovered and computed values.
File manifests are stored alongside, numbered per mount (`.manifest.1`, `.manifest.2`, ...).

## Development

The tool is organized as:

```
commands/     — subcommand implementations
lib/          — shared helpers (state, kube, nfs, manifest, copy, validation)
ui/           — logging, prompts, usage
```

## Security notes

- Always review the state file before running destructive operations
- Run `backup` BEFORE deploying a new chart when ReclaimPolicy is Delete
- Validate app functionality manually after `validate`
- Do not delete old PV/PVC until the migration is confirmed successful
