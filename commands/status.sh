cmd_status() {
	local command="status"
	parse_common_args "$command" "$@" || return 1
	require_common_args "$command" || return 1
	require_no_command_args "$command" || return 1

	local context="$CLI_CONTEXT" namespace="$CLI_NAMESPACE" migration_id="$CLI_MIGRATION"

	local sf
	sf=$(state_file_path "$context" "$namespace" "$migration_id")

	if [[ ! -f "$sf" ]]; then
		log_info "No state file found at $sf"
		exit 0
	fi

	echo "State file: $sf"
	echo ""
	echo "===== State contents ====="
	cat "$sf"
	echo ""

	local reclaim_policy_old
	reclaim_policy_old=$(state_get "$context" "$namespace" "$migration_id" "RECLAIM_POLICY_OLD" || true)
	if [[ -n "$reclaim_policy_old" ]]; then
		log_info "Old PV reclaim policy: $reclaim_policy_old"
	fi

	local phase
	phase=$(state_get "$context" "$namespace" "$migration_id" "PHASE" || true)
	if [[ -n "$phase" ]]; then
		log_info "Current phase: $phase"
	fi
}
