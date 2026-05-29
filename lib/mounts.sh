# shellcheck shell=bash
# Mount state helpers — indexed format (MOUNT_COUNT_OLD, MOUNT_OLD_0, SUBPATH_OLD_0, ...)
# with backward compat for legacy __ delimited MOUNT_OLD / SUBPATH_OLD keys.

# Sets global MOUNTS_LIST, SUBPATHS_LIST, MOUNT_COUNT
state_get_mounts() {
	local context="$1" namespace="$2" migration_id="$3"
	local prefix="$4"

	MOUNTS_LIST=()
	SUBPATHS_LIST=()

	local count
	count=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_COUNT_${prefix}" || true)

	if [[ -n "$count" ]]; then
		local i
		for ((i = 0; i < count; i++)); do
			MOUNTS_LIST+=("$(state_get "$context" "$namespace" "$migration_id" "MOUNT_${prefix}_${i}" || true)")
			SUBPATHS_LIST+=("$(state_get "$context" "$namespace" "$migration_id" "SUBPATH_${prefix}_${i}" || true)")
		done
		MOUNT_COUNT="$count"
	else
		local mounts_str subpaths_str
		mounts_str=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_${prefix}" || true)
		subpaths_str=$(state_get "$context" "$namespace" "$migration_id" "SUBPATH_${prefix}" || true)

		while IFS= read -r line; do [[ -n "$line" ]] && MOUNTS_LIST+=("$line"); done <<<"$(echo "$mounts_str" | sed 's/__/\n/g')"
		while IFS= read -r line; do SUBPATHS_LIST+=("$line"); done <<<"$(echo "$subpaths_str" | sed 's/__/\n/g')"

		MOUNT_COUNT="${#MOUNTS_LIST[@]}"
	fi

	if [[ "$MOUNT_COUNT" -eq 0 ]]; then
		MOUNT_COUNT=1
		MOUNTS_LIST=("")
		SUBPATHS_LIST=("")
	fi

	while [[ ${#SUBPATHS_LIST[@]} -lt "$MOUNT_COUNT" ]]; do SUBPATHS_LIST+=(""); done
}

state_set_mounts() {
	local context="$1" namespace="$2" migration_id="$3"
	local prefix="$4"
	local count="$5"
	shift 5

	# Remove legacy __ keys
	state_del "$context" "$namespace" "$migration_id" "MOUNT_${prefix}"
	state_del "$context" "$namespace" "$migration_id" "SUBPATH_${prefix}"

	# Remove previous indexed keys
	state_del_prefix "$context" "$namespace" "$migration_id" "MOUNT_${prefix}_"
	state_del_prefix "$context" "$namespace" "$migration_id" "SUBPATH_${prefix}_"
	state_del "$context" "$namespace" "$migration_id" "MOUNT_COUNT_${prefix}"

	state_set "$context" "$namespace" "$migration_id" "MOUNT_COUNT_${prefix}" "$count"

	local i
	for ((i = 0; i < count; i++)); do
		state_set "$context" "$namespace" "$migration_id" "MOUNT_${prefix}_${i}" "$1"
		shift
	done
	for ((i = 0; i < count; i++)); do
		state_set "$context" "$namespace" "$migration_id" "SUBPATH_${prefix}_${i}" "$1"
		shift
	done
}
