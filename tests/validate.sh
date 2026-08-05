#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/pvc-migration.sh"

declare -A MOCK_STATE=()
MOCK_SCALE_FAIL=false
MOCK_WAIT_FAIL=false
MOCK_CONFIRM=true
MOCK_KUBECTL_LOG=$(mktemp)
MOCK_OUTPUT=$(mktemp)
SELECTOR_TIMEOUT_FILE=$(mktemp)
trap 'rm -f "$MOCK_KUBECTL_LOG" "$MOCK_OUTPUT" "$SELECTOR_TIMEOUT_FILE"' EXIT

state_require() {
	:
}

state_get() {
	case "$4" in
	DEPLOY_NEW) printf 'new-deployment\n' ;;
	PVC_OLD) printf 'old-pvc\n' ;;
	PVC_NEW) printf 'new-pvc\n' ;;
	PV_OLD) printf 'old-pv\n' ;;
	OLD_NFS_HOST) printf 'old-host\n' ;;
	NFS_PATH_OLD) printf '/old-root/\n' ;;
	NEW_NFS_HOST) printf 'new-host\n' ;;
	NFS_PATH_NEW) printf '/new-root/\n' ;;
	VERIFY_STATUS) printf '%s\n' "${MOCK_STATE[VERIFY_STATUS]:-passed}" ;;
	PHASE) printf '%s\n' "${MOCK_STATE[PHASE]:-copied}" ;;
	*) printf '%s\n' "${MOCK_STATE[$4]:-}" ;;
	esac
}

state_set() {
	MOCK_STATE["$4"]="$5"
}

state_get_mounts() {
	MOUNT_COUNT=1
	MOUNTS_LIST=("/var/www/html")
	SUBPATHS_LIST=("")
}

get_deploy_selector() {
	printf '%s' "${4:-}" >"$SELECTOR_TIMEOUT_FILE"
	printf 'app=new-deployment\n'
}

compute_total_size_nfs() {
	printf '0\n'
}

human_size() {
	printf '%s' "$1"
}

confirm() {
	$MOCK_CONFIRM
}

kubectl() {
	printf '%s\n' "$*" >>"$MOCK_KUBECTL_LOG"
	case "$1 $2" in
	scale\ deployment)
		if $MOCK_SCALE_FAIL; then
			return 1
		fi
		return 0
		;;
	wait\ deployment)
		if $MOCK_WAIT_FAIL; then
			return 1
		fi
		return 0
		;;
	get\ pods)
		if [[ " $* " == *jsonpath* ]]; then
			printf 'new-pod\n'
		else
			printf 'new-pod 0/1 CrashLoopBackOff\n'
		fi
		return 0
		;;
	logs)
		printf 'diagnostic log line\n'
		return 0
		;;
	describe\ pod)
		printf 'Events:\n  Warning  BackOff\n'
		return 0
		;;
	exec)
		printf 'total 4\n'
		return 0
		;;
	*)
		return 0
		;;
	esac
}

reset_case() {
	MOCK_STATE=()
	MOCK_SCALE_FAIL=false
	MOCK_WAIT_FAIL=false
	MOCK_CONFIRM=true
	: >"$MOCK_KUBECTL_LOG"
	: >"$SELECTOR_TIMEOUT_FILE"
}

reset_case
MOCK_SCALE_FAIL=true
if cmd_validate --context test-context --namespace test-namespace --migration test-migration \
	>"$MOCK_OUTPUT" 2>&1; then
	printf 'validate must fail when scale fails\n' >&2
	exit 1
fi
if [[ "${MOCK_STATE[PHASE]:-}" != validation-failed ]]; then
	printf 'Scale failure must mark validation-failed\n' >&2
	exit 1
fi
if grep -q '^wait deployment' "$MOCK_KUBECTL_LOG"; then
	printf 'validate must not wait after scale failure\n' >&2
	exit 1
fi
if ! grep -q -- '--request-timeout=15s' "$MOCK_KUBECTL_LOG"; then
	printf 'scale must use a Kubernetes request timeout\n' >&2
	exit 1
fi

reset_case
MOCK_WAIT_FAIL=true
MOCK_CONFIRM=false
if cmd_validate --context test-context --namespace test-namespace --migration test-migration \
	>"$MOCK_OUTPUT" 2>&1; then
	printf 'validate must fail when the rollout is unavailable\n' >&2
	exit 1
fi
if [[ "${MOCK_STATE[PHASE]:-}" != validation-failed ]]; then
	printf 'Unavailable rollout must mark validation-failed\n' >&2
	exit 1
fi
for expected in 'logs new-pod' 'describe pod new-pod' 'get events'; do
	if ! grep -q "$expected" "$MOCK_KUBECTL_LOG"; then
		printf 'Rollout diagnostics must include: %s\n' "$expected" >&2
		exit 1
	fi
done
if ! grep -q -- '--previous' "$MOCK_KUBECTL_LOG"; then
	printf 'Rollout diagnostics must include previous pod logs\n' >&2
	exit 1
fi

MOCK_WAIT_FAIL=false
MOCK_CONFIRM=true
if ! cmd_validate --context test-context --namespace test-namespace --migration test-migration \
	>"$MOCK_OUTPUT" 2>&1; then
	printf 'validate must be retryable after a previous rollout failure\n' >&2
	exit 1
fi
if [[ "${MOCK_STATE[PHASE]:-}" != validated ]]; then
	printf 'A retry after validation-failed must be able to reach validated\n' >&2
	exit 1
fi

reset_case
if ! cmd_validate --context test-context --namespace test-namespace --migration test-migration \
	>"$MOCK_OUTPUT" 2>&1; then
	printf 'validate should succeed for a ready deployment\n' >&2
	exit 1
fi
if [[ "${MOCK_STATE[PHASE]:-}" != validated ]]; then
	printf 'Successful validate must mark validated\n' >&2
	exit 1
fi
if [[ "$(<"$SELECTOR_TIMEOUT_FILE")" != 15s ]]; then
	printf 'Selector lookup must use the Kubernetes request timeout\n' >&2
	exit 1
fi
if ! grep -q '^wait deployment' "$MOCK_KUBECTL_LOG"; then
	printf 'Successful validate must wait for the deployment\n' >&2
	exit 1
fi
if ! grep -q -- '--request-timeout=15s' "$MOCK_KUBECTL_LOG"; then
	printf 'wait must use a Kubernetes request timeout\n' >&2
	exit 1
fi

printf 'Validate tests passed.\n'
