cmd_status() {
	local context="${1:-}" namespace="${2:-}" migration_id="${3:-}"

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME status <context> <namespace> <migration-id>"
		exit 1
	fi

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

	local phase
	phase=$(state_get "$context" "$namespace" "$migration_id" "PHASE" || true)
	if [[ -n "$phase" ]]; then
		log_info "Current phase: $phase"
	fi
}
