#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/pvc-migration.sh"

declare -A MOCK_STATE=()
MOCK_DEPLOY_MATCHES="new-deployment"
MOCK_PVC_MATCHES="new-pvc"
MOCK_DEST_EXISTS=false
MOCK_OUTPUT=$(mktemp)
STATE_BASE=$(mktemp -d)
trap 'rm -f "$MOCK_OUTPUT" "$STATE_BASE/test-context/test-namespace/test-migration.env"; rmdir "$STATE_BASE/test-context/test-namespace" "$STATE_BASE/test-context" "$STATE_BASE" 2>/dev/null || true' EXIT

state_require() {
	:
}

state_get() {
	case "$4" in
	RECLAIM_POLICY_OLD) printf 'Retain\n' ;;
	PHASE) printf 'discovered-old\n' ;;
	DEPLOY_OLD) printf 'old-deployment\n' ;;
	PVC_OLD) printf 'old-pvc\n' ;;
	OLD_NFS_HOST) printf 'old-host\n' ;;
	NFS_PATH_OLD) printf '/old-root/\n' ;;
	NEW_NFS_HOST) printf 'new-host\n' ;;
	NEW_NFS_SHARE_BASE) printf '/new-share\n' ;;
	*) printf '%s\n' "${MOCK_STATE[$4]:-}" ;;
	esac
}

state_set() {
	MOCK_STATE["$4"]="$5"
}

state_del() {
	unset 'MOCK_STATE[$4]'
}

state_set_mounts() {
	MOCK_STATE[MOUNT_COUNT_NEW]="$6"
}

get_deployments_by_pattern() {
	printf '%s\n' "$MOCK_DEPLOY_MATCHES"
}

get_pvcs_by_pattern() {
	printf '%s\n' "$MOCK_PVC_MATCHES"
}

get_pv_from_pvc() {
	printf 'new-pv\n'
}

get_volume_handle() {
	:
}

get_nfs_from_pv() {
	printf 'NFS_HOST=new-host\nNFS_SHARE_BASE=/new-share\n'
}

get_volume_mounts_from_deploy() {
	printf '@/new-mount|\n'
}

get_pvcs_from_deploy() {
	printf 'pvc-one\npvc-two\n'
}

parse_volume_handle() {
	:
}

ssh_run() {
	if [[ "$MOCK_DEST_EXISTS" == true ]]; then
		return 0
	fi
	return 1
}

compute_total_size_nfs() {
	printf '27\n'
}

human_size() {
	printf '%s B' "$1"
}

reclaim_policy_warn_if_backup_missing() {
	:
}

kubectl() {
	if [[ "$*" == *".spec.template.spec.volumes"* ]]; then
		printf 'data\n'
	fi
	return 0
}

reset_case() {
	MOCK_STATE=()
	MOCK_DEPLOY_MATCHES="new-deployment"
	MOCK_PVC_MATCHES="new-pvc"
	MOCK_DEST_EXISTS=false
	: >"$MOCK_OUTPUT"
}

reset_case
MOCK_DEST_EXISTS=true
MOCK_STATE[MOUNT_COUNT_NEW]=5
explicit_output=$(cmd_discover_new \
	--context test-context --namespace test-namespace --migration test-migration \
	--deploy new-deployment --pvc new-pvc 2>&1)
if [[ "$explicit_output" != *"Destination discovery:"* ||
	"$explicit_output" != *"Destination:  exists (27 B)"* ||
	"$explicit_output" != *"Deployment new-deployment uses 2 PVCs; migrating only:"* ||
	"$explicit_output" != *"Mount count differs from the source:"* ]]; then
	printf 'Explicit discover-new output is missing the compact destination summary\n%s\n' "$explicit_output" >&2
	exit 1
fi
if [[ "$explicit_output" == *"New VolumeHandle"* ||
	"$explicit_output" == *"Contents:"* ||
	"$explicit_output" == *"Picked:"* ]]; then
	printf 'Explicit discover-new output still contains verbose or ambiguous-selection details\n' >&2
	exit 1
fi

reset_case
MOCK_DEPLOY_MATCHES=$'new-one\nnew-two'
if cmd_discover_new --context test-context --namespace test-namespace --migration test-migration \
	--pvc new-pvc >"$MOCK_OUTPUT" 2>&1; then
	printf 'Ambiguous deployment auto-discovery must fail\n' >&2
	exit 1
fi
ambiguous_deploy_output=$(<"$MOCK_OUTPUT")
if [[ "$ambiguous_deploy_output" != *"Multiple deployments match"* ||
	"$ambiguous_deploy_output" != *"--deploy <deployment>"* ||
	"$ambiguous_deploy_output" == *"Picked:"* ]]; then
	printf 'Ambiguous deployment failure is missing the explicit-selection guidance\n' >&2
	exit 1
fi

reset_case
MOCK_PVC_MATCHES=$'new-pvc-one\nnew-pvc-two'
if cmd_discover_new --context test-context --namespace test-namespace --migration test-migration \
	--deploy new-deployment >"$MOCK_OUTPUT" 2>&1; then
	printf 'Ambiguous PVC auto-discovery must fail\n' >&2
	exit 1
fi
ambiguous_pvc_output=$(<"$MOCK_OUTPUT")
if [[ "$ambiguous_pvc_output" != *"Multiple PVCs match"* ||
	"$ambiguous_pvc_output" != *"--pvc <pvc>"* ||
	"$ambiguous_pvc_output" == *"Picked:"* ]]; then
	printf 'Ambiguous PVC failure is missing the explicit-selection guidance\n' >&2
	exit 1
fi

reset_case
auto_output=$(cmd_discover_new \
	--context test-context --namespace test-namespace --migration test-migration 2>&1)
if [[ "$auto_output" != *"new-deployment (auto-discovered)"* ||
	"$auto_output" != *"new-pvc (auto-discovered)"* ||
	"$auto_output" != *"Destination:  not created yet"* ]]; then
	printf 'Unique auto-discovery output is missing its compact labels\n%s\n' "$auto_output" >&2
	exit 1
fi

printf 'Discover-new tests passed.\n'
