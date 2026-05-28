cmd_discover_old() {
	local context="" namespace="" migration_id="" deploy_old="" pvc_old=""

	context="$1"
	shift || true
	namespace="$1"
	shift || true
	migration_id="$1"
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--deploy)
			deploy_old="$2"
			shift 2
			;;
		--pvc)
			pvc_old="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			usage
			;;
		esac
	done

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME discover-old <context> <namespace> <migration-id> --deploy <deploy> --pvc <pvc>"
		exit 1
	fi

	if [[ -z "$deploy_old" ]]; then
		log_error "--deploy is required. Specify the old deployment name."
		usage
	fi
	if [[ -z "$pvc_old" ]]; then
		log_error "--pvc is required. Specify the old PVC name."
		usage
	fi

	local existing_phase
	existing_phase=$(state_get "$context" "$namespace" "$migration_id" "PHASE" || true)
	local existing_deploy
	existing_deploy=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_OLD" || true)
	if [[ -n "$existing_phase" && -n "$existing_deploy" ]]; then
		log_info "Existing state found (phase=$existing_phase). Add --force to re-discover."
		if ! confirm "Re-discover old state?"; then
			log_info "Aborted."
			return
		fi
	fi

	if echo "$pvc_old" | grep -q -- '--.*pvc$'; then
		log_warn "========================================================================="
		log_warn "PVC '$pvc_old' looks like a 4.3.2 naming pattern (*--*pvc)."
		log_warn "If the new chart has already been synced, this discover-old is CAPTURING"
		log_warn "THE NEW STATE as if it were the old state, which is incorrect."
		log_warn "========================================================================="
		if echo "$pvc_old" | grep -q -- '--.*[0-9]\+gi.*pvc$'; then
			log_warn "PVC name contains a size suffix (e.g. '15gi'), confirming 4.3.2 pattern."
		fi
		if ! confirm "Continue anyway?"; then
			log_info "Aborted. Re-run with --pvc pointing to the OLD PVC name if you know it."
			exit 1
		fi
	fi

	log_info "Verifying deployment $deploy_old ..."
	if ! kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" &>/dev/null; then
		log_error "Deployment $deploy_old not found in $context/$namespace"
		exit 1
	fi

	log_info "Verifying PVC $pvc_old ..."
	if ! kubectl get pvc "$pvc_old" -n "$namespace" --context="$context" &>/dev/null; then
		log_error "PVC $pvc_old not found in $context/$namespace"
		exit 1
	fi

	local pv_old
	pv_old=$(get_pv_from_pvc "$context" "$namespace" "$pvc_old")
	log_info "Found PV: $pv_old"

	local volume_handle_old
	volume_handle_old=$(get_volume_handle "$context" "$pv_old")
	if [[ -z "$volume_handle_old" ]]; then
		log_warn "No CSI volumeHandle found for PV $pv_old. Trying spec.nfs..."
		local nfs_info
		nfs_info=$(get_nfs_from_pv "$context" "$pv_old")
		log_info "NFS info from PV: $nfs_info"
	else
		log_info "VolumeHandle: $volume_handle_old"
	fi

	state_set "$context" "$namespace" "$migration_id" "PHASE" "discovered-old"
	state_set "$context" "$namespace" "$migration_id" "CONTEXT" "$context"
	state_set "$context" "$namespace" "$migration_id" "NAMESPACE" "$namespace"
	state_set "$context" "$namespace" "$migration_id" "APP" "$migration_id"
	state_set "$context" "$namespace" "$migration_id" "DEPLOY_OLD" "$deploy_old"
	state_set "$context" "$namespace" "$migration_id" "PVC_OLD" "$pvc_old"
	state_set "$context" "$namespace" "$migration_id" "PV_OLD" "$pv_old"
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
		log_info "Found volume in deployment: $vol_in_deploy"
		state_del "$context" "$namespace" "$migration_id" "MOUNT_OLD"
		state_del "$context" "$namespace" "$migration_id" "SUBPATH_OLD"

		local mount_idx=0 raw_mount raw_subpath
		while IFS='|' read -r raw_mount raw_subpath; do
			local mount_path="${raw_mount#@}"
			[[ -z "$mount_path" ]] && continue
			mount_idx=$((mount_idx + 1))
			log_info "Mount $mount_idx: $mount_path (subPath: ${raw_subpath:-<none>})"
			state_append "$context" "$namespace" "$migration_id" "MOUNT_OLD" "$mount_path"
			state_append "$context" "$namespace" "$migration_id" "SUBPATH_OLD" "${raw_subpath:-}"
		done < <(kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" \
			-o jsonpath="{range .spec.template.spec.containers[0].volumeMounts[?(@.name=='$vol_in_deploy')]}@{.mountPath}|{.subPath}{'\n'}{end}" 2>/dev/null || true)

		if [[ "$mount_idx" -eq 0 ]]; then
			log_warn "No volume mounts found for volume $vol_in_deploy"
		else
			log_info "Total mounts captured: $mount_idx"
		fi
	else
		log_warn "Could not find volume name for PVC $pvc_old in deployment $deploy_old"
		local fallback_mount
		fallback_mount=$(kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" \
			-o jsonpath="{range .spec.template.spec.containers[0].volumeMounts[?(@.name=='$pvc_old')]}@{.mountPath}|{.subPath}{'\n'}{end}" 2>/dev/null | head -1) || true
		if [[ -n "$fallback_mount" ]]; then
			local fb_path="${fallback_mount%%|*}"
			fb_path="${fb_path#@}"
			log_info "Fallback mount: $fb_path"
			state_set "$context" "$namespace" "$migration_id" "MOUNT_OLD" "$fb_path"
		fi
	fi

	local nfs_host nfs_share_base pv_uid nfs_path_old
	nfs_host=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST" || true)
	nfs_share_base=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_SHARE_BASE" || true)
	pv_uid=$(state_get "$context" "$namespace" "$migration_id" "OLD_PV_UID" || true)

	if [[ -n "$nfs_host" && -n "$nfs_share_base" && -n "$pv_uid" ]]; then
		nfs_path_old="${nfs_share_base}/${pv_uid}/"
		state_set "$context" "$namespace" "$migration_id" "NFS_PATH_OLD" "$nfs_path_old"
		log_ok "Old NFS path (PV root): $nfs_host:$nfs_path_old"
	else
		log_warn "Could not construct NFS path. Set NFS_PATH_OLD manually."
		log_info "  nfs_host=$nfs_host"
		log_info "  nfs_share_base=$nfs_share_base"
		log_info "  pv_uid=$pv_uid"
	fi

	local manifest_base="$STATE_BASE/$context/$namespace/${migration_id}.old.manifest"
	local pod_name
	pod_name=$(get_pod_for_deploy "$context" "$namespace" "$deploy_old")

	if [[ -n "$pod_name" ]]; then
		local mounts_str
		mounts_str=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_OLD" || true)
		if [[ -n "$mounts_str" ]]; then
			local mnt_idx=0 pids=()
			while IFS= read -r single_mount; do
				[[ -z "$single_mount" ]] && continue
				mnt_idx=$((mnt_idx + 1))
				local per_mount_manifest="${manifest_base}.${mnt_idx}"
				capture_file_manifest "$context" "$namespace" "$pod_name" "$single_mount" "$per_mount_manifest" 2>/dev/null || true &
				pids+=($!)
			done <<< "$(echo "$mounts_str" | sed 's/__/\n/g')"
			for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
			log_info "All per-mount manifests captured (${#pids[@]} total)."
		fi
	else
		log_info "No running pod — capturing combined NFS manifest (needed for validate)."
		if [[ -n "$nfs_host" && -n "${nfs_path_old:-}" ]] && ssh "$nfs_host" "test -d '$nfs_path_old'" 2>/dev/null; then
			capture_file_manifest_nfs "$nfs_host" "$nfs_path_old" "$manifest_base" 2>/dev/null || true
		fi
	fi

	local old_total_bytes=0
	if [[ -n "$nfs_host" && -n "${nfs_path_old:-}" ]] && ssh "$nfs_host" "test -d '$nfs_path_old'" 2>/dev/null; then
		old_total_bytes=$(compute_total_size_nfs "$nfs_host" "$nfs_path_old")
	elif [[ -f "${manifest_base}.1" ]]; then
		for mf in "$manifest_base".*; do
			local sz
			sz=$(compute_total_size_manifest "$mf")
			old_total_bytes=$((old_total_bytes + sz))
		done
	elif [[ -f "$manifest_base" ]]; then
		old_total_bytes=$(compute_total_size_manifest "$manifest_base")
	fi
	state_set "$context" "$namespace" "$migration_id" "OLD_TOTAL_SIZE" "$old_total_bytes"
	log_info "Old data size: $(human_size "$old_total_bytes")"

	log_ok "discover-old complete for $migration_id in $context/$namespace"
	log_info "State file: $(state_file_path "$context" "$namespace" "$migration_id")"
	echo ""
	echo "===== Next steps ====="
	echo "1. Review the state file and correct any values if needed."
	echo "2. Apply the new chart (4.3.2) to the cluster."
	echo "3. Run: $SCRIPT_NAME discover-new $context $namespace $migration_id"
}