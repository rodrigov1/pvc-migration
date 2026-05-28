# ---- NFS / size helpers ----

parse_volume_handle() {
	local vh="$1"
	local var_prefix="$2" # e.g. "OLD" or "NEW"
	local host share pv_uid rest

	IFS='#' read -r host share pv_uid rest <<<"$vh"

	if [[ -z "$host" || -z "$share" || -z "$pv_uid" ]]; then
		log_warn "Could not parse volumeHandle: $vh"
		log_warn "Set ${var_prefix}_NFS_HOST, ${var_prefix}_NFS_SHARE, ${var_prefix}_PV_UID manually in state file."
		return 1
	fi

	host=$(echo "$host" | xargs)
	share=$(echo "$share" | xargs)
	pv_uid=$(echo "$pv_uid" | xargs)

	echo "${var_prefix}_NFS_HOST=${host}"
	echo "${var_prefix}_NFS_SHARE_BASE=/${share}"
	echo "${var_prefix}_PV_UID=${pv_uid}"
}

human_size() {
	local bytes=$1
	if ((bytes >= 1073741824)); then
		echo "$(awk "BEGIN{printf \"%.1f\", $bytes/1073741824}") GiB"
	elif ((bytes >= 1048576)); then
		echo "$(awk "BEGIN{printf \"%.1f\", $bytes/1048576}") MiB"
	elif ((bytes >= 1024)); then
		echo "$(awk "BEGIN{printf \"%.1f\", $bytes/1024}") KiB"
	else
		echo "${bytes} B"
	fi
}

compute_total_size_manifest() {
	local manifest_file="$1"
	if [[ -f "$manifest_file" ]]; then
		awk '{s+=$1} END{print s+0}' "$manifest_file" 2>/dev/null || echo "0"
	else
		echo "0"
	fi
}

compute_total_size_nfs() {
	local nfs_host="$1" nfs_path="$2"
	ssh "$nfs_host" "du -sb '$nfs_path' 2>/dev/null | awk '{print \$1}'" 2>/dev/null || echo "0"
}

nfs_test_ssh() {
	local nfs_host="$1"
	ssh -o ConnectTimeout=5 -o BatchMode=yes "$nfs_host" "echo ok" 2>/dev/null
}
