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
		log_warn "Source PV uses ReclaimPolicy=Delete and no completed backup is recorded."
		log_warn "Verify the source backup before running copy-data."
		;;
	Retain)
		;;
	*)
		log_warn "Source ReclaimPolicy is unknown and no completed backup is recorded."
		log_warn "Treat the source as unsafe until a backup is verified."
		;;
	esac
}
