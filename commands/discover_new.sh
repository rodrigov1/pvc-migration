cmd_discover_new() {
	local context="" namespace="" migration_id="" deploy_new="" pvc_new=""

	context="$1"
	shift || true
	namespace="$1"
	shift || true
	migration_id="$1"
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--deploy)
			deploy_new="$2"
			shift 2
			;;
		--pvc)
			pvc_new="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			usage
			;;
		esac
	done

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME discover-new <context> <namespace> <migration-id> [--deploy <deploy>] [--pvc <pvc>]"
		exit 1
	fi

	state_require "$context" "$namespace" "$migration_id"

	if [[ -z "$deploy_new" ]]; then
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
		local count
		count=$(echo "$matches" | wc -l)
		if [[ "$count" -gt 1 ]]; then
			local deploy_old
			deploy_old=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_OLD" || true)
			local filtered=""
			if [[ -n "$deploy_old" ]]; then
				filtered=$(echo "$matches" | grep -v "^${deploy_old}$" || true)
			fi
			if [[ -n "$filtered" ]]; then
				count=$(echo "$filtered" | wc -l)
				if [[ "$count" -eq 1 ]]; then
					deploy_new="$filtered"
				else
					log_warn "Multiple deployments match '$migration_id':"
					echo "$filtered"
					deploy_new=$(echo "$filtered" | head -1)
					log_info "Picked: $deploy_new"
					if ! confirm "Use this deployment?"; then
						log_error "Re-run with --deploy to specify the correct deployment."
						exit 1
					fi
				fi
			else
				log_warn "Multiple deployments match '$migration_id':"
				echo "$matches"
				deploy_new=$(echo "$matches" | head -1)
				log_info "Picked: $deploy_new"
				if ! confirm "Use this deployment?"; then
					log_error "Re-run with --deploy to specify the correct deployment."
					exit 1
				fi
			fi
		else
			deploy_new="$matches"
		fi
		log_info "Found new deployment: $deploy_new"
	else
		log_info "Using specified deployment: $deploy_new"
	fi

	if [[ -z "$pvc_new" ]]; then
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
		local count
		count=$(echo "$matches" | wc -l)
		if [[ "$count" -gt 1 ]]; then
			local pvc_old
			pvc_old=$(state_get "$context" "$namespace" "$migration_id" "PVC_OLD" || true)
			local filtered=""
			if [[ -n "$pvc_old" ]]; then
				filtered=$(echo "$matches" | grep -v "^${pvc_old}$" || true)
			fi
			if [[ -n "$filtered" ]]; then
				count=$(echo "$filtered" | wc -l)
				if [[ "$count" -eq 1 ]]; then
					pvc_new="$filtered"
				else
					log_warn "Multiple PVCs match '$migration_id':"
					echo "$filtered"
					pvc_new=$(echo "$filtered" | head -1)
					log_info "Picked: $pvc_new"
					if ! confirm "Use this PVC?"; then
						log_error "Re-run with --pvc to specify the correct PVC."
						exit 1
					fi
				fi
			else
				log_warn "Multiple PVCs match '$migration_id':"
				echo "$matches"
				pvc_new=$(echo "$matches" | head -1)
				log_info "Picked: $pvc_new"
				if ! confirm "Use this PVC?"; then
					log_error "Re-run with --pvc to specify the correct PVC."
					exit 1
				fi
			fi
		else
			pvc_new="$matches"
		fi
		log_info "Found new PVC: $pvc_new"
	else
		log_info "Using specified PVC: $pvc_new"
	fi

	local pv_new
	pv_new=$(get_pv_from_pvc "$context" "$namespace" "$pvc_new")
	log_info "Found new PV: $pv_new"

	local volume_handle_new
	volume_handle_new=$(get_volume_handle "$context" "$pv_new")
	if [[ -z "$volume_handle_new" ]]; then
		log_warn "No CSI volumeHandle found for PV $pv_new. Trying spec.nfs..."
		local nfs_info
		nfs_info=$(get_nfs_from_pv "$context" "$pv_new")
		if [[ -n "$nfs_info" ]]; then
			log_info "NFS info from PV: $nfs_info"
		fi
	else
		log_info "New VolumeHandle: $volume_handle_new"
	fi

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
		state_del "$context" "$namespace" "$migration_id" "MOUNT_NEW"
		state_del "$context" "$namespace" "$migration_id" "SUBPATH_NEW"

		local mount_idx=0 raw_mount raw_subpath
		while IFS='|' read -r raw_mount raw_subpath; do
			local mount_path="${raw_mount#@}"
			[[ -z "$mount_path" ]] && continue
			mount_idx=$((mount_idx + 1))
			log_info "New mount $mount_idx: $mount_path (subPath: ${raw_subpath:-<none>})"
			state_append "$context" "$namespace" "$migration_id" "MOUNT_NEW" "$mount_path"
			state_append "$context" "$namespace" "$migration_id" "SUBPATH_NEW" "${raw_subpath:-}"
		done < <(kubectl get deployment "$deploy_new" -n "$namespace" --context="$context" \
			-o jsonpath="{range .spec.template.spec.containers[0].volumeMounts[?(@.name=='$vol_in_deploy')]}@{.mountPath}|{.subPath}{'\n'}{end}" 2>/dev/null || true)
	else
		log_warn "Could not find volume name for PVC $pvc_new in deployment $deploy_new"
	fi

	local nfs_host nfs_share_base pv_uid nfs_path_new
	nfs_host=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_HOST" || true)
	nfs_share_base=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_SHARE_BASE" || true)
	pv_uid=$(state_get "$context" "$namespace" "$migration_id" "NEW_PV_UID" || true)

	if [[ -n "$nfs_host" && -n "$nfs_share_base" && -n "$pv_uid" ]]; then
		nfs_path_new="${nfs_share_base}/${pv_uid}/"
		state_set "$context" "$namespace" "$migration_id" "NFS_PATH_NEW" "$nfs_path_new"
		log_ok "New NFS path (PV root): $nfs_host:$nfs_path_new"
	else
		log_warn "Could not construct new NFS path. Set NFS_PATH_NEW manually."
	fi

	local nfs_host_old nfs_path_old
	nfs_host_old=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST" || true)
	nfs_path_old=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD" || true)
	if [[ -n "$nfs_host" && -n "$nfs_host_old" && "$nfs_host" != "$nfs_host_old" ]]; then
		log_warn "NFS host changed: $nfs_host_old -> $nfs_host"
		log_warn "Cross-host copy will be required."
	fi

	if [[ -n "$nfs_host" && -n "${nfs_path_new:-}" ]]; then
		if ssh "$nfs_host" "test -d '$nfs_path_new'" 2>/dev/null; then
			log_warn "New NFS path ALREADY EXISTS: $nfs_host:$nfs_path_new"
			log_warn "Contents:"
			ssh "$nfs_host" "ls -lah '$nfs_path_new'" 2>/dev/null || true
			local new_total_bytes
			new_total_bytes=$(compute_total_size_nfs "$nfs_host" "$nfs_path_new")
			state_set "$context" "$namespace" "$migration_id" "NEW_TOTAL_SIZE" "$new_total_bytes"
			log_info "New data size: $(human_size "$new_total_bytes")"
		else
			log_info "New NFS path does not exist yet (expected). Will be created during copy-data."
			state_del "$context" "$namespace" "$migration_id" "NEW_TOTAL_SIZE"
		fi
	fi

	log_ok "discover-new complete for $migration_id in $context/$namespace"
	echo ""
	echo "===== Next steps ====="
	echo "1. Run: $SCRIPT_NAME copy-data $context $namespace $migration_id"
}