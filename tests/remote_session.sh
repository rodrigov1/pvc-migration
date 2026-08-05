#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/pvc-migration.sh"

ssh() {
	local host="$1" remote_command="$2"
	bash -c "$remote_command"
}

tmp_dir=$(mktemp -d)
danger_marker="$ROOT_DIR/pvc-migration-remote-test-marker"
rm -f "$danger_marker"
special_path="$tmp_dir/file ' with spaces \$(touch pvc-migration-remote-test-marker)"
printf 'safe\n' >"$special_path"

if ! ssh_run local-host test -f "$special_path"; then
	printf 'ssh_run must preserve special path arguments\n' >&2
	exit 1
fi
if [[ -e "$danger_marker" ]]; then
	printf 'ssh_run evaluated shell content from a path\n' >&2
	exit 1
fi
if [[ "$(ssh_bash local-host 'printf "%s" "$1"' "$special_path")" != "$special_path" ]]; then
	printf 'ssh_bash must preserve special path arguments\n' >&2
	exit 1
fi

build_persistent_session_command copy-data -c prod -n app -m "migration with spaces" --compress
eval "set -- $PERSISTENT_SESSION_COMMAND"
if [[ "$1" != env || "$2" != PVC_MIGRATION_SESSION=1 || "$4" != copy-data ||
	"${10}" != "migration with spaces" || "${11}" != --compress ||
	"$PERSISTENT_SESSION_NAME" != pvc-mig-copy-data-migration-with-spaces ]]; then
	printf 'Persistent session command did not preserve the full workflow arguments\n' >&2
	exit 1
fi

session_root=$(mktemp -d)
mock_bin=$(mktemp -d)
for dependency in kubectl ssh jq; do
	printf '#!/bin/bash\nexit 0\n' >"$mock_bin/$dependency"
	chmod +x "$mock_bin/$dependency"
done
export STATE_BASE="$session_root"
export PATH="$mock_bin:$PATH"

build_persistent_session_command status -c test -n test -m status-success
write_persistent_session_wrapper status -c test -n test -m status-success
if ! printf '\n' | bash "$PERSISTENT_SESSION_WRAPPER" >"$session_root/success.out" 2>&1; then
	printf 'A successful persistent wrapper command must exit successfully\n' >&2
	exit 1
fi
if ! session_result_code || [[ "$PERSISTENT_SESSION_EXIT_CODE" != 0 ]]; then
	printf 'Persistent wrapper must record a successful exit code\n' >&2
	exit 1
fi
if ! grep -q 'Persistent workflow completed successfully' "$PERSISTENT_SESSION_LOG"; then
	printf 'Persistent wrapper log must record success\n' >&2
	exit 1
fi

build_persistent_session_command copy-data -c test -n test -m missing-state
write_persistent_session_wrapper copy-data -c test -n test -m missing-state
if printf '\n' | bash "$PERSISTENT_SESSION_WRAPPER" >"$session_root/failure.out" 2>&1; then
	printf 'A failed persistent wrapper command must fail\n' >&2
	exit 1
fi
if ! session_result_code || [[ "$PERSISTENT_SESSION_EXIT_CODE" != 1 ]]; then
	printf 'Persistent wrapper must record a failed exit code\n' >&2
	exit 1
fi
if ! grep -q 'State file not found' "$PERSISTENT_SESSION_LOG"; then
	printf 'Persistent wrapper log must preserve the workflow error\n' >&2
	exit 1
fi

rm -f "$special_path"
rmdir "$tmp_dir"
rm -f "$mock_bin"/*
rmdir "$mock_bin"
rm -f "$session_root/success.out" "$session_root/failure.out"
rm -f "$session_root/sessions"/*
rmdir "$session_root/sessions" "$session_root"
printf 'Remote and session tests passed.\n'
