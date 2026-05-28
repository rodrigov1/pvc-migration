# ---- File manifest helpers ----

strip_path_prefix() {
	local base="$1"
	awk -v base="$base" '{
		path = $NF
		if (index(path, base) == 1) {
			rel = substr(path, length(base) + 1)
		} else {
			rel = path
		}
		print $5, $3, $4, rel
	}'
}

capture_file_manifest() {
	local ctx="$1" ns="$2" pod="$3" mount_path="$4" outfile="$5"
	log_info "Capturing file manifest from pod $pod:$mount_path ..."
	local base_path="${mount_path%/}/"
	kubectl exec "$pod" -n "$ns" --context="$ctx" -- \
		find "$mount_path" -type f -exec ls -ln {} + 2>/dev/null |
		strip_path_prefix "$base_path" >"$outfile" || {
		log_warn "kubectl exec failed (may be transient)."
		return 1
	}
	log_ok "Manifest saved: $outfile"
}

capture_file_manifest_nfs() {
	local nfs_host="$1" nfs_path="$2" outfile="$3"
	log_info "Capturing file manifest via SSH to $nfs_host:$nfs_path ..."
	ssh "$nfs_host" "find '$nfs_path' -type f -printf '%s %U %G %P\n'" 2>/dev/null >"$outfile" || {
		log_error "SSH to $nfs_host failed"
		return 1
	}
	log_ok "Manifest saved: $outfile"
}
