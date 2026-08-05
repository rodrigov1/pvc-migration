COPY_RESULT_CODE=""

read_copy_result_code() {
	local result_file="$1" result_line

	if [[ ! -f "$result_file" ]]; then
		return 1
	fi
	if ! result_line=$(awk 'NF { count++; line=$0 } END { if (count != 1) exit 1; print line }' "$result_file"); then
		return 1
	fi
	if [[ ! "$result_line" =~ ^exit_code=[0-9]+$ ]]; then
		return 1
	fi

	COPY_RESULT_CODE="${result_line#exit_code=}"
}

run_copy_job() {
	local tmp_script="$1" result_file="$2" copy_failed=false

	if ! bash "$tmp_script"; then
		copy_failed=true
	fi

	if ! read_copy_result_code "$result_file"; then
		log_error "Copy result file is missing or invalid."
		copy_failed=true
	elif [[ "$COPY_RESULT_CODE" != "0" ]]; then
		log_error "Copy script failed with exit code $COPY_RESULT_CODE."
		copy_failed=true
	fi

	if $copy_failed; then
		return 1
	fi
}

cmd_copy_data() {
	local command="copy-data"
	parse_common_args "$command" "$@" || return 1
	parse_copy_args "$command" || return 1
	require_common_args "$command" || return 1

	local context="$CLI_CONTEXT" namespace="$CLI_NAMESPACE" migration_id="$CLI_MIGRATION"
	local use_compress="$COPY_COMPRESS"

	state_require "$context" "$namespace" "$migration_id"

	local depl_old depl_new nfs_host_old nfs_path_old nfs_host_new nfs_path_new
	depl_old=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_OLD")
	depl_new=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_NEW")
	nfs_host_old=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST")
	nfs_path_old=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD")
	nfs_host_new=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_HOST")
	nfs_path_new=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_NEW")

	local backup_root backup_base reclaim_policy_old backup_generation
	backup_root="$(dirname "$nfs_path_old")/${migration_id}-backup"
	backup_base=$(state_get "$context" "$namespace" "$migration_id" "BACKUP_BASE_OLD" || true)
	reclaim_policy_old=$(state_get "$context" "$namespace" "$migration_id" "RECLAIM_POLICY_OLD" || true)
	backup_generation=$(state_get "$context" "$namespace" "$migration_id" "BACKUP_VERIFY_OLD_GENERATION" || true)
	if [[ -z "$backup_base" ]]; then
		if verification_find_current_backup "$nfs_host_old" "$backup_root" 2>/dev/null; then
			backup_base="$RECOVERED_BACKUP_BASE"
		fi
	fi
	if [[ -n "$backup_base" ]] && ssh_run "$nfs_host_old" test -d "$backup_base" 2>/dev/null; then
		if ! verification_hydrate_backup_state "$context" "$namespace" "$migration_id" \
			"$nfs_host_old" "$backup_base"; then
			log_error "Selected backup metadata conflicts with state or its source baseline is missing."
			return 1
		fi
		backup_generation="$BACKUP_METADATA_GENERATION"
	fi

	local missing=false
	for var in depl_old depl_new nfs_host_old nfs_path_old nfs_host_new nfs_path_new; do
		if [[ -z "${!var}" ]]; then
			log_error "Missing state: $var"
			missing=true
		fi
	done
	if $missing; then
		log_error "Run 'discover-old' and 'discover-new' first, or set missing values manually."
		exit 1
	fi

	local -a workloads=()
	for deployment in "$depl_old" "$depl_new"; do
		[[ -n "$deployment" ]] || continue
		if kubectl get deployment "$deployment" -n "$namespace" --context="$context" &>/dev/null; then
			if [[ ! " ${workloads[*]} " == *" $deployment "* ]]; then
				workloads+=("$deployment")
			fi
		fi
	done

	local mount_old_list=() subpath_old_list=() mount_new_list=() subpath_new_list=()
	state_get_mounts "$context" "$namespace" "$migration_id" "OLD"
	mount_old_list=("${MOUNTS_LIST[@]}")
	subpath_old_list=("${SUBPATHS_LIST[@]}")
	local mount_count="$MOUNT_COUNT"
	state_get_mounts "$context" "$namespace" "$migration_id" "NEW"
	mount_new_list=("${MOUNTS_LIST[@]}")
	subpath_new_list=("${SUBPATHS_LIST[@]}")
	local mount_count_new="$MOUNT_COUNT"

	if [[ "${#mount_old_list[@]}" -ne "$mount_count" ||
		"${#subpath_old_list[@]}" -ne "$mount_count" ||
		"${#mount_new_list[@]}" -ne "$mount_count_new" ||
		"${#subpath_new_list[@]}" -ne "$mount_count_new" ||
		"$mount_count" -ne "$mount_count_new" ]]; then
		log_error "Mount count differs:"
		printf '        Source:      %s\n' "$mount_count"
		printf '        Destination: %s\n' "$mount_count_new"
		log_error "Run discover-new again after correcting the destination mounts."
		return 1
	fi

	local source_available=false restore_mode=false
	if ssh_run "$nfs_host_old" test -d "$nfs_path_old" 2>/dev/null; then
		source_available=true
	fi
	if [[ "$reclaim_policy_old" == "Delete" && -n "$backup_base" ]] &&
		ssh_run "$nfs_host_old" test -d "$backup_base" 2>/dev/null; then
		source_available=false
		restore_mode=true
	fi
	if ! $source_available && ! $restore_mode; then
		if [[ -n "$backup_base" ]] && ssh_run "$nfs_host_old" test -d "$backup_base" 2>/dev/null; then
			restore_mode=true
		else
			log_error "Source NFS path is unavailable and no verified backup was found."
			return 1
		fi
	fi

	if $source_available; then
		if ! verification_preflight_remote "$nfs_host_old" "$nfs_path_old"; then
			log_error "Old NFS host is not ready for baseline verification."
			return 1
		fi
	else
		if ! verification_preflight_remote "$nfs_host_old" "$backup_base"; then
			log_error "Old NFS host is not ready for backup restore verification."
			return 1
		fi
	fi

	if ! ssh_run "$nfs_host_new" test -d "$(dirname "$nfs_path_new")" 2>/dev/null; then
		log_error "Cannot access destination NFS parent:"
		printf '        %s:%s\n' "$nfs_host_new" "$(dirname "$nfs_path_new")"
		return 1
	fi
	if ! verification_preflight_remote "$nfs_host_new" "$(dirname "$nfs_path_new")"; then
		log_error "New NFS host is not ready for baseline verification."
		return 1
	fi

	local new_has_data=false new_total_bytes=0 destination_status="not created yet"
	if ssh_run "$nfs_host_new" test -d "$nfs_path_new" 2>/dev/null; then
		if ssh_bash "$nfs_host_new" 'find "$1" -mindepth 1 -maxdepth 1 -printf 1 -quit' "$nfs_path_new" 2>/dev/null | grep -q .; then
			new_has_data=true
			new_total_bytes=$(compute_total_size_nfs "$nfs_host_new" "$nfs_path_new")
			destination_status="contains data ($(human_size "$new_total_bytes"))"
		else
			destination_status="empty"
		fi
	fi

	if $restore_mode; then
		local current_old_generation backup_mount_count
		current_old_generation=$(state_get "$context" "$namespace" "$migration_id" "VERIFY_OLD_GENERATION" || true)
		if [[ -z "$backup_generation" || "$current_old_generation" != "$backup_generation" ]]; then
			log_error "The source baseline generation does not match the selected backup."
			return 1
		fi
		backup_mount_count=$(state_get "$context" "$namespace" "$migration_id" "BACKUP_MOUNT_COUNT" || true)
		if [[ "$backup_mount_count" != "$mount_count" ]]; then
			log_error "Selected backup mount count does not match the migration state."
			return 1
		fi
		if ! verification_check_backup_archives "$context" "$namespace" "$migration_id" \
			"$nfs_host_old" "$backup_base" "$mount_count"; then
			return 1
		fi
		log_info "Backup metadata and archives verified."
	fi

	local old_total_bytes source_summary mode_summary compression_summary
	old_total_bytes=$(state_get "$context" "$namespace" "$migration_id" "OLD_TOTAL_SIZE" || true)
	old_total_bytes="${old_total_bytes:-0}"
	if $restore_mode; then
		source_summary="verified backup: $nfs_host_old:$backup_base"
		mode_summary="backup restore"
	else
		source_summary="$nfs_host_old:$nfs_path_old"
		mode_summary="live source"
	fi
	if [[ "$use_compress" == true ]]; then
		compression_summary="enabled"
	else
		compression_summary="disabled"
	fi

	echo ""
	echo "Copy summary:"
	printf '  Source:       %s\n' "$source_summary"
	printf '  Destination:  %s:%s\n' "$nfs_host_new" "$nfs_path_new"
	if [[ "${#workloads[@]}" -gt 0 ]]; then
		printf '  Workloads:    %s\n' "${workloads[*]}"
	else
		printf '  Workloads:    none found\n'
	fi
	printf '  Mounts:       %s\n' "$mount_count"
	printf '  Data:         %s\n' "$(human_size "$old_total_bytes")"
	printf '  Mode:         %s\n' "$mode_summary"
	printf '  Compression:  %s\n' "$compression_summary"
	printf '  Destination:  %s\n' "$destination_status"

	echo ""
	log_info "Preflight checks passed."
	if [[ "${#workloads[@]}" -gt 0 ]]; then
		log_warn "Workload(s) ${workloads[*]} will be scaled to 0."
	else
		log_warn "No workloads found; nothing will be scaled down."
	fi
	if $new_has_data; then
		log_warn "Existing destination data will be replaced."
	fi
	if ! confirm "Stop workloads and start the copy?"; then
		log_info "Aborted. No workloads were modified."
		return
	fi

	log_info "Preparing destination directories..."
	for ((i = 0; i < mount_count; i++)); do
		local ns="${subpath_new_list[$i]}"
		local dst="${nfs_path_new}${ns:+${ns}/}"
		ssh_run "$nfs_host_new" mkdir -p "$dst" 2>/dev/null || {
			log_error "Failed to create destination directory: $dst"
			return 1
		}
	done
	log_ok "Destination directories ready."

	state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "pending"
	state_set "$context" "$namespace" "$migration_id" "PHASE" "copy-in-progress"

	local workflow_start_time
	workflow_start_time=$(date +%s)
	for deployment in "${workloads[@]}"; do
		if ! kubectl scale deployment "$deployment" --replicas=0 -n "$namespace" --context="$context" 2>/dev/null; then
			log_error "Could not scale down $deployment."
			return 1
		fi
	done
	for deployment in "${workloads[@]}"; do
		if ! wait_for_deployment_pods_zero "$context" "$namespace" "$deployment" 60 "" true; then
			return 1
		fi
	done
	if [[ "${#workloads[@]}" -gt 0 ]]; then
		log_ok "Workloads stopped."
	fi

	if $source_available; then
		log_info "Capturing source baseline ($mount_count mount(s))..."
		if ! verification_capture_side "$context" "$namespace" "$migration_id" OLD \
			"$nfs_host_old" "$nfs_path_old" true; then
			state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
			return 1
		fi
		log_ok "Source baseline captured."
	elif ! verification_side_ready "$context" "$namespace" "$migration_id" OLD; then
		log_error "Source baseline manifests are missing; run backup before restore."
		state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
		return 1
	fi

	local progress_cmd="cat"
	if command -v pv &>/dev/null; then
		progress_cmd="pv -trab"
	fi
	if $new_has_data; then
		log_info "Clearing existing destination data..."
		for ((i = 0; i < mount_count; i++)); do
			local clean_subpath="${subpath_new_list[$i]}"
			local clean_dst="${nfs_path_new}${clean_subpath:+${clean_subpath}/}"
			if ! ssh_bash "$nfs_host_new" \
				'[[ -n "$1" && "$1" != / ]] || exit 64; find -P "$1" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' \
				"$clean_dst"; then
				state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
				state_set "$context" "$namespace" "$migration_id" "PHASE" "copy-failed"
				log_error "Could not clean destination mount path: $clean_dst"
				return 1
			fi
		done
	fi

	local tmp_script result_file
	tmp_script=$(mktemp "/tmp/pvc-mig-copy-XXXXXX.sh")
	result_file=$(mktemp "/tmp/pvc-mig-copy-result-XXXXXX")
	{
		echo '#!/bin/bash'
		echo 'set -euo pipefail'
		echo "source $(printf '%q' "$SCRIPT_DIR/lib/remote.sh")"
		echo "result_file=$(printf '%q' "$result_file")"
		echo 'trap '\''status=$?; printf "exit_code=%s\n" "$status" > "$result_file" || true; trap - EXIT; exit "$status"'\'' EXIT'
		echo ''
		echo "nfs_host_old=$(printf '%q' "$nfs_host_old")"
		echo "nfs_host_new=$(printf '%q' "$nfs_host_new")"
		echo "nfs_path_old=$(printf '%q' "$nfs_path_old")"
		echo "nfs_path_new=$(printf '%q' "$nfs_path_new")"
		echo "backup_base=$(printf '%q' "$backup_base")"
		echo "restore_mode=$restore_mode"
		echo "progress_cmd=$(printf '%q' "$progress_cmd")"
		echo "mount_count=$mount_count"
		echo ''
		echo "subpath_old_list=($(for v in "${subpath_old_list[@]}"; do printf '%q ' "$v"; done))"
		echo "subpath_new_list=($(for v in "${subpath_new_list[@]}"; do printf '%q ' "$v"; done))"
		echo "mount_labels=($(for v in "${mount_old_list[@]}"; do printf '%q ' "$v"; done))"
		echo ''
		echo 'for ((i = 0; i < mount_count; i++)); do'
		echo '  old_sub="${subpath_old_list[$i]}"'
		echo '  new_sub="${subpath_new_list[$i]}"'
		echo '  src="${nfs_path_old}${old_sub:+${old_sub}/}"'
		echo '  dst="${nfs_path_new}${new_sub:+${new_sub}/}"'
		echo '  mount_label="${mount_labels[$i]:-<root>}"'
		if $restore_mode; then
			echo '  printf "[%d/%d] Restoring %s...\n" "$((i+1))" "$mount_count" "$mount_label"'
			echo '  if ! ssh_run "$nfs_host_old" cat -- "${backup_base}/${i}.tgz" | eval "$progress_cmd" | ssh_bash "$nfs_host_new" '\''exec tar --numeric-owner --same-owner --same-permissions --sparse --gzip -xpf - --directory="$1"'\'' "$dst"; then'
		else
			echo '  printf "[%d/%d] Copying %s...\n" "$((i+1))" "$mount_count" "$mount_label"'
			if $use_compress; then
				echo '  if ! ssh_bash "$nfs_host_old" '\''exec tar --format=pax --numeric-owner --sparse --gzip -cpf - --directory="$1" .'\'' "$src" | eval "$progress_cmd" | ssh_bash "$nfs_host_new" '\''exec tar --numeric-owner --same-owner --same-permissions --sparse --gzip -xpf - --directory="$1"'\'' "$dst"; then'
			else
				echo '  if ! ssh_bash "$nfs_host_old" '\''exec tar --format=pax --numeric-owner --sparse -cpf - --directory="$1" .'\'' "$src" | eval "$progress_cmd" | ssh_bash "$nfs_host_new" '\''exec tar --numeric-owner --same-owner --same-permissions --sparse -xpf - --directory="$1"'\'' "$dst"; then'
			fi
		fi
		echo '    echo "[ERROR] Copy failed for mount $((i+1))"'
		echo '    exit 1'
		echo '  fi'
		echo 'done'
	} > "$tmp_script"
	chmod +x "$tmp_script"

	local copy_failed=false
	if ! run_copy_job "$tmp_script" "$result_file"; then
		copy_failed=true
	fi
	if ! $copy_failed; then
		log_info "Verifying destination ($mount_count mount(s))..."
		if ! verification_capture_side "$context" "$namespace" "$migration_id" NEW \
			"$nfs_host_new" "$nfs_path_new" true ||
			! verification_compare_sides "$context" "$namespace" "$migration_id"; then
			copy_failed=true
		else
			log_ok "Content and metadata verification passed."
		fi
	fi

	local end_time elapsed
	end_time=$(date +%s)
	elapsed=$((end_time - workflow_start_time))
	rm -f "$tmp_script" "$result_file"

	if $copy_failed; then
		state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
		state_set "$context" "$namespace" "$migration_id" "PHASE" "copy-failed"
		state_set "$context" "$namespace" "$migration_id" "COPY_ERROR_TIMESTAMP" "$(date -Iseconds)"
		log_error "Data copy failed. Destination was not marked as copied."
		return 1
	fi

	state_set "$context" "$namespace" "$migration_id" "PHASE" "copied"
	state_set "$context" "$namespace" "$migration_id" "COPY_TIMESTAMP" "$(date -Iseconds)"

	echo ""
	log_ok "Copy completed successfully (${elapsed}s)."
	echo ""
	echo "Next:"
	echo "  Run: $SCRIPT_NAME validate -c $context -n $namespace -m $migration_id"
}
