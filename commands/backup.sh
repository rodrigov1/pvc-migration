mark_backup_failed() {
	local context="$1" namespace="$2" migration_id="$3"
	state_set "$context" "$namespace" "$migration_id" "PHASE" "backup-failed"
	state_set "$context" "$namespace" "$migration_id" "BACKUP_ERROR_TIMESTAMP" "$(date -Iseconds)"
}

cmd_backup() {
	local command="backup"
	parse_common_args "$command" "$@" || return 1
	require_common_args "$command" || return 1
	require_no_command_args "$command" || return 1

	local context="$CLI_CONTEXT" namespace="$CLI_NAMESPACE" migration_id="$CLI_MIGRATION"

	state_require "$context" "$namespace" "$migration_id"

	local nfs_host_old nfs_path_old deploy_old
	nfs_host_old=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST")
	nfs_path_old=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD")
	deploy_old=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_OLD")

	if [[ -z "$nfs_host_old" || -z "$nfs_path_old" || -z "$deploy_old" ]]; then
		log_error "Missing old NFS info. Run 'discover-old' first."
		exit 1
	fi

	log_info "Verifying access to old NFS host..."
	if ! ssh_run "$nfs_host_old" test -d "$nfs_path_old" 2>/dev/null; then
		log_error "Old NFS path inaccessible: $nfs_host_old:$nfs_path_old"
		exit 1
	fi
	if ! verification_preflight_remote "$nfs_host_old" "$nfs_path_old"; then
		log_error "Old NFS host is not ready for baseline backup verification."
		return 1
	fi

	local backup_root backup_base backup_partial
	backup_root="$(dirname "$nfs_path_old")/${migration_id}-backup"
	backup_base="$backup_root/$(date -u +%Y%m%dT%H%M%SZ)-$$"
	backup_partial="${backup_base}.partial"

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

	if ! confirm "Scale down $deploy_old and create a consistent backup?"; then
		log_info "Backup cancelled."
		return
	fi
	state_set "$context" "$namespace" "$migration_id" "PHASE" "backup-in-progress"

	if ! kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" &>/dev/null; then
		log_error "Old deployment $deploy_old is no longer available; cannot establish quiescence."
		mark_backup_failed "$context" "$namespace" "$migration_id"
		return 1
	fi
	if ! kubectl scale deployment "$deploy_old" --replicas=0 -n "$namespace" --context="$context" 2>/dev/null; then
		log_error "Could not scale down $deploy_old before backup."
		mark_backup_failed "$context" "$namespace" "$migration_id"
		return 1
	fi
	if ! wait_for_deployment_pods_zero "$context" "$namespace" "$deploy_old" 60; then
		mark_backup_failed "$context" "$namespace" "$migration_id"
		return 1
	fi

	if ! verification_capture_side "$context" "$namespace" "$migration_id" OLD \
		"$nfs_host_old" "$nfs_path_old"; then
		log_error "Could not capture the source baseline before backup."
		mark_backup_failed "$context" "$namespace" "$migration_id"
		return 1
	fi
	local source_generation
	source_generation=$(state_get "$context" "$namespace" "$migration_id" "VERIFY_OLD_GENERATION")

	if ! ssh_run "$nfs_host_old" mkdir -p "$backup_partial"; then
		log_error "Could not create backup staging directory: $backup_partial"
		mark_backup_failed "$context" "$namespace" "$migration_id"
		return 1
	fi

	local tmp_script result_file
	tmp_script=$(mktemp "/tmp/pvc-mig-backup-XXXXXX.sh")
	result_file=$(mktemp "/tmp/pvc-mig-backup-result-XXXXXX")
	{
		echo '#!/bin/bash'
		echo 'set -euo pipefail'
		echo "source $(printf '%q' "$SCRIPT_DIR/lib/remote.sh")"
		echo "result_file=$(printf '%q' "$result_file")"
		echo 'trap "echo exit_code=\$? > \"\$result_file\"" EXIT'
		echo ''
		echo "nfs_host_old=$(printf '%q' "$nfs_host_old")"
		echo "nfs_path_old=$(printf '%q' "$nfs_path_old")"
		echo "backup_base=$(printf '%q' "$backup_partial")"
		echo "source_generation=$(printf '%q' "$source_generation")"
		echo "mount_count=$mount_count"
		echo ''
		echo "subpath_old_list=($(for v in "${subpath_old_list[@]}"; do printf '%q ' "$v"; done))"
		echo ''
		echo 'for ((i = 0; i < mount_count; i++)); do'
		echo '  sub="${subpath_old_list[$i]}"'
		echo '  src="${nfs_path_old}${sub:+${sub}/}"'
		echo '  echo "[Mount $((i+1))/$mount_count] Backing up $src ..."'
		echo '  ssh_bash "$nfs_host_old" '\''exec tar --format=pax --numeric-owner --sparse --gzip --create --file="$1" --directory="$2" .'\'' "${backup_base}/${i}.tgz" "$src" 2>/dev/null || { echo "[ERROR] Backup failed for mount $((i+1))"; exit 1; }'
		echo '  ssh_bash "$nfs_host_old" '\''exec tar --compare --gzip --file="$1" --directory="$2" .'\'' "${backup_base}/${i}.tgz" "$src" 2>/dev/null || { echo "[ERROR] Backup verification failed for mount $((i+1))"; exit 1; }'
		echo '  echo "[Mount $((i+1))/$mount_count] Complete."'
		echo 'done'
		echo ''
		echo '# Write self-contained metadata only after every archive was verified.'
		echo 'ssh_bash "$nfs_host_old" '\''set -euo pipefail; base="$1"; count="$2"; generation="$3"; metadata="$base/metadata.env"; tmp="${metadata}.tmp"; printf "VERIFY_OLD_GENERATION=%s\nMOUNT_COUNT=%s\n" "$generation" "$count" > "$tmp"; for ((idx=0; idx<count; idx++)); do digest=$(sha256sum -- "$base/$idx.tgz"); digest=${digest%% *}; digest=${digest#\\}; printf "ARCHIVE_%s_SHA256=%s\n" "$idx" "$digest" >> "$tmp"; done; mv -- "$tmp" "$metadata"'\'' "$backup_base" "$mount_count" "$source_generation"'
		echo ''
		echo 'echo "Backup archives compared successfully at $(date -Iseconds)"'
	} > "$tmp_script"
	chmod +x "$tmp_script"

	local start_time end_time elapsed
	start_time=$(date +%s)

	local backup_failed=false
	log_info "Starting backup (inline in the current full-workflow session)..."
	if ! bash "$tmp_script"; then
		backup_failed=true
	fi

	rm -f "$tmp_script" "$result_file"
	end_time=$(date +%s)
	elapsed=$((end_time - start_time))

	if $backup_failed; then
		log_error "Backup failed. The partial backup was kept at $backup_partial."
		mark_backup_failed "$context" "$namespace" "$migration_id"
		return 1
	fi
	if ! ssh_run "$nfs_host_old" mv -- "$backup_partial" "$backup_base"; then
		log_error "Backup was verified but could not be published at $backup_base."
		mark_backup_failed "$context" "$namespace" "$migration_id"
		return 1
	fi
	local pointer_file="$backup_root/current" pointer_tmp="$backup_root/.current.$$"
	if ! ssh_bash "$nfs_host_old" \
		'printf "%s\n" "$2" > "$1" && mv -- "$1" "$3"' \
		"$pointer_tmp" "$backup_base" "$pointer_file"; then
		log_error "Backup was published but its current pointer could not be updated."
		mark_backup_failed "$context" "$namespace" "$migration_id"
		return 1
	fi
	local archive_digest
	for ((i = 0; i < mount_count; i++)); do
		if ! archive_digest=$(ssh_bash "$nfs_host_old" \
			'sha256sum -- "$1" | awk '\''{print $1}'\''' "${backup_base}/${i}.tgz"); then
			log_error "Could not record the digest for backup archive $i."
			mark_backup_failed "$context" "$namespace" "$migration_id"
			return 1
		fi
		state_set "$context" "$namespace" "$migration_id" "BACKUP_ARCHIVE_DIGEST_${i}" "$archive_digest"
	done

	log_ok "Backup completed in ${elapsed}s"
	state_set "$context" "$namespace" "$migration_id" "BACKUP_BASE_OLD" "$backup_base"
	state_set "$context" "$namespace" "$migration_id" "BACKUP_VERIFY_OLD_GENERATION" "$source_generation"
	state_set "$context" "$namespace" "$migration_id" "BACKUP_MOUNT_COUNT" "$mount_count"
	state_set "$context" "$namespace" "$migration_id" "PHASE" "backed_up"
	echo ""
	log_ok "backup complete for $migration_id in $context/$namespace"
	echo ""
	echo "===== Next steps ====="
	echo "1. Deploy the new chart (helm upgrade)"
	echo "2. Run: $SCRIPT_NAME discover-new -c $context -n $namespace -m $migration_id"
}
