# ---- Validation helpers ----

require_context_namespace_migration_id() {
	local context="$1" namespace="$2" migration_id="$3"
	[[ -n "$context" && -n "$namespace" && -n "$migration_id" ]]
}

ensure_single_match_or_fail() {
	local matches="$1" label="$2" extra_hint="$3"
	local count
	count=$(echo "$matches" | grep -c . || true)
	if [[ "$count" -eq 0 ]]; then
		log_error "No $label found."
		[[ -n "$extra_hint" ]] && log_info "$extra_hint"
		exit 1
	elif [[ "$count" -gt 1 ]]; then
		log_warn "Multiple $label found:"
		echo "$matches"
		[[ -n "$extra_hint" ]] && log_info "$extra_hint"
		exit 1
	fi
}
