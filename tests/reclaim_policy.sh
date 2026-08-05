#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_NAME=pvc-migration.sh
source "$ROOT_DIR/pvc-migration.sh"

MOCK_POLICY=""

kubectl() {
	local args="$*"
	if [[ "$args" == *"persistentVolumeReclaimPolicy"* ]]; then
		printf '%s' "$MOCK_POLICY"
	elif [[ "$args" == *".spec.template.spec.volumes"* ]]; then
		printf 'data\n'
	fi
}

get_pv_from_pvc() {
	printf 'pv-old\n'
}

get_volume_handle() {
	:
}

get_nfs_from_pv() {
	printf 'NFS_HOST=old-nfs\nNFS_SHARE_BASE=/srv/nfs/old\n'
}

get_volume_mounts_from_deploy() {
	printf '@/data|\n'
}

get_pvcs_from_deploy() {
	printf 'pvc-one\npvc-two\n'
}

get_pod_for_deploy() {
	:
}

ssh() {
	return 1
}

confirm() {
	printf '[?] %s [y/N] y\n' "$1"
	return 0
}

assert_contains() {
	local value="$1" expected="$2"
	if [[ "$value" != *"$expected"* ]]; then
		printf 'Expected output to contain: %s\n' "$expected" >&2
		exit 1
	fi
}

assert_state_value() {
	local state_file="$1" key="$2" expected="$3" actual
	actual=$(grep "^${key}=" "$state_file" | cut -d= -f2- || true)
	if [[ "$actual" != "$expected" ]]; then
		printf 'Expected %s=%s, got %s\n' "$key" "$expected" "${actual:-<empty>}" >&2
		exit 1
	fi
}

run_discover_old() {
	local policy="$1" expected_output="$2"
	local state_root state_file output

	state_root=$(mktemp -d)
	STATE_BASE="$state_root"
	MOCK_POLICY="$policy"
	output=$(cmd_discover_old \
		--context test-context --namespace test-namespace --migration test-migration \
		--deploy old-deployment --pvc old-pvc 2>&1)
	state_file="$state_root/test-context/test-namespace/test-migration.env"

	assert_state_value "$state_file" RECLAIM_POLICY_OLD "${policy:-unknown}"
	assert_contains "$output" "$expected_output"
	assert_contains "$output" "Deployment old-deployment uses 2 PVCs; migrating only:"

	rm -f "$state_file"
	rmdir "$state_root/test-context/test-namespace" "$state_root/test-context" "$state_root"
}

run_discover_old Delete "backup required before deploying"
run_discover_old Retain "backup optional"
run_discover_old "" "backup recommended"

state_root=$(mktemp -d)
STATE_BASE="$state_root"
pattern_output=$(cmd_discover_old \
	--context test-context --namespace test-namespace --migration test-migration \
	--deploy old-deployment --pvc old--15gi-pvc 2>&1)
assert_contains "$pattern_output" "PVC name includes a size suffix from the legacy 4.3.x naming bug"
assert_contains "$pattern_output" "Use this PVC as migration source?"
if [[ "$pattern_output" == *"===="* || "$pattern_output" == *"Verifying deployment"* ]]; then
	printf 'discover-old warning/output should not contain the legacy verbose banner\n' >&2
	exit 1
fi
state_file="$state_root/test-context/test-namespace/test-migration.env"
rm -f "$state_file"
rmdir "$state_root/test-context/test-namespace" "$state_root/test-context" "$state_root"

state_root=$(mktemp -d)
STATE_BASE="$state_root"
modern_output=$(cmd_discover_old \
	--context test-context --namespace test-namespace --migration test-migration \
	--deploy old-deployment --pvc old--var-www-html-sites-all-pvc 2>&1)
if [[ "$modern_output" == *"size suffix from the legacy"* || "$modern_output" == *"Use this PVC as migration source?"* ]]; then
	printf 'discover-old must not flag the current double-dash naming without a size suffix\n' >&2
	exit 1
fi
state_file="$state_root/test-context/test-namespace/test-migration.env"
rm -f "$state_file"
rmdir "$state_root/test-context/test-namespace" "$state_root/test-context" "$state_root"

state_root=$(mktemp -d)
STATE_BASE="$state_root"
state_set test-context test-namespace test-migration PHASE discovered-old
state_set test-context test-namespace test-migration RECLAIM_POLICY_OLD Delete
discover_new_output=$(cmd_discover_new \
	--context test-context --namespace test-namespace --migration test-migration \
	--deploy new-deployment --pvc new-pvc 2>&1)
assert_contains "$discover_new_output" "no completed backup is recorded"
state_file="$state_root/test-context/test-namespace/test-migration.env"
rm -f "$state_file"
rmdir "$state_root/test-context/test-namespace" "$state_root/test-context" "$state_root"

delete_warning=$(reclaim_policy_warn_if_backup_missing Delete discovered-old)
assert_contains "$delete_warning" "no completed backup is recorded"

retain_warning=$(reclaim_policy_warn_if_backup_missing Retain discovered-old)
if [[ -n "$retain_warning" ]]; then
	printf 'Retain must not warn about a missing backup\n' >&2
	exit 1
fi

backed_up_warning=$(reclaim_policy_warn_if_backup_missing Delete backed_up)
if [[ -n "$backed_up_warning" ]]; then
	printf 'A completed backup must suppress the warning\n' >&2
	exit 1
fi

printf 'Reclaim policy tests passed.\n'
