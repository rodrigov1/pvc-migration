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

rm -f "$special_path"
rmdir "$tmp_dir"
printf 'Remote and session tests passed.\n'
