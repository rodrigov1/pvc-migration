#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/pvc-migration.sh"

declare -A MOCK_STATE=()
STATE_BASE=$(mktemp -d)
old_root=$(mktemp -d)
mkdir -p "$old_root/data"
printf 'backup baseline data\n' >"$old_root/data/file.txt"
mock_bin=$(mktemp -d)

printf '%s\n' \
	'#!/bin/bash' \
	'set -euo pipefail' \
	'host="$1"' \
	'shift' \
	'remote_command="$1"' \
	'if [[ "${MOCK_BACKUP_FAIL:-false}" == true && "$remote_command" == *"--create"* ]]; then exit 1; fi' \
	'exec bash -c "$remote_command"' >"$mock_bin/ssh"
chmod +x "$mock_bin/ssh"
PATH="$mock_bin:$PATH"
export MOCK_BACKUP_FAIL=false

state_require() {
	:
}

state_get() {
	case "$4" in
	OLD_NFS_HOST) printf 'old-host\n' ;;
	NFS_PATH_OLD) printf '%s/\n' "$old_root/data" ;;
	DEPLOY_OLD) printf 'old-deployment\n' ;;
	*) printf '%s\n' "${MOCK_STATE[$4]:-}" ;;
	esac
}

state_set() {
	MOCK_STATE["$4"]="$5"
}

state_get_mounts() {
	MOUNT_COUNT=1
	MOUNTS_LIST=("/data")
	SUBPATHS_LIST=("")
}

get_deploy_selector() {
	printf 'app=%s\n' "$3"
}

confirm() {
	return 0
}

confirm_default_yes() {
	return 1
}

kubectl() {
	return 0
}

ssh() {
	local host="$1" remote_command="$2"
	bash -c "$remote_command"
}

output_file=$(mktemp)
if ! cmd_backup --context test-context --namespace test-namespace --migration test-migration \
	>"$output_file" 2>&1; then
	cat "$output_file" >&2
	printf 'Consistent backup flow must succeed\n' >&2
	exit 1
fi

backup_base="${MOCK_STATE[BACKUP_BASE_OLD]:-}"
if [[ "${MOCK_STATE[PHASE]:-}" != backed_up || -z "$backup_base" ]]; then
	printf 'Backup must persist backed_up and BACKUP_BASE_OLD\n' >&2
	exit 1
fi
if [[ ! -f "$backup_base/0.tgz" || ! -f "$backup_base/metadata.env" ]]; then
	printf 'Published backup artifacts are missing\n' >&2
	exit 1
fi
backup_root=$(dirname "$backup_base")
if ! verification_find_current_backup old-host "$backup_root" ||
	[[ "$RECOVERED_BACKUP_BASE" != "$backup_base" ]]; then
	printf 'Published backup must be recoverable through the current pointer\n' >&2
	exit 1
fi
if ! verification_load_backup_metadata old-host "$RECOVERED_BACKUP_BASE" ||
	[[ "$BACKUP_METADATA_GENERATION" != "${MOCK_STATE[BACKUP_VERIFY_OLD_GENERATION]:-}" ||
		"$BACKUP_METADATA_MOUNT_COUNT" != 1 ]]; then
	printf 'Self-contained backup metadata must recover generation and mount count\n' >&2
	exit 1
fi
expected_generation="${MOCK_STATE[BACKUP_VERIFY_OLD_GENERATION]}"
unset 'MOCK_STATE[BACKUP_BASE_OLD]' 'MOCK_STATE[BACKUP_VERIFY_OLD_GENERATION]' \
	'MOCK_STATE[BACKUP_MOUNT_COUNT]' 'MOCK_STATE[BACKUP_ARCHIVE_DIGEST_0]' \
	'MOCK_STATE[VERIFY_OLD_GENERATION]' 'MOCK_STATE[VERIFY_OLD_MOUNT_COUNT]'
if ! verification_hydrate_backup_state test-context test-namespace test-migration \
	old-host "$RECOVERED_BACKUP_BASE"; then
	printf 'Backup metadata must recover missing state values\n' >&2
	exit 1
fi
if [[ "${MOCK_STATE[BACKUP_BASE_OLD]:-}" != "$backup_base" ||
	"${MOCK_STATE[BACKUP_VERIFY_OLD_GENERATION]:-}" != "$expected_generation" ||
	"${MOCK_STATE[VERIFY_OLD_GENERATION]:-}" != "$expected_generation" ]]; then
	printf 'Recovered backup state values are incomplete\n' >&2
	exit 1
fi
if ! verification_side_ready test-context test-namespace test-migration OLD; then
	printf 'Source baseline must be available after backup\n' >&2
	exit 1
fi
if ! verification_check_backup_archives test-context test-namespace test-migration \
	old-host "$backup_base" 1; then
	printf 'Published backup digest must validate\n' >&2
	exit 1
fi
printf 'tamper\n' >>"$backup_base/0.tgz"
if verification_check_backup_archives test-context test-namespace test-migration \
	old-host "$backup_base" 1 >/dev/null 2>&1; then
	printf 'A modified backup archive must fail digest validation\n' >&2
	exit 1
fi

MOCK_BACKUP_FAIL=true
if cmd_backup --context test-context --namespace test-namespace --migration test-migration \
	>/dev/null 2>&1; then
	printf 'A failed backup command must return failure\n' >&2
	exit 1
fi
if [[ "${MOCK_STATE[PHASE]:-}" != backup-failed || -z "${MOCK_STATE[BACKUP_ERROR_TIMESTAMP]:-}" ]]; then
	printf 'A failed backup must persist backup-failed state\n' >&2
	exit 1
fi

rm -f "$output_file" "$old_root/data/file.txt" "$mock_bin/ssh" \
	"$backup_base/0.tgz" "$backup_base/metadata.env" "$backup_root/current"
rm -rf -- "$backup_root"
rmdir "$old_root/data" "$old_root" "$mock_bin"
verify_dir=$(verification_dir test-context test-namespace test-migration)
rm -rf -- "$verify_dir"
rmdir "$STATE_BASE/test-context/test-namespace" "$STATE_BASE/test-context" "$STATE_BASE"

printf 'Backup baseline tests passed.\n'
