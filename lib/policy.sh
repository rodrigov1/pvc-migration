# ---- PersistentVolume reclaim policy helpers ----

normalize_reclaim_policy() {
	local policy="${1:-}"
	if [[ -n "$policy" ]]; then
		printf '%s\n' "$policy"
	else
		printf 'unknown\n'
	fi
}

reclaim_policy_requires_backup() {
	[[ "${1:-unknown}" != "Retain" ]]
}

log_reclaim_policy_discovery() {
	local policy="${1:-unknown}"
	case "$policy" in
	Delete)
		log_warn "Old PV has persistentVolumeReclaimPolicy=Delete."
		log_warn "Deleting the old PVC may delete the PV and its backend data."
		log_warn "Run 'backup' before deploying or syncing the new chart."
		;;
	Retain)
		log_ok "Old PV has persistentVolumeReclaimPolicy=Retain."
		log_info "The old PV and backend data should remain after PVC deletion; backup is optional."
		;;
	*)
		log_warn "Could not determine the old PV reclaim policy (value: $policy)."
		log_warn "Treating the source as unsafe: run 'backup' before deploying or syncing the new chart."
		;;
	esac
}

reclaim_policy_warn_if_backup_missing() {
	local policy="${1:-unknown}" phase="${2:-unknown}"

	[[ "$phase" == "backed_up" ]] && return 0

	case "$policy" in
	Delete)
		log_warn "Old PV has ReclaimPolicy=Delete, but no completed backup is recorded (phase: $phase)."
		log_warn "If the old PVC is removed, the source data may already be or become unavailable."
		log_warn "Verify or create the backup before continuing whenever possible."
		;;
	Retain)
		;;
	*)
		log_warn "Old PV reclaim policy is unknown, and no completed backup is recorded (phase: $phase)."
		log_warn "Verify the PV policy and run 'backup' before continuing whenever possible."
		;;
	esac
}
