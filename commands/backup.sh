cmd_backup() {
	local context="$1" namespace="$2" migration_id="$3"

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME backup <context> <namespace> <migration-id>"
		exit 1
	fi

	state_require "$context" "$namespace" "$migration_id"

	local nfs_host_old nfs_path_old
	nfs_host_old=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST")
	nfs_path_old=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD")

	if [[ -z "$nfs_host_old" || -z "$nfs_path_old" ]]; then
		log_error "Missing old NFS info. Run 'discover-old' first."
		exit 1
	fi

	log_info "Verifying access to old NFS host..."
	if ! ssh "$nfs_host_old" "test -d '$nfs_path_old'" 2>/dev/null; then
		log_error "Old NFS path inaccessible: $nfs_host_old:$nfs_path_old"
		exit 1
	fi

	local backup_base
	backup_base="$(dirname "$nfs_path_old")/${migration_id}-backup"

	local -a subpath_old_list=()
	state_get_mounts "$context" "$namespace" "$migration_id" "OLD"
	subpath_old_list=("${SUBPATHS_LIST[@]}")
	local mount_count="$MOUNT_COUNT"

	echo ""
	log_info "Backup plan for $migration_id in $context/$namespace"
	echo "  Old NFS host: $nfs_host_old"
	echo "  Old PV root:  $nfs_path_old"
	echo "  Backup dir:   $backup_base"
	echo "  Mounts:       $mount_count"
	for ((i = 0; i < mount_count; i++)); do
		local os="${subpath_old_list[$i]}"
		local src="${nfs_path_old}${os:+${os}/}"
		echo "  [$((i+1))] $src -> ${backup_base}/${i}.tgz"
	done

	if ! confirm "Proceed with backup?"; then
		log_info "Backup cancelled."
		return
	fi

	ssh "$nfs_host_old" "mkdir -p '$backup_base' && rm -f '$backup_base'/*.tgz"

	local tmp_script="/tmp/pvc-mig-backup-${migration_id}-$$.sh"
	local result_file="/tmp/pvc-mig-backup-result-${migration_id}-$$.txt"
	rm -f "$result_file"
	{
		echo '#!/bin/bash'
		echo 'set -euo pipefail'
		echo "result_file='$result_file'"
		echo 'trap "echo exit_code=\$? > \"\$result_file\"" EXIT'
		echo ''
		echo "nfs_host_old=$(printf '%q' "$nfs_host_old")"
		echo "nfs_path_old=$(printf '%q' "$nfs_path_old")"
		echo "backup_base=$(printf '%q' "$backup_base")"
		echo "mount_count=$mount_count"
		echo ''
		echo "subpath_old_list=($(for v in "${subpath_old_list[@]}"; do printf '%q ' "$v"; done))"
		echo ''
		echo 'for ((i = 0; i < mount_count; i++)); do'
		echo '  sub="${subpath_old_list[$i]}"'
		echo '  src="${nfs_path_old}${sub:+${sub}/}"'
		echo '  echo "[Mount $((i+1))/$mount_count] Backing up $src ..."'
		echo '  ssh "$nfs_host_old" "tar -czf '\''${backup_base}/${i}.tgz'\'' -C '\''$src'\'' ." 2>/dev/null || { echo "[ERROR] Backup failed for mount $((i+1))"; exit 1; }'
		echo '  echo "[Mount $((i+1))/$mount_count] Complete."'
		echo 'done'
		echo ''
		echo '# Write metadata'
		echo 'ssh "$nfs_host_old" "echo '\''mount_count=$mount_count'\'' > '\''${backup_base}/metadata.env'\''"'
		echo ''
		echo 'echo ""'
		echo 'echo "===== Verification ====="'
		echo 'all_ok=true'
		echo 'total_src=0 total_tgz=0'
		echo 'for ((i = 0; i < mount_count; i++)); do'
		echo '  sub="${subpath_old_list[$i]}"'
		echo '  src="${nfs_path_old}${sub:+${sub}/}"'
		echo '  echo "[Mount $((i+1))/$mount_count] Verifying ..."'
		echo '  src_c=$(ssh "$nfs_host_old" "find \"$src\" -type f 2>/dev/null | wc -l" || echo "0")'
		echo '  tgz_c=$(ssh "$nfs_host_old" "tar -tzf '\''${backup_base}/${i}.tgz'\'' 2>/dev/null | grep -c -v '\''/$'\'' 2>/dev/null || echo 0")'
		echo '  total_src=$((total_src + src_c))'
		echo '  total_tgz=$((total_tgz + tgz_c))'
		echo '  echo "  File count: source=$src_c backup=$tgz_c"'
		echo '  if [[ "$src_c" != "$tgz_c" ]]; then'
		echo '    echo "  [WARN] File count mismatch"; all_ok=false'
		echo '  else'
		echo '    echo "  [OK] File count matches"'
		echo '  fi'
		echo '  src_size=$(ssh "$nfs_host_old" "du -sb \"$src\" 2>/dev/null | awk '\''{print \$1}'\''" || echo "0")'
		echo '  echo "  Source size: $(numfmt --to=iec "$src_size" 2>/dev/null || echo "$src_size bytes")"'
		echo 'done'
		echo 'echo ""'
		echo 'echo "Total file count: source=$total_src backup=$total_tgz"'
		echo 'if [[ "$total_src" == "$total_tgz" ]]; then echo "[OK] Total matches"; else echo "[WARN] Total mismatch"; all_ok=false; fi'
		echo 'echo ""'
		echo 'if $all_ok; then'
		echo '  echo "[OK] All mounts verified successfully."'
		echo 'else'
		echo '  echo "[ERROR] Verification failed."'
		echo '  exit 1'
		echo 'fi'
		echo 'echo "Backup completed at $(date -Iseconds)"'
	} > "$tmp_script"
	chmod +x "$tmp_script"

	local use_persistent=false term_cmd=""
	if command -v tmux &>/dev/null; then
		if confirm_default_yes "Use tmux session (survives SSH disconnects)?"; then
			use_persistent=true; term_cmd="tmux"
		fi
	elif command -v screen &>/dev/null; then
		if confirm_default_yes "Use screen session (survives SSH disconnects)?"; then
			use_persistent=true; term_cmd="screen"
		fi
	fi

	local start_time end_time elapsed
	start_time=$(date +%s)

	local backup_failed=false
	if $use_persistent; then
		local session_name="pvc-mig-backup-${migration_id}"
		if [[ "$term_cmd" == "tmux" ]]; then
			tmux new-session -d -s "$session_name" "$tmp_script"
			log_info "tmux session '${session_name}' started"
			log_info "  Attach: tmux attach -t ${session_name}"
			while tmux has-session -t "$session_name" 2>/dev/null; do sleep 5; done
		else
			screen -dmS "$session_name" bash "$tmp_script"
			log_info "screen session '${session_name}' started"
			log_info "  Attach: screen -r ${session_name}"
			while screen -list 2>/dev/null | grep -q "$session_name"; do sleep 5; done
		fi
		if [[ -f "$result_file" ]]; then
			local saved_exit
			saved_exit=$(grep -o 'exit_code=[0-9]*' "$result_file" | cut -d= -f2)
			[[ "$saved_exit" != "0" ]] && backup_failed=true
			rm -f "$result_file"
		else
			log_warn "Backup session result file not found (session may have been killed)."
			backup_failed=true
		fi
	else
		log_info "Starting backup (inline)..."
		if ! bash "$tmp_script"; then
			backup_failed=true
		fi
	fi

	rm -f "$tmp_script" "$result_file"
	end_time=$(date +%s)
	elapsed=$((end_time - start_time))

	if $backup_failed; then
		log_error "Backup failed. Re-run to retry."
		return
	fi

	log_ok "Backup completed in ${elapsed}s"
	state_set "$context" "$namespace" "$migration_id" "PHASE" "backed_up"
	echo ""
	log_ok "backup complete for $migration_id in $context/$namespace"
	echo ""
	echo "===== Next steps ====="
	echo "1. Deploy the new chart (helm upgrade)"
	echo "2. Run: $SCRIPT_NAME discover-new $context $namespace $migration_id"
}