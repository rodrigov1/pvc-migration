#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/pvc-migration.sh"

make_job_script() {
	local script="$1" result_file="$2" exit_code="$3" escaped_result
	escaped_result=$(printf '%q' "$result_file")
	printf '#!/bin/bash\nprintf "exit_code=%%s\\n" "%s" > %s\nexit %s\n' \
		"$exit_code" "$escaped_result" "$exit_code" >"$script"
}

assert_result_code() {
	local result_file="$1" expected="$2"
	read_copy_result_code "$result_file"
	if [[ "$COPY_RESULT_CODE" != "$expected" ]]; then
		printf 'Expected result code %s, got %s\n' "$expected" "$COPY_RESULT_CODE" >&2
		exit 1
	fi
}

run_success_case() {
	local result_file script
	result_file=$(mktemp)
	script=$(mktemp)
	make_job_script "$script" "$result_file" 0

	if ! run_copy_job "$script" "$result_file" >/dev/null 2>&1; then
		printf 'Inline copy should succeed\n' >&2
		exit 1
	fi
	assert_result_code "$result_file" 0
	rm -f "$script" "$result_file"
}

run_failure_case() {
	local result_file script
	result_file=$(mktemp)
	script=$(mktemp)
	make_job_script "$script" "$result_file" 1

	if run_copy_job "$script" "$result_file" >/dev/null 2>&1; then
		printf 'Inline failure must be propagated\n' >&2
		exit 1
	fi
	assert_result_code "$result_file" 1
	rm -f "$script" "$result_file"
}

run_success_case
run_failure_case

missing_result=$(mktemp)
missing_script=$(mktemp)
printf '#!/bin/bash\nexit 0\n' >"$missing_script"
rm -f "$missing_result"
if run_copy_job "$missing_script" "$missing_result" >/dev/null 2>&1; then
	printf 'Missing result file must fail\n' >&2
	exit 1
fi
rm -f "$missing_script"

invalid_result=$(mktemp)
printf 'exit_code=0\nexit_code=1\n' >"$invalid_result"
if read_copy_result_code "$invalid_result"; then
	printf 'Multiple result lines must fail validation\n' >&2
	exit 1
fi
rm -f "$invalid_result"

COPY_PHASE=""
declare -A MOCK_STATE=()
MOCK_BAD_HASH=false
KUBECTL_CALLED=false
CONFIRM_COUNT=0
SCALE_COUNT=0
MOCK_MOUNT_MISMATCH=false
old_root=$(mktemp -d)
new_root=$(mktemp -d)
mock_bin=$(mktemp -d)
printf '%s\n' \
	'#!/bin/bash' \
	'set -euo pipefail' \
	'host="$1"' \
	'shift' \
	'remote_command="$1"' \
	'if [[ "${MOCK_BAD_HASH:-false}" == true && "$host" == new-host && "$remote_command" == *"sha256sum"* ]]; then' \
		'printf "00000000000000000000000000000000  fake-file\\n"' \
		'exit 0' \
		'fi' \
	'exec bash -c "$remote_command"' >"$mock_bin/ssh"
chmod +x "$mock_bin/ssh"
real_sha256sum=$(command -v sha256sum)
printf '%s\n' \
	'#!/bin/bash' \
	'if [[ "${MOCK_BAD_HASH:-false}" == true && "${MOCK_VERIFY_SIDE:-}" == new ]]; then' \
		'printf "00000000000000000000000000000000  %s\\n" "$1"' \
		'exit 0' \
	'fi' \
	"exec $real_sha256sum \"\$@\"" >"$mock_bin/sha256sum"
chmod +x "$mock_bin/sha256sum"
export MOCK_BAD_HASH
PATH="$mock_bin:$PATH"
mkdir -p "$old_root/data"
printf 'migration-data\n' >"$old_root/data/file.txt"

state_require() {
	:
}

state_get() {
	case "$4" in
	DEPLOY_OLD) printf 'old-deployment\n' ;;
	DEPLOY_NEW) printf 'old-deployment\n' ;;
	OLD_NFS_HOST) printf 'old-host\n' ;;
	NFS_PATH_OLD) printf '%s/\n' "$old_root" ;;
	NEW_NFS_HOST) printf 'new-host\n' ;;
	NFS_PATH_NEW) printf '%s/\n' "$new_root" ;;
	*) printf '%s\n' "${MOCK_STATE[$4]:-}" ;;
	esac
}

state_set() {
	MOCK_STATE["$4"]="$5"
	if [[ "$4" == "PHASE" ]]; then
		COPY_PHASE="$5"
	fi
}

state_get_mounts() {
	if [[ "$4" == NEW && "$MOCK_MOUNT_MISMATCH" == true ]]; then
		MOUNT_COUNT=2
		MOUNTS_LIST=("/data" "/other")
		SUBPATHS_LIST=("" "")
	else
		MOUNT_COUNT=1
		MOUNTS_LIST=("/data")
		SUBPATHS_LIST=("")
	fi
}

get_deploy_selector() {
	printf 'app=%s\n' "$3"
}

confirm() {
	CONFIRM_COUNT=$((CONFIRM_COUNT + 1))
	return 0
}

confirm_default_yes() {
	return 1
}

kubectl() {
	KUBECTL_CALLED=true
	case "$1 $2" in
	get\ deployment|get\ pods|scale\ deployment)
		if [[ "$1 $2" == "scale deployment" ]]; then
			SCALE_COUNT=$((SCALE_COUNT + 1))
		fi
		return 0
		;;
	*)
		return 0
		;;
	esac
}

ssh() {
	local host="$1" remote_command="$2"
	if [[ "$host" == "new-host" ]]; then
		MOCK_VERIFY_SIDE=new bash -c "$remote_command"
	else
		MOCK_VERIFY_SIDE=old bash -c "$remote_command"
	fi
}

copy_output_file=$(mktemp)
if ! cmd_copy_data --context test-context --namespace test-namespace --migration test-migration \
	>"$copy_output_file" 2>&1; then
	copy_output=$(<"$copy_output_file")
	printf 'A valid generated copy script must succeed:\n%s\n' "$copy_output" >&2
	exit 1
fi
copy_output=$(<"$copy_output_file")
rm -f "$copy_output_file"
if [[ "$COPY_PHASE" != "copied" || ! -f "$new_root/data/file.txt" ]]; then
	printf 'A successful copy must mark the phase and copy the file\nOutput:\n%s\n' "$copy_output" >&2
	exit 1
fi
if [[ "$CONFIRM_COUNT" != 1 || "$SCALE_COUNT" != 1 ]]; then
	printf 'Same old/new deployment must use one confirmation and one scale operation\n' >&2
	exit 1
fi

rm -f "$new_root/data/file.txt"
COPY_PHASE=""
MOCK_BAD_HASH=true
copy_output_file=$(mktemp)
if cmd_copy_data --context test-context --namespace test-namespace --migration test-migration \
	>"$copy_output_file" 2>&1; then
	printf 'A verification mismatch must fail copy-data\n' >&2
	exit 1
fi
rm -f "$copy_output_file"
if [[ "$COPY_PHASE" != "copy-failed" ]]; then
	printf 'A failed verification must set the copy-failed phase\n' >&2
	exit 1
fi
if [[ "${MOCK_STATE[VERIFY_STATUS]:-}" != failed ]]; then
	printf 'A failed retry must invalidate a previously passed verification\n' >&2
	exit 1
fi

MOCK_BAD_HASH=false
MOCK_MOUNT_MISMATCH=true
SCALE_COUNT=0
CONFIRM_COUNT=0
if cmd_copy_data --context test-context --namespace test-namespace --migration test-migration \
	>/dev/null 2>&1; then
	printf 'Mount mismatches must fail before any copy confirmation or scale operation\n' >&2
	exit 1
fi
if [[ "$SCALE_COUNT" != 0 || "$CONFIRM_COUNT" != 0 ]]; then
	printf 'Mount mismatch must be rejected before touching workloads\n' >&2
	exit 1
fi

MOCK_STATE[VERIFY_STATUS]=passed
MOCK_STATE[PHASE]=copy-failed
KUBECTL_CALLED=false
if cmd_validate --context test-context --namespace test-namespace --migration test-migration \
	>/dev/null 2>&1; then
	printf 'validate must reject a stale passed baseline when phase is copy-failed\n' >&2
	exit 1
fi
if [[ "$KUBECTL_CALLED" == true ]]; then
	printf 'validate must reject invalid state before touching Kubernetes\n' >&2
	exit 1
fi

rm -f "$old_root/data/file.txt" "$new_root/data/file.txt"
rm -f "$mock_bin/ssh" "$mock_bin/sha256sum"
rmdir "$old_root/data" "$old_root" "$new_root/data" "$new_root" "$mock_bin"

printf 'Copy result tests passed.\n'
