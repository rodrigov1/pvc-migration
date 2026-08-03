#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CALLS_FILE=$(mktemp)
trap 'rm -f "$CALLS_FILE"' EXIT

# Source the entrypoint without executing it, then replace its command
# functions. This isolates the dispatcher from kubectl, ssh, and a cluster.
source "$ROOT_DIR/pvc-migration.sh"

dependency_checks=0
check_dependencies() {
	dependency_checks=$((dependency_checks + 1))
}

record_call() {
	printf '%s\n' "$1" >>"$CALLS_FILE"
}

cmd_discover_old() { record_call discover-old; }
cmd_backup() { record_call backup; }
cmd_discover_new() { record_call discover-new; }
cmd_copy_data() { record_call copy-data; }
cmd_validate() { record_call validate; }
cmd_status() { record_call status; }

subcommands=(discover-old backup discover-new copy-data validate status)
for subcommand in "${subcommands[@]}"; do
	main "$subcommand" test-context test-namespace test-migration
done

if [[ "$dependency_checks" -ne "${#subcommands[@]}" ]]; then
	printf 'Expected check_dependencies to run %d times, got %d\n' \
		"${#subcommands[@]}" "$dependency_checks" >&2
	exit 1
fi

if [[ "$(wc -l <"$CALLS_FILE")" -ne "${#subcommands[@]}" ]]; then
	printf 'Expected one command invocation per subcommand\n' >&2
	exit 1
fi

for subcommand in "${subcommands[@]}"; do
	count=$(grep -c "^${subcommand}$" "$CALLS_FILE" || true)
	if [[ "$count" -ne 1 ]]; then
		printf 'Expected %s to be dispatched exactly once, got %d\n' "$subcommand" "$count" >&2
		exit 1
	fi
done

if [[ -e "$ROOT_DIR/pvc_migration.sh" ]]; then
	printf 'The legacy pvc_migration.sh entrypoint must not exist\n' >&2
	exit 1
fi

printf 'Dispatcher smoke test passed.\n'
