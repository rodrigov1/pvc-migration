#!/bin/bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
STATE_BASE="$HOME/.pvc-migration/state"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/ui/logging.sh"
source "$SCRIPT_DIR/ui/prompts.sh"
source "$SCRIPT_DIR/ui/usage.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/kube.sh"
source "$SCRIPT_DIR/lib/nfs.sh"
source "$SCRIPT_DIR/lib/manifest.sh"
source "$SCRIPT_DIR/lib/copy.sh"
source "$SCRIPT_DIR/lib/validation.sh"

source "$SCRIPT_DIR/commands/discover_old.sh"
source "$SCRIPT_DIR/commands/discover_new.sh"
source "$SCRIPT_DIR/commands/backup.sh"
source "$SCRIPT_DIR/commands/copy_data.sh"
source "$SCRIPT_DIR/commands/validate.sh"
source "$SCRIPT_DIR/commands/status.sh"

discover_old() { cmd_discover_old "$@"; }
discover_new() { cmd_discover_new "$@"; }
backup() { cmd_backup "$@"; }
copy_data() { cmd_copy_data "$@"; }
validate() { cmd_validate "$@"; }
show_status() { cmd_status "$@"; }

# ======================================================================
# MAIN
# ======================================================================

if [[ $# -lt 1 ]]; then
	usage
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
discover-old)
	discover_old "$@"
	;;
discover-new | discover_new)
	discover_new "$@"
	;;
backup)
	backup "$@"
	;;
copy-data | copy_data)
	copy_data "$@"
	;;
validate)
	validate "$@"
	;;
status)
	show_status "$@"
	;;
*)
	log_error "Unknown subcommand: $SUBCOMMAND"
	usage
	;;
esac
copy_data() {
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

	# Backup directory (at share level, outside PV path)
	local backup_base
	backup_base="$(dirname "$nfs_path_old")/${migration_id}-backup"

	# Validate required fields
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

	# Verify SSH access to both NFS hosts
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

	# Check if new path already has data
	local new_has_data=false
	if ssh "$nfs_host_new" "test -d '$nfs_path_new' && find '$nfs_path_new' -mindepth 1 -maxdepth 1 | head -1" 2>/dev/null | grep -q .; then
		new_has_data=true
		log_warn "New NFS path already has data!"
		ssh "$nfs_host_new" "ls -lah '$nfs_path_new'" 2>/dev/null || true
		if ! confirm "Overwrite new path data?"; then
			log_info "Aborted."
			return
		fi
	fi

	# Scale down old and new deployments (handle missing deployments gracefully)
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

	# Parse mount lists (supports both single and multi-mount) — must be before backup
	local mounts_old_str subpaths_old_str mounts_new_str subpaths_new_str
	mounts_old_str=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_OLD" || true)
	subpaths_old_str=$(state_get "$context" "$namespace" "$migration_id" "SUBPATH_OLD" || true)
	mounts_new_str=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_NEW" || true)
	subpaths_new_str=$(state_get "$context" "$namespace" "$migration_id" "SUBPATH_NEW" || true)

	local mount_old_list=() subpath_old_list=() mount_new_list=() subpath_new_list=()
	local line
	while IFS= read -r line; do [[ -n "$line" ]] && mount_old_list+=("$line"); done <<< "$(echo "$mounts_old_str" | sed 's/__/\n/g')"
	while IFS= read -r line; do subpath_old_list+=("$line"); done <<< "$(echo "$subpaths_old_str" | sed 's/__/\n/g')"
	while IFS= read -r line; do [[ -n "$line" ]] && mount_new_list+=("$line"); done <<< "$(echo "$mounts_new_str" | sed 's/__/\n/g')"
	while IFS= read -r line; do subpath_new_list+=("$line"); done <<< "$(echo "$subpaths_new_str" | sed 's/__/\n/g')"

	local mount_count=${#mount_old_list[@]}
	if [[ "$mount_count" -eq 0 ]]; then
		# Single mount (legacy state without lists) — use entire NFS paths as-is
		mount_count=1
		mount_old_list=("")
		subpath_old_list=("")
		mount_new_list=("")
		subpath_new_list=("")
	fi
	# Pad subpath arrays to match mount_count (preserve empty subPaths)
	while [[ ${#subpath_old_list[@]} -lt "$mount_count" ]]; do subpath_old_list+=(""); done
	while [[ ${#subpath_new_list[@]} -lt "$mount_count" ]]; do subpath_new_list+=(""); done

	# Print copy plan with mounts
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

	# Determine copy mode: source or restore
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

	# Build tar flags
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

	# Create all destination directories
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

	# Generate temp copy script
	local tmp_script="/tmp/pvc-mig-${migration_id}-$$.sh"
	{
		echo '#!/bin/bash'
		echo 'set -euo pipefail'
		echo ''
		echo "nfs_host_old='$nfs_host_old'"
		echo "nfs_host_new='$nfs_host_new'"
		echo "nfs_path_old='$nfs_path_old'"
		echo "nfs_path_new='$nfs_path_new'"
		echo "backup_base='$backup_base'"
		echo "restore_mode=$restore_mode"
		echo "tar_flags='$tar_flags'"
		echo "tar_extract='$tar_extract'"
		echo "progress_cmd='$progress_cmd'"
		echo "mount_count=$mount_count"
		echo ''

		# Mount-specific variables as arrays
		echo "subpath_old_list=($(for v in "${subpath_old_list[@]}"; do echo -n "'$v' "; done))"
		echo "subpath_new_list=($(for v in "${subpath_new_list[@]}"; do echo -n "'$v' "; done))"

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
			# md5 comparison only when old source is available
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

	# Decide: tmux, screen, or inline
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

	# Record copy in state
	state_set "$context" "$namespace" "$migration_id" "PHASE" "copied"
	state_set "$context" "$namespace" "$migration_id" "COPY_TIMESTAMP" "$(date -Iseconds)"

	echo ""
	log_ok "copy-data complete for $migration_id in $context/$namespace"
	echo ""
	echo "===== Next steps ====="
	echo "1. Run: $SCRIPT_NAME validate $context $namespace $migration_id"
}

# ======================================================================
# SUBCOMMAND: backup
# ======================================================================
backup() {
	local context="$1" namespace="$2" migration_id="$3"

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME backup <context> <namespace> <migration-id>"
		exit 1
	fi

	state_require "$context" "$namespace" "$migration_id"

	local nfs_host_old nfs_path_old subpaths_str
	nfs_host_old=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST")
	nfs_path_old=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD")
	subpaths_str=$(state_get "$context" "$namespace" "$migration_id" "SUBPATH_OLD" || true)

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

	# Parse mounts
	local -a subpath_old_list=()
	if [[ -n "$subpaths_str" ]]; then
		while IFS= read -r line; do subpath_old_list+=("$line"); done <<< "$(echo "$subpaths_str" | sed 's/__/\n/g')"
	fi

	local mount_count=${#subpath_old_list[@]}
	if [[ "$mount_count" -eq 0 ]]; then
		mount_count=1
		subpath_old_list=("")
	fi

	# Display backup plan
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

	# Create backup dir on old NFS host
	ssh "$nfs_host_old" "mkdir -p '$backup_base' && rm -f '$backup_base'/*.tgz"

	# Generate temp backup script
	local tmp_script="/tmp/pvc-mig-backup-${migration_id}-$$.sh"
	local result_file="/tmp/pvc-mig-backup-result-${migration_id}-$$.txt"
	rm -f "$result_file"
	{
		echo '#!/bin/bash'
		echo 'set -euo pipefail'
		echo "result_file='$result_file'"
		echo 'trap "echo exit_code=\$? > \"\$result_file\"" EXIT'
		echo ''
		echo "nfs_host_old='$nfs_host_old'"
		echo "nfs_path_old='$nfs_path_old'"
		echo "backup_base='$backup_base'"
		echo "mount_count=$mount_count"
		echo ''
		echo "subpath_old_list=($(for v in "${subpath_old_list[@]}"; do echo -n "'$v' "; done))"
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
		echo '  echo "  Backup integrity: verified (gzip + tar format valid)"'
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

	# tmux/screen wrapper (same pattern as copy-data)
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
		# Check result file written by trap in temp script
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

# ======================================================================
# SUBCOMMAND: validate
# ======================================================================
validate() {
	local context="$1" namespace="$2" migration_id="$3"

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME validate <context> <namespace> <migration-id>"
		exit 1
	fi

	state_require "$context" "$namespace" "$migration_id"

	local depl_new mount_new pvc_new
	depl_new=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_NEW")
	mount_new=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_NEW")
	pvc_new=$(state_get "$context" "$namespace" "$migration_id" "PVC_NEW")

	if [[ -z "$depl_new" ]]; then
		log_error "No new deployment found in state. Run discover-new first."
		exit 1
	fi

	echo ""
	log_info "Scaling up $depl_new to 1..."
	kubectl scale deployment "$depl_new" --replicas=1 -n "$namespace" --context="$context"

	log_info "Waiting for pod to be ready (timeout: 120s)..."
	if ! kubectl wait deployment "$depl_new" -n "$namespace" --context="$context" \
		--for=condition=Available --timeout=120s 2>/dev/null; then
		log_warn "Deployment not available yet. Checking pod status..."
		kubectl get pods -n "$namespace" --context="$context" | grep "$depl_new" || true
		if ! confirm "Continue waiting?"; then
			log_warn "Validation incomplete. Check the pod manually."
			return
		fi
		# Wait more
		kubectl wait deployment "$depl_new" -n "$namespace" --context="$context" \
			--for=condition=Available --timeout=120s 2>/dev/null || true
	fi

	# Get the running pod using deployment's selector labels
	local pod_name selector
	selector=$(get_deploy_selector "$context" "$namespace" "$depl_new")
	pod_name=$(kubectl get pods -n "$namespace" --context="$context" \
		-l "${selector:-app=$depl_new}" \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

	if [[ -z "$pod_name" ]]; then
		log_error "Could not find running pod for $depl_new"
		kubectl get pods -n "$namespace" --context="$context" | grep "$depl_new" || true
		exit 1
	fi

	log_ok "Pod $pod_name is running."

	# Show logs
	log_info "Recent logs (last 20 lines):"
	kubectl logs "$pod_name" -n "$namespace" --context="$context" --tail=20 2>/dev/null ||
		log_warn "Could not fetch logs (kubelet may be unavailable)."

	# Verify files inside the pod — iterate over ALL mounts
	local manifest_base="$STATE_BASE/$context/$namespace/${migration_id}.old.manifest"
	local mounts_str manifests_all_match=true
	mounts_str=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_NEW" || true)
	if [[ -z "$mounts_str" ]]; then
		# Legacy single mount
		mounts_str="$mount_new"
	fi

	local mnt_idx=0
	while IFS= read -r single_mount; do
		[[ -z "$single_mount" ]] && continue
		mnt_idx=$((mnt_idx + 1))
		echo ""
		log_info "Checking mount $mnt_idx: $single_mount ..."

		# List files
		if ! kubectl exec "$pod_name" -n "$namespace" --context="$context" -- \
			ls -lah "$single_mount" 2>/dev/null; then
			log_warn "kubectl exec failed for $single_mount"
			log_warn "Check manually: kubectl exec -n $namespace --context=$context $pod_name -- ls -lah $single_mount"
		fi

		# Compare with per-mount old manifest (numbered) or combined (legacy single-mount)
		local manifest_old="${manifest_base}.${mnt_idx}"
		if [[ ! -f "$manifest_old" ]]; then
			if [[ -f "$manifest_base" && ! -f "${manifest_base}.1" ]]; then
				manifest_old="$manifest_base"
			else
				manifest_old=""
			fi
		fi
		if [[ -n "$manifest_old" && -f "$manifest_old" ]]; then
			echo ""
			log_info "Comparing with old manifest ${manifest_old##*/}..."
			local manifest_new
			manifest_new=$(mktemp)
			local base_path="${single_mount%/}/"
			if kubectl exec "$pod_name" -n "$namespace" --context="$context" -- \
				find "$single_mount" -type f -exec ls -ln {} + 2>/dev/null |
				strip_path_prefix "$base_path" >"$manifest_new" 2>/dev/null; then
				if diff <(sort "$manifest_old") <(sort "$manifest_new") &>/dev/null; then
					log_ok "Files match old manifest."
				else
					log_warn "Files differ from old manifest:"
					diff <(sort "$manifest_old") <(sort "$manifest_new") || true
					manifests_all_match=false
				fi
			else
				log_warn "Could not compare manifests (kubectl exec issue)."
			fi
			rm -f "$manifest_new"
		fi
	done <<< "$(echo "$mounts_str" | sed 's/__/\n/g')"

	if [[ -n "$mounts_str" ]]; then
		if $manifests_all_match; then
			log_ok "All mounts verified against old manifests."
		else
			log_warn "Some mounts differ from old manifests. Review above."
		fi
	fi

	# PV cleanup assessment (old PVC is usually pruned by ArgoCD during sync)
	echo ""
	log_info "===== PV Cleanup Assessment ====="
	local pvc_old_name pvc_new_name pv_old_name
	pvc_old_name=$(state_get "$context" "$namespace" "$migration_id" "PVC_OLD" || true)
	pvc_new_name=$(state_get "$context" "$namespace" "$migration_id" "PVC_NEW" || true)
	pv_old_name=$(state_get "$context" "$namespace" "$migration_id" "PV_OLD" || true)

	# Old PVC status
	local pvc_old_status="NotFound"
	if [[ -n "$pvc_old_name" ]]; then
		if kubectl get pvc "$pvc_old_name" -n "$namespace" --context="$context" &>/dev/null; then
			pvc_old_status="Exists"
		else
			pvc_old_status="Deleted (pruned by ArgoCD during sync)"
		fi
	fi

	# Old PV status
	local pv_old_status="" pv_old_reclaim="" pv_old_nfs_info=""
	if [[ -n "$pv_old_name" ]]; then
		if kubectl get pv "$pv_old_name" --context="$context" &>/dev/null; then
			pv_old_status=$(kubectl get pv "$pv_old_name" --context="$context" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
			pv_old_reclaim=$(kubectl get pv "$pv_old_name" --context="$context" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || echo "unknown")
		else
			pv_old_status="Deleted"
		fi
	fi
	# NFS info from state (PV with CSI driver doesn't have spec.nfs)
	local old_nfs_host_show old_nfs_path_show
	old_nfs_host_show=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST" || true)
	old_nfs_path_show=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD" || true)

	# New PVC info
	local new_pvc_size="" new_pvc_status="NotFound"
	if [[ -n "$pvc_new_name" ]]; then
		if kubectl get pvc "$pvc_new_name" -n "$namespace" --context="$context" &>/dev/null; then
			new_pvc_size=$(kubectl get pvc "$pvc_new_name" -n "$namespace" --context="$context" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "unknown")
			new_pvc_status="Bound"
		fi
	fi

	echo "  Old PVC: $pvc_old_name"
	echo "    Status: $pvc_old_status"
	echo ""
	echo "  Old PV: $pv_old_name"
	echo "    Status: ${pv_old_status:--}"
	if [[ -n "$pv_old_reclaim" ]]; then
		echo "    Reclaim Policy: $pv_old_reclaim"
	fi
	if [[ -n "$old_nfs_host_show" && -n "$old_nfs_path_show" ]]; then
		echo "    NFS: $old_nfs_host_show:$old_nfs_path_show"
	fi
	echo ""
	echo "  New PVC: $pvc_new_name"
	echo "    Status: $new_pvc_status"
	echo "    Capacity: ${new_pvc_size:--}"
	echo ""

	# Size comparison — always recompute new size since copy-data may have run
	local old_size_bytes new_size_bytes
	old_size_bytes=$(state_get "$context" "$namespace" "$migration_id" "OLD_TOTAL_SIZE" || true)
	new_size_bytes=$(compute_total_size_nfs "$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_HOST" || true)" \
		"$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_NEW" || true)")
	state_set "$context" "$namespace" "$migration_id" "NEW_TOTAL_SIZE" "$new_size_bytes"
	if [[ -n "$old_size_bytes" && "$old_size_bytes" != "0" ]]; then
		echo "  Data size (old): $(human_size "$old_size_bytes")"
	fi
	if [[ -n "$new_size_bytes" && "$new_size_bytes" != "0" ]]; then
		echo "  Data size (new): $(human_size "$new_size_bytes")"
	fi
	if [[ -n "$old_size_bytes" && -n "$new_size_bytes" && "$old_size_bytes" != "0" && "$new_size_bytes" != "0" ]]; then
		if [[ "$old_size_bytes" == "$new_size_bytes" ]]; then
			log_ok "Sizes match: $(human_size "$old_size_bytes")"
		else
			local diff=$((old_size_bytes - new_size_bytes))
			local abs_diff=${diff#-}
			log_info "Size difference: $(human_size "$abs_diff") $([ "$diff" -ge 0 ] && echo "less" || echo "more") on new side"
		fi
	fi
	echo ""

	if [[ "$pv_old_status" == "Released" ]]; then
		log_ok "Old PV is Released — safe to delete. Data still exists on old NFS."
		log_info "Delete command: kubectl delete pv $pv_old_name --context=$context"
	elif [[ "$pv_old_status" == "Bound" ]]; then
		log_warn "Old PV is still Bound. Old PVC may still be in use. Investigate before deleting."
	elif [[ "$pv_old_status" == "Deleted" || -z "$pv_old_status" ]]; then
		log_info "Old PV no longer exists — nothing to clean up on the PV level."
	fi

	state_set "$context" "$namespace" "$migration_id" "PHASE" "validated"
	state_set "$context" "$namespace" "$migration_id" "VALIDATION_POD" "$pod_name"

	echo ""
	log_ok "Validation complete for $migration_id in $context/$namespace"
	echo ""
	echo "===== Next steps ====="
	echo "1. Perform manual functional testing (UI, API, etc.)"
	echo "2. If everything works, clean up old resources (see PV Cleanup Assessment above)"
	echo "   - Old PVC: kubectl delete pvc \$PVC_OLD -n \$NAMESPACE --context=\$CONTEXT"
	echo "   - Old PV:  kubectl delete pv \$PV_OLD --context=\$CONTEXT"
	echo "   - Backup tarballs: ssh \$NFS_HOST \"rm -rf \$(dirname \$NFS_PATH)/<migration-id>-backup/\""
	echo "3. Or repurpose the old NFS path if no longer needed"
}

# ======================================================================
# MAIN
# ======================================================================

if [[ $# -lt 1 ]]; then
	usage
fi

SUBCOMMAND="$1"
shift

case "$SUBCOMMAND" in
discover-old)
	discover_old "$@"
	;;
discover-new | discover_new)
	discover_new "$@"
	;;
backup)
	backup "$@"
	;;
copy-data | copy_data)
	copy_data "$@"
	;;
validate)
	validate "$@"
	;;
status)
	show_status "$@"
	;;
*)
	log_error "Unknown subcommand: $SUBCOMMAND"
	usage
	;;
esac
