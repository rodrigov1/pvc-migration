# PVC Migration

Modular bash toolset (`pvc-migration.sh` + `lib/` + `commands/`) to migrate K8s PVC/PV data between NFS backends.

## Current State (Phase 6 COMPLETE)

- **Goal**: Split the original monolith into modular `commands/*.sh`, `lib/`, `ui/`
- **Progress**: Phase 6 COMPLETE — baseline SHA-256/content and POSIX metadata verification added, strict quiescing enabled, and versioned verified backups implemented.
- **Entry point**: `pvc-migration.sh` dispatches to `cmd_*` and sources all commands.
- **CLI**: common options use `--context/-c`, `--namespace/-n`, and `--migration/-m`; positional arguments are not supported.

## Requirements

- `bash` (≥4.3 for namerefs), `kubectl`, `jq`, `ssh`, `tar`, `find`, `awk`, `sed`, `grep`, `sha256sum`, `stat`, `sort`, `cmp`, `readlink` — all on `$PATH`
- The script is **interactive** (uses `read` prompts). Run in a TTY — piping stdin breaks confirmations.
- Multi-cluster aware — every `kubectl` call passes `--context`.

## Workflow

Strictly ordered pipeline per app:

```
discover-old → discover-new → copy-data → validate
```

- `discover-old` discovers old PVC/PV/NFS state
- `discover-new` discovers new PVC/PV/NFS state (after chart sync)
- `copy-data` scales **both** deployments to 0, copies via `tar` over SSH (no compression by default), and compares baseline SHA-256/content and POSIX metadata manifests per mount. Add `--compress` for gzip on slow links. Shows progress via `pv` if installed.
- `backup` quiesces the old deployment, captures source baseline manifests, and creates versioned per-mount `.tgz` tarballs before deploying the new chart. Only needed when PV has ReclaimPolicy: Delete.
- If `copy-data` is re-run and the old NFS source no longer exists (e.g., PV deleted with ReclaimPolicy:Delete), it restores from the verified backup and compares the destination against the saved source baseline.
- `validate` requires `VERIFY_STATUS=passed`, scales new deploy to 1, checks every mount from the pod, and prints a cleanup assessment.

Each subcommand reads/writes from a state file, so you **must** complete the prior step first.

## Multi-mount support

A single PVC can have **multiple volume mounts** with different subPaths (e.g., a 50Gi PVC mounted at 5 different paths). Mounts are stored in **indexed format**: `MOUNT_COUNT_OLD`, `MOUNT_OLD_0`/`SUBPATH_OLD_0`, `MOUNT_OLD_1`/`SUBPATH_OLD_1`, etc. (see `lib/mounts.sh`). Legacy `__`-delimited `MOUNT_OLD`/`SUBPATH_OLD` files are still read via a compat fallback.

- `NFS_PATH_OLD` / `NFS_PATH_NEW` are set to the **PV root** (`<SHARE>/<PV_UID>/` for CSI, `<SHARE>/` for spec.nfs)
- `copy-data` iterates over each mount pair, refuses mismatched mount counts, and verifies each subpath with baseline manifests
- `validate` checks every mount path inside the pod after baseline verification has passed

## tmux / screen support

For `backup` and `copy-data`, the entrypoint offers to wrap the complete command in a `tmux` or `screen` session before any operational work starts.

```
Run the complete copy-data workflow inside tmux (survives disconnects)? [Y/n]
```

Sessions are named `pvc-mig-<subcommand>-<migration-id>`. Quiescing, transfer, verification, publication, and state updates all run inside the session.

## State files

Stored at **`$HOME/.pvc-migration/state/<context>/<namespace>/<migration-id>.env`** — the repo's `state/` dir is empty and unused. Baseline artifacts live in the adjacent `<migration-id>.verify/` directory.

## Syntax

`--migration/-m` is an arbitrary label used only to name the state file and verification artifacts. It does not need to match any cluster resource name.

- `discover-old` **requires** `--deploy` and `--pvc` (old deployment and PVC names)
- `discover-new` accepts optional `--deploy`/`--pvc` for the new side; if omitted, it auto-discovers using the migration-id as a substring pattern
- `validate` always recomputes `NEW_TOTAL_SIZE` from NFS (avoid stale size from `discover-new`)

## Typical invocation

```bash
./pvc-migration.sh discover-old -c prod -n n8n -m n8n-2026-08 --deploy n8n-n8n --pvc n8n-n8n-deployment-pvc
./pvc-migration.sh discover-new -c prod -n n8n -m n8n-2026-08 --deploy n8n --pvc n8n-pvc
./pvc-migration.sh copy-data -c prod -n n8n -m n8n-2026-08
./pvc-migration.sh validate -c prod -n n8n -m n8n-2026-08
```

## Auto-discovery quirks

- `discover-old` uses **no auto-discovery** — `--deploy` and `--pvc` are required.
- `discover-new` falls back to **case-insensitive substring** matching using the migration-id if `--deploy`/`--pvc` are omitted. If ambiguous after filtering the old resource, it lists candidates and requires the corresponding explicit option. It filters out the old deployment/PVC from state when possible.
- `discover-old` warns if the PVC name contains the size suffix from the legacy 4.3.x naming bug (for example `--...-2gi-pvc`). The current 5.0.0 format may still contain `--`, but no longer includes that size suffix.

## Guardrails

- `set -euo pipefail` at line 2
- `state_require()` errors if discover-old was never run
- `copy-data` verifies SSH access to both NFS hosts and waits for selected deployments to reach zero pods before proceeding

## Phase 3: Commands Extracted (COMPLETE, `dbdac70`)

**Files created:** `commands/{status,validate,discover_old,discover_new,backup,copy_data}.sh`

**Changes:**
- `pvc-migration.sh` sources `commands/*.sh` and dispatches to `cmd_*`
- All functions renamed to `cmd_*` prefix
- `state_set` uses delete+append (not `sed`) to avoid escaping bugs
- `cleanup` subcommand removed (validate prints cleanup instructions)

## Phase 4: Indexed Mounts + spec.nfs + Quoting (COMPLETE, `c3550be`)

**Files created:** `lib/mounts.sh` — `state_set_mounts()`/`state_get_mounts()` with indexed format + legacy `__` compat fallback

**Changes:**
- Mount storage migrated from `__`-delimited `MOUNT_OLD`/`SUBPATH_OLD` to indexed `MOUNT_COUNT_OLD`, `MOUNT_OLD_0`/`SUBPATH_OLD_0`, …
- `lib/state.sh`: added `state_del_prefix()` for bulk key deletion by prefix pattern
- `spec.nfs` PV path fix: `PV_UID` is now optional — when absent (spec.nfs PVs), `NFS_PATH` uses only the share base (`<SHARE>/` instead of `<SHARE>/<PV_UID>/`)
- Temp scripts in `copy-data` and `backup` use `printf '%q'` for safe quoting of all variables (paths with spaces, quotes, etc.)
- `containers[0]` kubectl calls centralized into `get_volume_mounts_from_deploy()` in `lib/kube.sh`
- `head -1` → `find -printf 1 -quit` for empty-directory check in `copy-data`
- `pvc-migration.sh` now correctly sources all `commands/*.sh` (was broken since Phase 3 — only sourced `status.sh`)
- Unused variables removed (`subpaths_str` in backup, `mount_new` in validate)

## Phase 5: Entrypoint cleanup and verification

**Changes:**
- Removed the legacy `pvc_migration.sh` entrypoint and its duplicated inline implementation.
- Enabled `check_dependencies()` from the modular entrypoint.
- Added `tests/smoke_dispatcher.sh` and `tests/run.sh`; the dispatcher test verifies exactly one dispatch per subcommand.
- Removed unused helper modules and functions.
- Added ShellCheck guidance to `README.md`; ShellCheck remains optional because it is not installed on the development host.

## Phase 6: Baseline verification and consistent backups

**Changes:**
- Added NUL-safe per-mount baseline manifests with SHA-256 content records and POSIX metadata records.
- `copy-data` captures source/destination baselines after quiescing and refuses mismatches.
- `backup` quiesces the old deployment, captures the source baseline, creates a versioned staged backup, and verifies it with `tar --compare` before publishing.
- `validate` requires `VERIFY_STATUS=passed` and checks all new mount paths from the pod.
- Added baseline, backup, copy-result, and special-path tests.

## Remaining / Cleanup

- `containers[0]` limits support to the first container in multi-container pods.
- Ambiguous auto-discovery now fails and requires explicit `--deploy`/`--pvc` selection.
- `state_set_mounts` does not yet validate indexed count/value consistency.
- Baseline does not yet compare ACLs, xattrs, SELinux labels, sparse allocation, or hard-link topology.
