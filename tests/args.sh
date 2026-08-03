#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_NAME=pvc-migration.sh
source "$ROOT_DIR/pvc-migration.sh"

assert_equal() {
	local name="$1" expected="$2" actual="$3"
	if [[ "$expected" != "$actual" ]]; then
		printf '%s: expected <%s>, got <%s>\n' "$name" "$expected" "$actual" >&2
		exit 1
	fi
}

parse_common_args test \
	--migration migration-long --deploy old-deployment \
	-n namespace -c context --pvc old-pvc
assert_equal context context "$CLI_CONTEXT"
assert_equal namespace namespace "$CLI_NAMESPACE"
assert_equal migration migration-long "$CLI_MIGRATION"
assert_equal remaining "--deploy old-deployment --pvc old-pvc" "${CLI_ARGS[*]}"

parse_discovery_args test
assert_equal deploy old-deployment "$DISCOVERY_DEPLOY"
assert_equal pvc old-pvc "$DISCOVERY_PVC"
assert_equal remaining-after-discovery "" "${CLI_ARGS[*]}"

parse_common_args test -c context -n namespace -m migration --compress
parse_copy_args test
assert_equal compress true "$COPY_COMPRESS"
assert_equal remaining-after-copy "" "${CLI_ARGS[*]}"

if parse_common_args test --context --namespace namespace --migration migration >/dev/null 2>&1; then
	printf 'A missing --context value must fail\n' >&2
	exit 1
fi

parse_common_args test -c context -n namespace -m migration --unknown
if require_no_command_args status >/dev/null 2>&1; then
	printf 'An unknown command argument must fail\n' >&2
	exit 1
fi

if cmd_status prod namespace migration >/dev/null 2>&1; then
	printf 'The legacy positional syntax must fail\n' >&2
	exit 1
fi

check_dependencies() {
	printf 'check_dependencies must not run for help\n' >&2
	return 1
}

main_help=$(main --help)
if [[ "$main_help" != *"Common options"* ]]; then
	printf 'Global help did not render\n' >&2
	exit 1
fi

command_help=$(main help discover-new)
if [[ "$command_help" != *"auto-discovered"* ]]; then
	printf 'Subcommand help did not render\n' >&2
	exit 1
fi

printf 'Argument parser tests passed.\n'
