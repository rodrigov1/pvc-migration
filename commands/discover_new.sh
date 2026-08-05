cmd_discover_new() {
	local command="discover-new"
	parse_common_args "$command" "$@" || return 1
	parse_discovery_args "$command" || return 1
	require_common_args "$command" || return 1
	require_no_command_args "$command" || return 1

	local context="$CLI_CONTEXT" namespace="$CLI_NAMESPACE" migration_id="$CLI_MIGRATION"
	local deploy_new="$DISCOVERY_DEPLOY" pvc_new="$DISCOVERY_PVC"
	local deploy_auto=false pvc_auto=false

	echo ""
	echo "Discovering destination for $migration_id..."

	state_require "$context" "$namespace" "$migration_id"
	state_del "$context" "$namespace" "$migration_id" "MOUNT_NEW"
	state_del "$context" "$namespace" "$migration_id" "SUBPATH_NEW"
	state_del "$context" "$namespace" "$migration_id" "MOUNT_COUNT_NEW"
	state_del_prefix "$context" "$namespace" "$migration_id" "MOUNT_NEW_"
	state_del_prefix "$context" "$namespace" "$migration_id" "SUBPATH_NEW_"

	local reclaim_policy_old old_phase
	reclaim_policy_old=$(state_get "$context" "$namespace" "$migration_id" "RECLAIM_POLICY_OLD" || true)
	old_phase=$(state_get "$context" "$namespace" "$migration_id" "PHASE" || true)
	reclaim_policy_warn_if_backup_missing "$reclaim_policy_old" "$old_phase"

	if [[ -z "$deploy_new" ]]; then
		deploy_auto=true
		local matches
		matches=$(get_deployments_by_pattern "$context" "$namespace" "$migration_id")
		if [[ -z "$matches" ]]; then
			log_error "No deployments found matching '$migration_id' in $context/$namespace"
			log_info "Available deployments:"
			kubectl get deployments -n "$namespace" --context="$context" \
				-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
				while IFS= read -r d; do echo "  - $d"; done
			log_error "Re-run with --deploy <name> to specify the correct deployment."
			exit 1
		fi
		local deploy_candidates="$matches"
		local deploy_old
		deploy_old=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_OLD" || true)
		if [[ -n "$deploy_old" ]]; then
			deploy_candidates=$(echo "$matches" | grep -v "^${deploy_old}$" || true)
		fi
		if [[ -z "$deploy_candidates" ]]; then
			deploy_candidates="$matches"
		fi

		local count
		count=$(printf '%s\n' "$deploy_candidates" | wc -l)
		if [[ "$count" -gt 1 ]]; then
			log_error "Multiple deployments match '$migration_id':"
			printf '%s\n' "$deploy_candidates" | while IFS= read -r candidate; do
				printf '  - %s\n' "$candidate"
			done
			log_error "Re-run with --deploy <deployment> to specify the correct resource."
			return 1
		else
			deploy_new="$deploy_candidates"
		fi
	fi

	if [[ -z "$pvc_new" ]]; then
		pvc_auto=true
		local matches
		matches=$(get_pvcs_by_pattern "$context" "$namespace" "$migration_id")
		if [[ -z "$matches" ]]; then
			log_error "No PVCs found matching '$migration_id' in $context/$namespace"
			log_info "Available PVCs:"
			kubectl get pvc -n "$namespace" --context="$context" \
				-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
				while IFS= read -r p; do echo "  - $p"; done
			log_error "Re-run with --pvc <name> to specify the correct PVC."
			exit 1
		fi
		local pvc_candidates="$matches"
		local pvc_old
		pvc_old=$(state_get "$context" "$namespace" "$migration_id" "PVC_OLD" || true)
		if [[ -n "$pvc_old" ]]; then
			pvc_candidates=$(echo "$matches" | grep -v "^${pvc_old}$" || true)
		fi
		if [[ -z "$pvc_candidates" ]]; then
			pvc_candidates="$matches"
		fi

		local count
		count=$(printf '%s\n' "$pvc_candidates" | wc -l)
		if [[ "$count" -gt 1 ]]; then
			log_error "Multiple PVCs match '$migration_id':"
			printf '%s\n' "$pvc_candidates" | while IFS= read -r candidate; do
				printf '  - %s\n' "$candidate"
			done
			log_error "Re-run with --pvc <pvc> to specify the correct resource."
			return 1
		else
			pvc_new="$pvc_candidates"
		fi
	fi

	local pv_new
	pv_new=$(get_pv_from_pvc "$context" "$namespace" "$pvc_new")

	local volume_handle_new
	volume_handle_new=$(get_volume_handle "$context" "$pv_new")

	local nfs_direct_new
	nfs_direct_new=$(get_nfs_from_pv "$context" "$pv_new") || true
	if [[ -n "$nfs_direct_new" ]]; then
		echo "$nfs_direct_new" | while IFS='=' read -r key value; do
			state_set "$context" "$namespace" "$migration_id" "NEW_${key}" "$value"
		done
	fi

	state_set "$context" "$namespace" "$migration_id" "PHASE" "discovered-new"
	state_set "$context" "$namespace" "$migration_id" "DEPLOY_NEW" "$deploy_new"
	state_set "$context" "$namespace" "$migration_id" "PVC_NEW" "$pvc_new"
	state_set "$context" "$namespace" "$migration_id" "PV_NEW" "$pv_new"
	state_set "$context" "$namespace" "$migration_id" "VOLUME_HANDLE_NEW" "$volume_handle_new"

	if [[ -n "$volume_handle_new" ]]; then
		local parsed
		parsed=$(parse_volume_handle "$volume_handle_new" "NEW") || true
		if [[ -n "$parsed" ]]; then
			echo "$parsed" | while IFS='=' read -r key value; do
				state_set "$context" "$namespace" "$migration_id" "$key" "$value"
			done
		fi
	fi

	local claim_name vol_in_deploy
	claim_name="$pvc_new"
	vol_in_deploy=$(kubectl get deployment "$deploy_new" -n "$namespace" --context="$context" \
		-o jsonpath="{range .spec.template.spec.volumes[?(@.persistentVolumeClaim.claimName=='$claim_name')]}{.name}{'\n'}{end}" 2>/dev/null) || true

	if [[ -n "$vol_in_deploy" ]]; then
		local mount_new_list=() subpath_new_list=() raw_mount raw_subpath
		while IFS='|' read -r raw_mount raw_subpath; do
			local mount_path="${raw_mount#@}"
			[[ -z "$mount_path" ]] && continue
			mount_new_list+=("$mount_path")
			subpath_new_list+=("${raw_subpath:-}")
		done < <(get_volume_mounts_from_deploy "$context" "$namespace" "$deploy_new" "$vol_in_deploy" 2>/dev/null || true)

		local mount_idx="${#mount_new_list[@]}"
		if [[ "$mount_idx" -gt 0 ]]; then
			state_set_mounts "$context" "$namespace" "$migration_id" "NEW" "$mount_idx" "${mount_new_list[@]}" "${subpath_new_list[@]}"
		fi
	else
		log_warn "Could not find volume name for PVC $pvc_new in deployment $deploy_new"
	fi

	local nfs_host nfs_share_base pv_uid nfs_path_new
	nfs_host=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_HOST" || true)
	nfs_share_base=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_SHARE_BASE" || true)
	pv_uid=$(state_get "$context" "$namespace" "$migration_id" "NEW_PV_UID" || true)

	if [[ -n "$nfs_host" && -n "$nfs_share_base" ]]; then
		nfs_path_new="${nfs_share_base}/"
		[[ -n "$pv_uid" ]] && nfs_path_new="${nfs_share_base}/${pv_uid}/"
		state_set "$context" "$namespace" "$migration_id" "NFS_PATH_NEW" "$nfs_path_new"
	else
		log_warn "Could not construct new NFS path. Set NFS_PATH_NEW manually."
	fi

	local nfs_host_old nfs_path_old
	nfs_host_old=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST" || true)
	nfs_path_old=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD" || true)
	if [[ -n "$nfs_host" && -n "$nfs_host_old" && "$nfs_host" != "$nfs_host_old" ]]; then
		log_info "Transfer will run across NFS hosts:"
		printf '       %s -> %s\n' "$nfs_host_old" "$nfs_host"
	fi

	local destination_status="unknown"
	if [[ -n "$nfs_host" && -n "${nfs_path_new:-}" ]]; then
		if ssh_run "$nfs_host" test -d "$nfs_path_new" 2>/dev/null; then
			local new_total_bytes
			new_total_bytes=$(compute_total_size_nfs "$nfs_host" "$nfs_path_new")
			state_set "$context" "$namespace" "$migration_id" "NEW_TOTAL_SIZE" "$new_total_bytes"
			destination_status="exists ($(human_size "$new_total_bytes"))"
			if [[ "$new_total_bytes" != "0" ]]; then
				log_warn "Destination already contains data ($(human_size "$new_total_bytes"))."
				log_warn "copy-data will require confirmation before replacing it."
			else
				log_info "Destination path already exists and is empty."
			fi
		else
			destination_status="not created yet"
			state_del "$context" "$namespace" "$migration_id" "NEW_TOTAL_SIZE"
		fi
	fi

	local deployment_pvcs pvc_count=0
	deployment_pvcs=$(get_pvcs_from_deploy "$context" "$namespace" "$deploy_new" || true)
	if [[ -n "$deployment_pvcs" ]]; then
		local -a deployment_pvc_names=()
		mapfile -t deployment_pvc_names <<<"$deployment_pvcs"
		pvc_count="${#deployment_pvc_names[@]}"
		if [[ "$pvc_count" -gt 1 ]]; then
			log_info "Deployment $deploy_new uses $pvc_count PVCs; migrating only:"
			printf '       %s\n' "$pvc_new"
		fi
	fi

	local mount_count_old mount_count_new
	mount_count_old=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_COUNT_OLD" || true)
	mount_count_new=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_COUNT_NEW" || true)
	mount_count_old="${mount_count_old:-0}"
	mount_count_new="${mount_count_new:-0}"
	if [[ "$mount_count_old" != "$mount_count_new" ]]; then
		log_warn "Mount count differs from the source:"
		printf '       Source:      %s\n' "$mount_count_old"
		printf '       Destination: %s\n' "$mount_count_new"
		log_warn "copy-data will refuse to continue until the mount sets match."
	fi

	local deploy_label="$deploy_new" pvc_label="$pvc_new"
	if $deploy_auto; then
		deploy_label+=" (auto-discovered)"
	fi
	if $pvc_auto; then
		pvc_label+=" (auto-discovered)"
	fi

	echo ""
	echo "Destination discovery:"
	printf '  Deployment:   %s\n' "$deploy_label"
	printf '  PVC:          %s\n' "$pvc_label"
	printf '  PV:           %s\n' "$pv_new"
	printf '  Mounts:       %s\n' "$mount_count_new"
	if [[ -n "${nfs_path_new:-}" ]]; then
		printf '  NFS:          %s:%s\n' "$nfs_host" "$nfs_path_new"
	fi
	printf '  Destination:  %s\n' "$destination_status"

	echo ""
	log_ok "Destination discovery complete."
	printf '  State: %s\n' "$(state_file_path "$context" "$namespace" "$migration_id")"
	echo ""
	echo "Next:"
	echo "  Run: $SCRIPT_NAME copy-data -c $context -n $namespace -m $migration_id"
}
