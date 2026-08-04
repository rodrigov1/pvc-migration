# PVC Migration

Single Bash tool to migrate K8s PVC/PV data between NFS backends.

Supports multi-mount PVCs with different `subPath`s, backup/restore for `ReclaimPolicy: Delete` PVs, cross-host copy via tar-pipe over SSH, and progress display via `pv`.

## Requirements

- `bash` ≥ 4.3, `kubectl`, `ssh`, `jq`, `tar`, `find`, `awk`, `sed`, `grep`, `sha256sum`, `stat`, `sort`, `cmp`, `readlink`
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
| `discover-old` | Discover old PVC/PV/NFS state; baseline is captured after quiescing |
| `backup` | Create compressed `.tgz` backup tarballs on the old NFS host |
| `discover-new` | Discover new deployment/PVC/PV/NFS state after chart deploy |
| `copy-data` | Copy/restore data via tar-pipe SSH; auto-restores from backup if source is gone |
| `validate` | Require baseline success, scale new deployment, and verify pod mounts |
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

## Baseline verification

`copy-data` uses `baseline-v1` verification after the tar stream completes.
The source and destination are compared per mount using NUL-safe manifests:

- SHA-256 content digest bound to each relative path;
- entry type, mode, numeric UID/GID, regular-file size and nanosecond mtime;
- symlink target and empty directories;
- missing and extra entries.

The source is captured after the writers are quiesced. For `Delete` PVs,
`backup` captures and stores the source manifests before publishing a versioned
backup, so restore can verify against the original source even if the PV is
later removed. `PHASE=copied` is written only after the baseline comparison
passes; otherwise the state is marked `copy-failed`.

Each published backup contains its baseline generation, mount count, and
per-archive SHA-256 digests. The backup root also contains an atomically updated
`current` pointer. If the process was interrupted after publication but before
the local state was updated, `copy-data` can recover and validate the selected
backup from this self-contained metadata.

Baseline does not yet compare ACLs, xattrs, SELinux labels, physical sparse
allocation, or hard-link topology. These require an explicit compatibility
profile because NFS backends may not preserve them equivalently.

Verification artifacts are stored alongside the migration state at:

```text
$HOME/.pvc-migration/state/<context>/<namespace>/<migration-id>.verify/
```

Baseline reads all source and destination file contents once for SHA-256. This
is intentionally more expensive than a file count, but it is the required
trade-off for detecting content changes and paths with identical data.

## Persistent sessions

When `tmux` or `screen` is available, `backup` and `copy-data` offer to run the
entire command inside an attached persistent session. The complete workflow —
quiescing, transfer, baseline verification, backup publication, and state
updates — continues if the operator disconnects. Reattach with the session name
printed by the command. If the script is already running inside tmux/screen, it
does not create a nested session.

## State files

Stored at `$HOME/.pvc-migration/state/<context>/<namespace>/<migration-id>.env`.

Each migration has its own state file with all discovered and computed values.
Baseline verification artifacts are stored in the migration's `.verify/` directory,
with separate content and metadata manifests per mount.

## Development

The tool is organized as:

```
commands/     — subcommand implementations
lib/          — shared helpers (args, state, kube, nfs, remote, session, verification, mounts, policy)
ui/           — logging, prompts, usage
tests/        — parser, dispatcher, reclaim-policy, copy-result, and baseline tests
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
