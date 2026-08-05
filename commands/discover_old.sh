cmd_discover_old() {
	local command="discover-old"
	parse_common_args "$command" "$@" || return 1
	parse_discovery_args "$command" || return 1
	require_common_args "$command" || return 1
	require_no_command_args "$command" || return 1

	local context="$CLI_CONTEXT" namespace="$CLI_NAMESPACE" migration_id="$CLI_MIGRATION"
	local deploy_old="$DISCOVERY_DEPLOY" pvc_old="$DISCOVERY_PVC"

	echo ""
	echo "Discovering source for $migration_id..."

	if [[ -z "$deploy_old" ]]; then
		cli_usage_error "$command" "--deploy is required. Specify the old deployment name." || true
		return 1
	fi
	if [[ -z "$pvc_old" ]]; then
		cli_usage_error "$command" "--pvc is required. Specify the old PVC name." || true
		return 1
	fi

	local existing_phase
	existing_phase=$(state_get "$context" "$namespace" "$migration_id" "PHASE" || true)
	local existing_deploy
	existing_deploy=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_OLD" || true)
	if [[ -n "$existing_phase" && -n "$existing_deploy" ]]; then
		log_warn "Existing source state found (phase=$existing_phase)."
		if ! confirm "Re-discover source state?"; then
			log_info "Aborted."
			return
		fi
	fi

	if echo "$pvc_old" | grep -Eiq -- '--.*[0-9]+(ki|mi|gi|ti|pi|ei)-pvc$'; then
		log_warn "PVC name includes a size suffix from the legacy 4.3.x naming bug:"
		printf '       %s\n' "$pvc_old"
		printf '       The 5.0.0 naming format no longer includes this suffix.\n'
		printf '       Confirm this is the OLD PVC, not one created by the new chart.\n'
		if ! confirm "Use this PVC as migration source?"; then
			log_info "Aborted. Re-run with --pvc pointing to the OLD PVC name if you know it."
			exit 1
		fi
	fi

	if ! kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" &>/dev/null; then
		log_error "Deployment $deploy_old not found in $context/$namespace"
		exit 1
	fi

	if ! kubectl get pvc "$pvc_old" -n "$namespace" --context="$context" &>/dev/null; then
		log_error "PVC $pvc_old not found in $context/$namespace"
		exit 1
	fi

	local deployment_pvcs
	deployment_pvcs=$(get_pvcs_from_deploy "$context" "$namespace" "$deploy_old" || true)
	if [[ -n "$deployment_pvcs" ]]; then
		local -a deployment_pvc_names=()
		mapfile -t deployment_pvc_names <<<"$deployment_pvcs"
		if [[ ${#deployment_pvc_names[@]} -gt 1 ]]; then
			log_info "Deployment $deploy_old uses ${#deployment_pvc_names[@]} PVCs; migrating only:"
			printf '       %s\n' "$pvc_old"
		fi
	fi

	local pv_old reclaim_policy_old
	pv_old=$(get_pv_from_pvc "$context" "$namespace" "$pvc_old")
	reclaim_policy_old=$(normalize_reclaim_policy "$(get_pv_reclaim_policy "$context" "$pv_old")")

	local volume_handle_old
	volume_handle_old=$(get_volume_handle "$context" "$pv_old")

	state_set "$context" "$namespace" "$migration_id" "PHASE" "discovered-old"
	state_set "$context" "$namespace" "$migration_id" "CONTEXT" "$context"
	state_set "$context" "$namespace" "$migration_id" "NAMESPACE" "$namespace"
	state_set "$context" "$namespace" "$migration_id" "APP" "$migration_id"
	state_set "$context" "$namespace" "$migration_id" "DEPLOY_OLD" "$deploy_old"
	state_set "$context" "$namespace" "$migration_id" "PVC_OLD" "$pvc_old"
	state_set "$context" "$namespace" "$migration_id" "PV_OLD" "$pv_old"
	state_set "$context" "$namespace" "$migration_id" "RECLAIM_POLICY_OLD" "$reclaim_policy_old"
	state_set "$context" "$namespace" "$migration_id" "VOLUME_HANDLE_OLD" "$volume_handle_old"

	if [[ -n "$volume_handle_old" ]]; then
		local parsed
		parsed=$(parse_volume_handle "$volume_handle_old" "OLD") || true
		if [[ -n "$parsed" ]]; then
			echo "$parsed" | while IFS='=' read -r key value; do
				state_set "$context" "$namespace" "$migration_id" "$key" "$value"
			done
		fi
	fi

	local nfs_direct
	nfs_direct=$(get_nfs_from_pv "$context" "$pv_old") || true
	if [[ -n "$nfs_direct" ]]; then
		echo "$nfs_direct" | while IFS='=' read -r key value; do
			state_set "$context" "$namespace" "$migration_id" "OLD_${key}" "$value"
		done
	fi

	local claim_name vol_in_deploy
	claim_name="$pvc_old"
	vol_in_deploy=$(kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" \
		-o jsonpath="{range .spec.template.spec.volumes[?(@.persistentVolumeClaim.claimName=='$claim_name')]}{.name}{'\n'}{end}" 2>/dev/null) || true

	if [[ -n "$vol_in_deploy" ]]; then
		local mount_old_list=() subpath_old_list=() raw_mount raw_subpath
		while IFS='|' read -r raw_mount raw_subpath; do
			local mount_path="${raw_mount#@}"
			[[ -z "$mount_path" ]] && continue
			mount_old_list+=("$mount_path")
			subpath_old_list+=("${raw_subpath:-}")
		done < <(get_volume_mounts_from_deploy "$context" "$namespace" "$deploy_old" "$vol_in_deploy" 2>/dev/null || true)

		local mount_idx="${#mount_old_list[@]}"
		if [[ "$mount_idx" -eq 0 ]]; then
			log_warn "No volume mounts found for volume $vol_in_deploy"
		else
			state_set_mounts "$context" "$namespace" "$migration_id" "OLD" "$mount_idx" "${mount_old_list[@]}" "${subpath_old_list[@]}"
		fi
	else
		log_warn "Could not find volume name for PVC $pvc_old in deployment $deploy_old"
		local fallback_mount
		fallback_mount=$(get_volume_mounts_from_deploy "$context" "$namespace" "$deploy_old" "$pvc_old" 2>/dev/null | head -1) || true
		if [[ -n "$fallback_mount" ]]; then
			local fb_path="${fallback_mount%%|*}"
			fb_path="${fb_path#@}"
			state_set_mounts "$context" "$namespace" "$migration_id" "OLD" 1 "$fb_path" ""
		fi
	fi

	local nfs_host nfs_share_base pv_uid nfs_path_old
	nfs_host=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST" || true)
	nfs_share_base=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_SHARE_BASE" || true)
	pv_uid=$(state_get "$context" "$namespace" "$migration_id" "OLD_PV_UID" || true)

	if [[ -n "$nfs_host" && -n "$nfs_share_base" ]]; then
		nfs_path_old="${nfs_share_base}/"
		[[ -n "$pv_uid" ]] && nfs_path_old="${nfs_share_base}/${pv_uid}/"
		state_set "$context" "$namespace" "$migration_id" "NFS_PATH_OLD" "$nfs_path_old"
	else
		log_warn "Could not construct NFS path. Set NFS_PATH_OLD manually."
	fi

	local old_total_bytes=0
	if [[ -n "$nfs_host" && -n "${nfs_path_old:-}" ]] && ssh_run "$nfs_host" test -d "$nfs_path_old" 2>/dev/null; then
		old_total_bytes=$(compute_total_size_nfs "$nfs_host" "$nfs_path_old")
	fi
	state_set "$context" "$namespace" "$migration_id" "OLD_TOTAL_SIZE" "$old_total_bytes"

	local policy_summary
	case "$reclaim_policy_old" in
	Delete)
		policy_summary="Delete (backup required before deploying the new chart)"
		;;
	Retain)
		policy_summary="Retain (backup optional)"
		;;
	*)
		policy_summary="$reclaim_policy_old (backup recommended)"
		;;
	esac

	echo ""
	local mount_count_old
	mount_count_old=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_COUNT_OLD" || true)
	mount_count_old="${mount_count_old:-0}"

	echo "Source discovery:"
	printf '  Deployment:      %s\n' "$deploy_old"
	printf '  PVC:             %s\n' "$pvc_old"
	printf '  PV:              %s\n' "$pv_old"
	printf '  Reclaim policy:  %s\n' "$policy_summary"
	printf '  Mounts:          %s\n' "$mount_count_old"
	if [[ -n "${nfs_path_old:-}" ]]; then
		printf '  NFS:             %s:%s\n' "$nfs_host" "$nfs_path_old"
	fi
	printf '  Data:            %s\n' "$(human_size "$old_total_bytes")"
	echo ""

	if [[ "$reclaim_policy_old" == "Delete" ]]; then
		log_warn "Create a verified backup before deploying the new chart."
	elif reclaim_policy_requires_backup "$reclaim_policy_old"; then
		log_warn "Reclaim policy is unknown; create a verified backup before deploying the new chart."
	fi

	log_ok "Source discovery complete."
	printf '  State: %s\n' "$(state_file_path "$context" "$namespace" "$migration_id")"
	echo ""
	echo "Next:"
	if [[ "$reclaim_policy_old" == "Delete" ]]; then
		echo "  1. Run: $SCRIPT_NAME backup -c $context -n $namespace -m $migration_id"
		echo "  2. Apply the new chart 5.0.0 to the cluster."
		echo "  3. Run: $SCRIPT_NAME discover-new -c $context -n $namespace -m $migration_id"
	elif reclaim_policy_requires_backup "$reclaim_policy_old"; then
		echo "  1. Run: $SCRIPT_NAME backup -c $context -n $namespace -m $migration_id"
    echo "  2. Apply the new chart (5.0.0) to the cluster."
		echo "  3. Run: $SCRIPT_NAME discover-new -c $context -n $namespace -m $migration_id"
	else
		echo "  1. Apply the new chart (5.0.0) to the cluster."
		echo "  2. Run: $SCRIPT_NAME discover-new -c $context -n $namespace -m $migration_id"
	fi
}
