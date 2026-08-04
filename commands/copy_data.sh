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

	log_info "Starting copy (inside the current full-workflow session)..."
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

	echo ""
	echo "===== Copy Plan ====="
	echo "  Old deployment: $depl_old"
	echo "  New deployment: $depl_new"
	echo "  Old NFS: $nfs_host_old:$nfs_path_old"
	echo "  New NFS: $nfs_host_new:$nfs_path_new"
	echo ""

	local source_available=false
	log_info "Verifying SSH access to old NFS host: $nfs_host_old ..."
	if ssh_run "$nfs_host_old" test -d "$nfs_path_old" 2>/dev/null; then
		source_available=true
	else
		log_warn "Old NFS path not accessible: $nfs_host_old:$nfs_path_old"
		if [[ -n "$backup_base" ]] && ssh_run "$nfs_host_old" test -d "$backup_base" 2>/dev/null; then
			log_info "But backup dir exists at $backup_base — will restore from backup."
		else
			log_warn "Contents of parent directory:"
			ssh_run "$nfs_host_old" ls -lah "$(dirname "$nfs_path_old")" 2>/dev/null || log_error "Cannot access old NFS at all."
			if ! confirm "Continue anyway (copy will fail without source or backup)?"; then
				log_info "Aborted."
				return
			fi
		fi
	fi
	if [[ "$reclaim_policy_old" == "Delete" && -n "$backup_base" ]] &&
		ssh_run "$nfs_host_old" test -d "$backup_base" 2>/dev/null; then
		log_info "A verified Delete-policy backup is recorded; using it instead of the live source path."
		source_available=false
	fi
	if $source_available; then
		if ! verification_preflight_remote "$nfs_host_old" "$nfs_path_old"; then
			log_error "Old NFS host is not ready for baseline verification."
			return 1
		fi
	else
		if [[ -z "$backup_base" ]] || ! verification_preflight_remote "$nfs_host_old" "$backup_base"; then
			log_error "Old NFS host is not ready for backup restore verification."
			return 1
		fi
	fi

	log_info "Verifying SSH access to new NFS host: $nfs_host_new ..."
	if ! ssh_run "$nfs_host_new" test -d "$(dirname "$nfs_path_new")" 2>/dev/null; then
		log_warn "New NFS parent path not accessible. The share may not exist yet."
		if ! confirm "Continue anyway?"; then
			log_info "Aborted."
			return
		fi
	fi
	if ! verification_preflight_remote "$nfs_host_new" "$(dirname "$nfs_path_new")"; then
		log_error "New NFS host is not ready for baseline verification."
		return 1
	fi

	local new_has_data=false
	if ssh_bash "$nfs_host_new" 'test -d "$1" && find "$1" -mindepth 1 -maxdepth 1 -printf 1 -quit' "$nfs_path_new" 2>/dev/null | grep -q .; then
		new_has_data=true
		log_warn "New NFS path already has data!"
		ssh_run "$nfs_host_new" ls -lah "$nfs_path_new" 2>/dev/null || true
		if ! confirm "Replace destination data? Existing entries under each destination mount will be deleted."; then
			log_info "Aborted."
			return
		fi
	fi

	echo ""
	log_warn "About to scale DOWN deployments to 0."
	local old_exists=false
	local new_exists=false
	if kubectl get deployment "$depl_old" -n "$namespace" --context="$context" &>/dev/null; then
		old_exists=true
		log_warn "  Scale down: $depl_old"
	else
		log_warn "  Old deployment '$depl_old' no longer exists (skipping)."
	fi
	if kubectl get deployment "$depl_new" -n "$namespace" --context="$context" &>/dev/null; then
		new_exists=true
		log_warn "  Scale down: $depl_new"
	else
		log_warn "  New deployment '$depl_new' no longer exists (skipping)."
	fi
	if ! $old_exists && ! $new_exists; then
		log_warn "Neither deployment exists. Nothing to scale down."
	fi
	if ! confirm "Proceed with scale down?"; then
		log_info "Aborted."
		return
	fi
	state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "pending"
	state_set "$context" "$namespace" "$migration_id" "PHASE" "copy-in-progress"

	if $old_exists; then
		log_info "Scaling down $depl_old ..."
		if ! kubectl scale deployment "$depl_old" --replicas=0 -n "$namespace" --context="$context" 2>/dev/null; then
			log_error "Could not scale down $depl_old."
			return 1
		fi
	fi
	if $new_exists; then
		log_info "Scaling down $depl_new ..."
		if ! kubectl scale deployment "$depl_new" --replicas=0 -n "$namespace" --context="$context"; then
			log_error "Could not scale down $depl_new."
			return 1
		fi
	fi

	if $old_exists && ! wait_for_deployment_pods_zero "$context" "$namespace" "$depl_old" 60; then
		return 1
	fi
	if $new_exists && ! wait_for_deployment_pods_zero "$context" "$namespace" "$depl_new" 60; then
		return 1
	fi

	local restore_mode=false
	if ! $source_available; then
		if [[ -n "$backup_base" ]] && ssh_run "$nfs_host_old" test -d "$backup_base" 2>/dev/null; then
			log_info "Will restore from backup at $backup_base"
			restore_mode=true
		else
			log_error "No source NFS path and no backup available at $backup_base"
			return 1
		fi
	fi

	if $source_available; then
		if ! verification_capture_side "$context" "$namespace" "$migration_id" OLD \
			"$nfs_host_old" "$nfs_path_old"; then
			state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
			return 1
		fi
	elif ! verification_side_ready "$context" "$namespace" "$migration_id" OLD; then
		log_error "Source baseline manifests are missing; run backup before restore."
		state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
		return 1
	fi
	if $restore_mode; then
		local current_old_generation
		current_old_generation=$(state_get "$context" "$namespace" "$migration_id" "VERIFY_OLD_GENERATION" || true)
		if [[ -z "$backup_generation" || "$current_old_generation" != "$backup_generation" ]]; then
			log_error "The source baseline generation does not match the selected backup."
			state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
			return 1
		fi
	fi

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
		log_error "Old/new mount counts or mount data do not match; refusing to copy."
		state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
		return 1
	fi
	if $restore_mode; then
		local backup_mount_count
		backup_mount_count=$(state_get "$context" "$namespace" "$migration_id" "BACKUP_MOUNT_COUNT" || true)
		if [[ "$backup_mount_count" != "$mount_count" ]]; then
			log_error "Selected backup mount count does not match the migration state."
			state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
			return 1
		fi
		if ! verification_check_backup_archives "$context" "$namespace" "$migration_id" \
			"$nfs_host_old" "$backup_base" "$mount_count"; then
			state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
			return 1
		fi
	fi

	echo ""
	log_info "Copy plan: $mount_count mount(s)"
	for ((i = 0; i < mount_count; i++)); do
		local os="${subpath_old_list[$i]}"
		local ns="${subpath_new_list[$i]}"
		local src="${nfs_path_old}${os:+${os}/}"
		local dst="${nfs_path_new}${ns:+${ns}/}"
		echo "  [$((i+1))] ${mount_old_list[$i]:-<root>}"
		echo "       Old: $nfs_host_old:$src"
		echo "       New: $nfs_host_new:$dst"
	done

	local progress_cmd="cat"
	if command -v pv &>/dev/null; then
		progress_cmd="pv -trab"
	fi

	log_info "Creating destination directories..."
	for ((i = 0; i < mount_count; i++)); do
		local ns="${subpath_new_list[$i]}"
		local dst="${nfs_path_new}${ns:+${ns}/}"
		ssh_run "$nfs_host_new" mkdir -p "$dst" 2>/dev/null || {
			log_error "Failed to create directory: $dst"
			exit 1
		}
	done

	local confirm_msg="Proceed with data copy?"
	if $restore_mode; then
		confirm_msg="Proceed with data restore from backup?"
	fi
	if ! confirm "$confirm_msg"; then
		log_info "Aborted."
		return
	fi
	if $new_has_data; then
		log_warn "Removing existing entries from destination mount paths..."
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
		echo ''
		echo 'for ((i = 0; i < mount_count; i++)); do'
		echo '  old_sub="${subpath_old_list[$i]}"'
		echo '  new_sub="${subpath_new_list[$i]}"'
		echo '  src="${nfs_path_old}${old_sub:+${old_sub}/}"'
		echo '  dst="${nfs_path_new}${new_sub:+${new_sub}/}"'
		echo '  echo ""'
		if $restore_mode; then
			echo '  echo "[Mount $((i+1))/$mount_count] Restoring from backup ..."'
			echo '  echo "  backup:${backup_base}/${i}.tgz -> $dst"'
			echo '  if ! ssh_run "$nfs_host_old" cat -- "${backup_base}/${i}.tgz" | eval "$progress_cmd" | ssh_bash "$nfs_host_new" '\''exec tar --numeric-owner --same-owner --same-permissions --sparse --gzip -xpf - --directory="$1"'\'' "$dst"; then'
		else
			echo '  echo "[Mount $((i+1))/$mount_count] Copying ..."'
			echo '  echo "  $src -> $dst"'
			if $use_compress; then
				echo '  if ! ssh_bash "$nfs_host_old" '\''exec tar --format=pax --numeric-owner --sparse --gzip -cpf - --directory="$1" .'\'' "$src" | eval "$progress_cmd" | ssh_bash "$nfs_host_new" '\''exec tar --numeric-owner --same-owner --same-permissions --sparse --gzip -xpf - --directory="$1"'\'' "$dst"; then'
			else
				echo '  if ! ssh_bash "$nfs_host_old" '\''exec tar --format=pax --numeric-owner --sparse -cpf - --directory="$1" .'\'' "$src" | eval "$progress_cmd" | ssh_bash "$nfs_host_new" '\''exec tar --numeric-owner --same-owner --same-permissions --sparse -xpf - --directory="$1"'\'' "$dst"; then'
			fi
		fi
		echo '    echo "[ERROR] Copy failed for mount $((i+1))"'
		echo '    exit 1'
		echo '  fi'
		echo '  echo "[Mount $((i+1))/$mount_count] Complete."'
		echo 'done'
		echo ''
		echo 'echo "Data stream transfer completed at $(date -Iseconds)"'
	} > "$tmp_script"
	chmod +x "$tmp_script"

	local start_time end_time elapsed
	start_time=$(date +%s)
	local copy_failed=false
	if ! run_copy_job "$tmp_script" "$result_file"; then
		copy_failed=true
	fi
	if ! $copy_failed; then
		if ! verification_capture_side "$context" "$namespace" "$migration_id" NEW \
			"$nfs_host_new" "$nfs_path_new" ||
			! verification_compare_sides "$context" "$namespace" "$migration_id"; then
			copy_failed=true
		fi
	fi

	end_time=$(date +%s)
	elapsed=$((end_time - start_time))
	rm -f "$tmp_script" "$result_file"

	if $copy_failed; then
		state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
		state_set "$context" "$namespace" "$migration_id" "PHASE" "copy-failed"
		state_set "$context" "$namespace" "$migration_id" "COPY_ERROR_TIMESTAMP" "$(date -Iseconds)"
		log_error "Data copy failed. Destination was not marked as copied."
		return 1
	fi

	log_ok "Data copy completed in ${elapsed}s"

	state_set "$context" "$namespace" "$migration_id" "PHASE" "copied"
	state_set "$context" "$namespace" "$migration_id" "COPY_TIMESTAMP" "$(date -Iseconds)"

	echo ""
	log_ok "copy-data complete for $migration_id in $context/$namespace"
	echo ""
	echo "===== Next steps ====="
	echo "1. Run: $SCRIPT_NAME validate -c $context -n $namespace -m $migration_id"
}
