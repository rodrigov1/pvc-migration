cmd_copy_data() {
	local context="" namespace="" migration_id="" use_compress=false

	context="$1"
	shift || true
	namespace="$1"
	shift || true
	migration_id="$1"
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--compress)
			use_compress=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			usage
			;;
		esac
	done

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME copy-data [--compress] <context> <namespace> <migration-id>"
		exit 1
	fi

	state_require "$context" "$namespace" "$migration_id"

	local depl_old depl_new nfs_host_old nfs_path_old nfs_host_new nfs_path_new
	depl_old=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_OLD")
	depl_new=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_NEW")
	nfs_host_old=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST")
	nfs_path_old=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD")
	nfs_host_new=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_HOST")
	nfs_path_new=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_NEW")

	local backup_base
	backup_base="$(dirname "$nfs_path_old")/${migration_id}-backup"

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
	if ssh "$nfs_host_old" "test -d '$nfs_path_old'" 2>/dev/null; then
		source_available=true
	else
		log_warn "Old NFS path not accessible: $nfs_host_old:$nfs_path_old"
		if ssh "$nfs_host_old" "test -d '$backup_base'" 2>/dev/null; then
			log_info "But backup dir exists at $backup_base — will restore from backup."
		else
			log_warn "Contents of parent directory:"
			ssh "$nfs_host_old" "ls -lah '$(dirname "$nfs_path_old")'" 2>/dev/null || log_error "Cannot access old NFS at all."
			if ! confirm "Continue anyway (copy will fail without source or backup)?"; then
				log_info "Aborted."
				return
			fi
		fi
	fi

	log_info "Verifying SSH access to new NFS host: $nfs_host_new ..."
	if ! ssh "$nfs_host_new" "test -d '$(dirname "$nfs_path_new")'" 2>/dev/null; then
		log_warn "New NFS parent path not accessible. The share may not exist yet."
		if ! confirm "Continue anyway?"; then
			log_info "Aborted."
			return
		fi
	fi

	local new_has_data=false
	if ssh "$nfs_host_new" "test -d '$nfs_path_new' && find '$nfs_path_new' -mindepth 1 -maxdepth 1 -printf 1 -quit" 2>/dev/null | grep -q .; then
		new_has_data=true
		log_warn "New NFS path already has data!"
		ssh "$nfs_host_new" "ls -lah '$nfs_path_new'" 2>/dev/null || true
		if ! confirm "Overwrite new path data?"; then
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

	if $old_exists; then
		log_info "Scaling down $depl_old ..."
		kubectl scale deployment "$depl_old" --replicas=0 -n "$namespace" --context="$context" 2>/dev/null ||
			log_warn "Could not scale down $depl_old (may already be deleted)."
	fi
	if $new_exists; then
		log_info "Scaling down $depl_new ..."
		kubectl scale deployment "$depl_new" --replicas=0 -n "$namespace" --context="$context"
	fi

	log_info "Waiting for pods to terminate (timeout: 60s)..."
	local sel_old="" sel_new=""
	if $old_exists; then
		sel_old=$(get_deploy_selector "$context" "$namespace" "$depl_old")
	fi
	if $new_exists; then
		sel_new=$(get_deploy_selector "$context" "$namespace" "$depl_new")
	fi
	local wait_start wait_elapsed
	wait_start=$(date +%s)
	while true; do
		wait_elapsed=$(($(date +%s) - wait_start))
		if [[ "$wait_elapsed" -gt 60 ]]; then
			log_warn "Timeout waiting for pods to terminate."
			break
		fi
		local old_count=0 new_count=0
		if $old_exists && [[ -n "$sel_old" ]]; then
			old_count=$(kubectl get pods -n "$namespace" --context="$context" -l "$sel_old" 2>/dev/null | tail -n +2 | wc -l || true)
		fi
		if $new_exists && [[ -n "$sel_new" ]]; then
			new_count=$(kubectl get pods -n "$namespace" --context="$context" -l "$sel_new" 2>/dev/null | tail -n +2 | wc -l || true)
		fi
		log_info "Pods remaining - old: $old_count, new: $new_count"
		if [[ "$old_count" -eq 0 && "$new_count" -eq 0 ]]; then
			log_ok "All pods terminated."
			break
		fi
		sleep 3
	done

	local mount_old_list=() subpath_old_list=() mount_new_list=() subpath_new_list=()
	state_get_mounts "$context" "$namespace" "$migration_id" "OLD"
	mount_old_list=("${MOUNTS_LIST[@]}")
	subpath_old_list=("${SUBPATHS_LIST[@]}")
	local mount_count="$MOUNT_COUNT"

	state_get_mounts "$context" "$namespace" "$migration_id" "NEW"
	mount_new_list=("${MOUNTS_LIST[@]}")
	subpath_new_list=("${SUBPATHS_LIST[@]}")

	if [[ "${#mount_old_list[@]}" -ne "$mount_count" ]]; then
		# Pad/truncate new side to match old side
		mount_new_list=()
		subpath_new_list=()
		local i
		for ((i = 0; i < mount_count; i++)); do
			mount_new_list+=("${MOUNTS_LIST[$i]:-}")
			subpath_new_list+=("${SUBPATHS_LIST[$i]:-}")
		done
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

	local restore_mode=false
	if ! $source_available; then
		if ssh "$nfs_host_old" "test -d '$backup_base'" 2>/dev/null; then
			log_info "Will restore from backup at $backup_base"
			restore_mode=true
		else
			log_error "No source NFS path and no backup available at $backup_base"
			exit 1
		fi
	fi

	local tar_flags="-cf -"
	local tar_extract="-xf -"
	local copy_label="tar-pipe (no compression)"
	if $use_compress; then
		tar_flags="-czf -"
		tar_extract="-xzf -"
		copy_label="tar-pipe (gzip compressed)"
	fi

	local progress_cmd="cat"
	if command -v pv &>/dev/null; then
		progress_cmd="pv -trab"
	fi

	log_info "Creating destination directories..."
	for ((i = 0; i < mount_count; i++)); do
		local ns="${subpath_new_list[$i]}"
		local dst="${nfs_path_new}${ns:+${ns}/}"
		ssh "$nfs_host_new" "mkdir -p '$dst'" 2>/dev/null || {
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

	local tmp_script="/tmp/pvc-mig-${migration_id}-$$.sh"
	{
		echo '#!/bin/bash'
		echo 'set -euo pipefail'
		echo ''
		echo "nfs_host_old=$(printf '%q' "$nfs_host_old")"
		echo "nfs_host_new=$(printf '%q' "$nfs_host_new")"
		echo "nfs_path_old=$(printf '%q' "$nfs_path_old")"
		echo "nfs_path_new=$(printf '%q' "$nfs_path_new")"
		echo "backup_base=$(printf '%q' "$backup_base")"
		echo "restore_mode=$restore_mode"
		echo "tar_flags=$(printf '%q' "$tar_flags")"
		echo "tar_extract=$(printf '%q' "$tar_extract")"
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
			echo '  if ! ssh "$nfs_host_old" "cat '\''${backup_base}/${i}.tgz'\''" | eval "$progress_cmd" | ssh "$nfs_host_new" "tar -xzf - -C \"$dst\""; then'
		else
			echo '  echo "[Mount $((i+1))/$mount_count] Copying ..."'
			echo '  echo "  $src -> $dst"'
			echo '  if ! ssh "$nfs_host_old" "tar $tar_flags -C \"$src\" ." | eval "$progress_cmd" | ssh "$nfs_host_new" "tar $tar_extract -C \"$dst\""; then'
		fi
		echo '    echo "[ERROR] Copy failed for mount $((i+1))"'
		echo '    exit 1'
		echo '  fi'
		echo '  echo "[Mount $((i+1))/$mount_count] Complete."'
		echo 'done'
		echo ''
		echo 'echo ""'
		echo 'echo "===== Verification ====="'
		echo 'all_ok=true'
		echo 'total_old=0 total_new=0'
		echo 'for ((i = 0; i < mount_count; i++)); do'
		echo '  old_sub="${subpath_old_list[$i]}"'
		echo '  new_sub="${subpath_new_list[$i]}"'
		echo '  src="${nfs_path_old}${old_sub:+${old_sub}/}"'
		echo '  dst="${nfs_path_new}${new_sub:+${new_sub}/}"'
		echo '  echo "[Mount $((i+1))/$mount_count] Verifying ..."'
		if $restore_mode; then
			echo '  old_c=$(ssh "$nfs_host_old" "tar -tzf '\''${backup_base}/${i}.tgz'\'' 2>/dev/null | grep -c -v '\''/$'\'' 2>/dev/null || echo 0")'
		else
			echo '  old_c=$(ssh "$nfs_host_old" "find \"$src\" -type f 2>/dev/null | wc -l" || echo "0")'
		fi
		echo '  new_c=$(ssh "$nfs_host_new" "find \"$dst\" -type f 2>/dev/null | wc -l" || echo "0")'
		echo '  total_old=$((total_old + old_c))'
		echo '  total_new=$((total_new + new_c))'
		echo '  echo "  File count: backup/old=$old_c new=$new_c"'
		echo '  if [[ "$old_c" != "$new_c" ]]; then'
		echo '    echo "  [WARN] Count mismatch"; all_ok=false'
		echo '  else'
		echo '    echo "  [OK] Count matches"'
		echo '  fi'
		if ! $restore_mode; then
			echo '  old_md5_list=$(ssh "$nfs_host_old" "find \"$src\" -type f -exec md5sum {} + 2>/dev/null" || true)'
			echo '  new_md5_list=$(ssh "$nfs_host_new" "find \"$dst\" -type f -exec md5sum {} + 2>/dev/null" || true)'
			echo '  old_md5=$(echo "$old_md5_list" | awk "{print \$1}" | sort | md5sum)'
			echo '  new_md5=$(echo "$new_md5_list" | awk "{print \$1}" | sort | md5sum)'
			echo '  if [[ -n "$old_md5" && -n "$new_md5" ]]; then'
			echo '    if [[ "$old_md5" == "$new_md5" ]]; then'
			echo '      echo "  [OK] md5 match"'
			echo '    else'
			echo '      echo "  [WARN] md5 differ"; all_ok=false'
			echo '    fi'
			echo '  fi'
		else
			echo '  echo "  [INFO] md5 check skipped (restore mode)"'
		fi
		echo 'done'
		echo 'echo ""'
		echo 'echo "Total file count: backup/old=$total_old new=$total_new"'
		echo 'if [[ "$total_old" == "$total_new" ]]; then echo "[OK] Total matches"; else echo "[WARN] Total mismatch"; all_ok=false; fi'
		echo 'echo ""'
		echo 'if $all_ok; then echo "[OK] All mounts verified successfully."; else echo "[WARN] Some checks failed."; fi'
		echo 'echo "Copy completed at $(date -Iseconds)"'
	} > "$tmp_script"
	chmod +x "$tmp_script"

	local use_persistent=false
	local term_cmd=""
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

	if $use_persistent; then
		local session_name="pvc-mig-${migration_id}"
		if [[ "$term_cmd" == "tmux" ]]; then
			tmux new-session -d -s "$session_name" "$tmp_script"
			log_info "tmux session '${session_name}' started"
			log_info "  Attach: tmux attach -t ${session_name}"
			log_info "  Session auto-closes on completion."
			while tmux has-session -t "$session_name" 2>/dev/null; do sleep 5; done
		else
			screen -dmS "$session_name" bash "$tmp_script"
			log_info "screen session '${session_name}' started"
			log_info "  Attach: screen -r ${session_name}"
			while screen -list 2>/dev/null | grep -q "$session_name"; do sleep 5; done
		fi
	else
		log_info "Starting copy (inline)..."
		bash "$tmp_script"
	fi

	end_time=$(date +%s)
	elapsed=$((end_time - start_time))
	rm -f "$tmp_script"

	log_ok "Data copy completed in ${elapsed}s"

	state_set "$context" "$namespace" "$migration_id" "PHASE" "copied"
	state_set "$context" "$namespace" "$migration_id" "COPY_TIMESTAMP" "$(date -Iseconds)"

	echo ""
	log_ok "copy-data complete for $migration_id in $context/$namespace"
	echo ""
	echo "===== Next steps ====="
	echo "1. Run: $SCRIPT_NAME validate $context $namespace $migration_id"
}