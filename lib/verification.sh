# ---- Baseline verification helpers ----

VERIFY_FORMAT="baseline-v1"
BACKUP_METADATA_GENERATION=""
BACKUP_METADATA_MOUNT_COUNT=""
declare -A BACKUP_METADATA_DIGESTS=()
RECOVERED_BACKUP_BASE=""

verification_dir() {
	local context="$1" namespace="$2" migration_id="$3"
	printf '%s/%s.verify\n' "$STATE_BASE/$context/$namespace" "$migration_id"
}

verification_manifest_path() {
	local context="$1" namespace="$2" migration_id="$3" side="$4" mount_idx="$5" kind="$6"
	local generation
	generation=$(state_get "$context" "$namespace" "$migration_id" "VERIFY_${side}_GENERATION" || true)
	if [[ -n "$generation" ]]; then
		printf '%s/%s/%s.%s.nul\n' \
			"$(verification_dir "$context" "$namespace" "$migration_id")" "$generation" "$mount_idx" "$kind"
	else
		printf '%s/%s.%s.%s.nul\n' \
			"$(verification_dir "$context" "$namespace" "$migration_id")" "$side" "$mount_idx" "$kind"
	fi
}

verification_digest() {
	local manifest_file="$1"
	sha256sum -- "$manifest_file" | awk '{print $1}'
}

verification_find_current_backup() {
	local nfs_host="$1" backup_root="$2"
	RECOVERED_BACKUP_BASE=""
	if ! RECOVERED_BACKUP_BASE=$(ssh_bash "$nfs_host" \
		'root="${1%/}"; pointer="$root/current"; [[ -f "$pointer" ]] || exit 1; IFS= read -r selected < "$pointer"; [[ "$selected" == "$root/"* && -d "$selected" ]] || exit 1; printf "%s\n" "$selected"' \
		"$backup_root"); then
		RECOVERED_BACKUP_BASE=""
		return 1
	fi
}

verification_preflight_remote() {
	local nfs_host="$1" root="$2" remote_command

	printf -v remote_command 'bash -s -- %q' "$root"
	ssh "$nfs_host" "$remote_command" <<'REMOTE_VERIFY_PREFLIGHT'
set -euo pipefail
root="$1"
for required in bash find sort stat sha256sum readlink tar; do
	command -v "$required" >/dev/null 2>&1 || {
		printf 'Missing remote verification dependency: %s\n' "$required" >&2
		exit 1
	}
done
[[ -d "$root" && -r "$root" && -x "$root" ]] || {
	printf 'Remote verification root is not an accessible directory: %s\n' "$root" >&2
	exit 1
}
REMOTE_VERIFY_PREFLIGHT
}

verification_capture_remote() {
	local nfs_host="$1" root="$2" kind="$3" outfile="$4" remote_command

	printf -v remote_command 'bash -s -- %q %q' "$kind" "$root"
	ssh "$nfs_host" "$remote_command" >"$outfile" <<'REMOTE_VERIFY_SCRIPT'
set -euo pipefail

kind="$1"
root="${2%/}"
[[ -n "$root" ]] || root=/
export LC_ALL=C

for required in bash find sort stat sha256sum readlink; do
	command -v "$required" >/dev/null 2>&1 || {
		printf 'Missing remote verification dependency: %s\n' "$required" >&2
		exit 1
	}
done

quote_path() {
	printf '%q' "$1"
}

relative_path() {
	local path="$1"
	if [[ "$path" == "$root" ]]; then
		printf '.\n'
	else
		printf '%s\n' "${path#"$root"/}"
	fi
}

metadata_records() {
	local path rel type mode_hex mode_value mode uid gid size mtime target device stat_line seconds fraction mtime_text
	while IFS= read -r -d '' path; do
		rel=$(relative_path "$path")
		if ! stat_line=$(stat -c $'%f\t%u\t%g\t%s\t%Y\t%y\t%t:%T' -- "$path"); then
			printf 'Could not stat %s\n' "$path" >&2
			exit 1
		fi
		IFS=$'\t' read -r mode_hex uid gid size seconds mtime_text device <<<"$stat_line"
		mode_value=$((16#$mode_hex))
		if (( (mode_value & 0170000) == 0040000 )); then
			type=directory
		elif (( (mode_value & 0170000) == 0100000 )); then
			type=file
		elif (( (mode_value & 0170000) == 0120000 )); then
			type=symlink
		elif (( (mode_value & 0170000) == 0010000 )); then
			type=fifo
		elif (( (mode_value & 0170000) == 0020000 )); then
			type=character
		elif (( (mode_value & 0170000) == 0060000 )); then
			type=block
		elif (( (mode_value & 0170000) == 0140000 )); then
			type=socket
		else
			type=other
		fi
		mode=$(printf '%04o' "$((mode_value & 07777))")
		if [[ "$type" == file ]]; then
			:
		else
			size=-
		fi
		if [[ "$type" != character && "$type" != block ]]; then
			device=-
		fi
		fraction="${mtime_text##*.}"
		fraction="${fraction%% *}"
		[[ "$fraction" =~ ^[0-9]+$ ]] || {
			printf 'Invalid mtime for %s\n' "$path" >&2
			exit 1
		}
		mtime=$(printf '%s.%09d' "$seconds" "$((10#$fraction))")
		if [[ "$type" == symlink ]]; then
			target=$(quote_path "$(readlink -- "$path")")
		else
			target=-
		fi

		printf '%s %s %s %s %s %s %s %s %s\0' \
			"$type" "$mode" "$uid" "$gid" "$size" "$mtime" "$device" \
			"$(quote_path "$rel")" "$target"
	done < <(find -P "$root" -print0) | LC_ALL=C sort -z
}

content_records() {
	local path rel hash_line hash
	while IFS= read -r -d '' path; do
		rel=$(relative_path "$path")
		hash_line=$(sha256sum -- "$path")
		hash="${hash_line%% *}"
		hash="${hash#\\}"
		[[ "$hash" =~ ^[[:xdigit:]]{64}$ ]] || {
			printf 'Invalid SHA-256 for %s\n' "$path" >&2
			exit 1
		}
		printf '%s %s\0' "$hash" "$(quote_path "$rel")"
	done < <(find -P "$root" -type f -print0) | LC_ALL=C sort -z
}

[[ -d "$root" ]] || {
	printf 'Verification root does not exist: %s\n' "$root" >&2
	exit 1
}

case "$kind" in
	content) content_records ;;
	metadata) metadata_records ;;
	*) printf 'Unknown verification manifest kind: %s\n' "$kind" >&2; exit 1 ;;
esac
REMOTE_VERIFY_SCRIPT
}

verification_capture_mount_to_dir() {
	local nfs_host="$1" root="$2" mount_idx="$3" target_dir="$4"
	local content_file metadata_file content_tmp metadata_tmp

	content_file="$target_dir/${mount_idx}.content.nul"
	metadata_file="$target_dir/${mount_idx}.metadata.nul"
	mkdir -p "$target_dir"
	content_tmp=$(mktemp "${content_file}.XXXXXX")
	metadata_tmp=$(mktemp "${metadata_file}.XXXXXX")

	if ! verification_capture_remote "$nfs_host" "$root" content "$content_tmp" ||
		! verification_capture_remote "$nfs_host" "$root" metadata "$metadata_tmp"; then
		rm -f "$content_tmp" "$metadata_tmp"
		return 1
	fi

	mv -f "$content_tmp" "$content_file"
	mv -f "$metadata_tmp" "$metadata_file"
}

verification_capture_mount() {
	local context="$1" namespace="$2" migration_id="$3" side="$4" mount_idx="$5"
	local nfs_host="$6" root="$7" target_dir
	target_dir=$(dirname "$(verification_manifest_path "$context" "$namespace" "$migration_id" "$side" "$mount_idx" content)")
	verification_capture_mount_to_dir "$nfs_host" "$root" "$mount_idx" "$target_dir"
}

verification_capture_side() {
	local context="$1" namespace="$2" migration_id="$3" side="$4"
	local nfs_host="$5" nfs_root="$6" quiet="${7:-false}"
	local mount_count mount_idx subpath root verify_dir staging_dir generation generation_dir
	local -a subpaths=()

	state_get_mounts "$context" "$namespace" "$migration_id" "$side"
	mount_count="$MOUNT_COUNT"
	subpaths=("${SUBPATHS_LIST[@]}")
	if [[ "$mount_count" -le 0 || "${#subpaths[@]}" -ne "$mount_count" ]]; then
		log_error "Cannot create baseline manifest: invalid $side mount data."
		return 1
	fi
	verify_dir=$(verification_dir "$context" "$namespace" "$migration_id")
	mkdir -p "$verify_dir"
	staging_dir=$(mktemp -d "$verify_dir/.${side}.XXXXXX")
	generation="${side}.$(date -u +%Y%m%dT%H%M%SZ).$$.$RANDOM"
	generation_dir="$verify_dir/$generation"

	for ((mount_idx = 0; mount_idx < mount_count; mount_idx++)); do
		subpath="${subpaths[$mount_idx]}"
		root="${nfs_root}${subpath:+${subpath}/}"
		if ! $quiet; then
			log_info "Capturing $side baseline manifest for mount $((mount_idx + 1))..."
		fi
		if ! verification_capture_mount_to_dir "$nfs_host" "$root" \
			"$((mount_idx + 1))" "$staging_dir"; then
			log_error "Could not capture $side baseline manifest for mount $((mount_idx + 1))."
			rm -rf "$staging_dir"
			return 1
		fi
	done

	if ! mv "$staging_dir" "$generation_dir"; then
		rm -rf "$staging_dir"
		log_error "Could not publish the $side baseline generation."
		return 1
	fi
	state_set "$context" "$namespace" "$migration_id" "VERIFY_${side}_MOUNT_COUNT" "$mount_count"
	state_set "$context" "$namespace" "$migration_id" "VERIFY_FORMAT" "$VERIFY_FORMAT"
	state_set "$context" "$namespace" "$migration_id" "VERIFY_${side}_GENERATION" "$generation"
}

verification_side_ready() {
	local context="$1" namespace="$2" migration_id="$3" side="$4"
	local mount_count mount_idx content_file metadata_file
	mount_count=$(state_get "$context" "$namespace" "$migration_id" "VERIFY_${side}_MOUNT_COUNT" || true)
	if [[ -z "$mount_count" || ! "$mount_count" =~ ^[0-9]+$ || "$mount_count" -le 0 ]]; then
		return 1
	fi

	for ((mount_idx = 1; mount_idx <= mount_count; mount_idx++)); do
		content_file=$(verification_manifest_path "$context" "$namespace" "$migration_id" "$side" "$mount_idx" content)
		metadata_file=$(verification_manifest_path "$context" "$namespace" "$migration_id" "$side" "$mount_idx" metadata)
		[[ -f "$content_file" && -f "$metadata_file" ]] || return 1
	done
}

verification_check_backup_archives() {
	local context="$1" namespace="$2" migration_id="$3" nfs_host="$4" backup_base="$5" mount_count="$6"
	local mount_idx expected_digest actual_digest

	for ((mount_idx = 0; mount_idx < mount_count; mount_idx++)); do
		expected_digest=$(state_get "$context" "$namespace" "$migration_id" "BACKUP_ARCHIVE_DIGEST_${mount_idx}" || true)
		if [[ -z "$expected_digest" ]] ||
			! actual_digest=$(ssh_bash "$nfs_host" 'sha256sum -- "$1" | awk '\''{print $1}'\''' "${backup_base}/${mount_idx}.tgz") ||
			[[ "$actual_digest" != "$expected_digest" ]]; then
			log_error "Backup archive $mount_idx is missing or its SHA-256 digest does not match."
			return 1
		fi
	done
}

verification_load_backup_metadata() {
	local nfs_host="$1" backup_base="$2" metadata line key value
	BACKUP_METADATA_GENERATION=""
	BACKUP_METADATA_MOUNT_COUNT=""
	BACKUP_METADATA_DIGESTS=()

	if ! metadata=$(ssh_run "$nfs_host" cat -- "$backup_base/metadata.env"); then
		return 1
	fi
	while IFS= read -r line; do
		key="${line%%=*}"
		value="${line#*=}"
		case "$key" in
		VERIFY_OLD_GENERATION)
			[[ "$value" =~ ^OLD\.[a-zA-Z0-9_.-]+$ ]] || return 1
			BACKUP_METADATA_GENERATION="$value"
			;;
		MOUNT_COUNT)
			[[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || return 1
			BACKUP_METADATA_MOUNT_COUNT="$value"
			;;
		ARCHIVE_*_SHA256)
			[[ "$key" =~ ^ARCHIVE_([0-9]+)_SHA256$ ]] || return 1
			[[ "$value" =~ ^[[:xdigit:]]{64}$ ]] || return 1
			BACKUP_METADATA_DIGESTS["${key#ARCHIVE_}"]="$value"
			;;
		*) return 1 ;;
		esac
	done <<<"$metadata"

	[[ -n "$BACKUP_METADATA_GENERATION" && -n "$BACKUP_METADATA_MOUNT_COUNT" ]] || return 1
	local mount_idx digest_key
	for ((mount_idx = 0; mount_idx < BACKUP_METADATA_MOUNT_COUNT; mount_idx++)); do
		digest_key="${mount_idx}_SHA256"
		[[ -n "${BACKUP_METADATA_DIGESTS[$digest_key]:-}" ]] || return 1
	done
}

verification_hydrate_backup_state() {
	local context="$1" namespace="$2" migration_id="$3" nfs_host="$4" backup_base="$5"
	local existing_value metadata_digest digest_key mount_idx

	verification_load_backup_metadata "$nfs_host" "$backup_base" || return 1

	# Validate every existing value before changing state, so conflicts cannot
	# leave a partially hydrated backup selection.
	existing_value=$(state_get "$context" "$namespace" "$migration_id" "BACKUP_BASE_OLD" || true)
	if [[ -n "$existing_value" && "$existing_value" != "$backup_base" ]]; then
		return 1
	fi
	existing_value=$(state_get "$context" "$namespace" "$migration_id" "BACKUP_VERIFY_OLD_GENERATION" || true)
	if [[ -n "$existing_value" && "$existing_value" != "$BACKUP_METADATA_GENERATION" ]]; then
		return 1
	fi
	existing_value=$(state_get "$context" "$namespace" "$migration_id" "BACKUP_MOUNT_COUNT" || true)
	if [[ -n "$existing_value" && "$existing_value" != "$BACKUP_METADATA_MOUNT_COUNT" ]]; then
		return 1
	fi
	for ((mount_idx = 0; mount_idx < BACKUP_METADATA_MOUNT_COUNT; mount_idx++)); do
		digest_key="${mount_idx}_SHA256"
		metadata_digest="${BACKUP_METADATA_DIGESTS[$digest_key]}"
		existing_value=$(state_get "$context" "$namespace" "$migration_id" "BACKUP_ARCHIVE_DIGEST_${mount_idx}" || true)
		if [[ -n "$existing_value" && "$existing_value" != "$metadata_digest" ]]; then
			return 1
		fi
	done
	existing_value=$(state_get "$context" "$namespace" "$migration_id" "VERIFY_OLD_GENERATION" || true)
	if [[ -z "$existing_value" ]]; then
		if [[ ! -d "$(verification_dir "$context" "$namespace" "$migration_id")/$BACKUP_METADATA_GENERATION" ]]; then
			return 1
		fi
	elif [[ "$existing_value" != "$BACKUP_METADATA_GENERATION" ]]; then
		return 1
	fi

	state_set "$context" "$namespace" "$migration_id" "BACKUP_BASE_OLD" "$backup_base"
	state_set "$context" "$namespace" "$migration_id" "BACKUP_VERIFY_OLD_GENERATION" "$BACKUP_METADATA_GENERATION"
	state_set "$context" "$namespace" "$migration_id" "BACKUP_MOUNT_COUNT" "$BACKUP_METADATA_MOUNT_COUNT"
	for ((mount_idx = 0; mount_idx < BACKUP_METADATA_MOUNT_COUNT; mount_idx++)); do
		digest_key="${mount_idx}_SHA256"
		state_set "$context" "$namespace" "$migration_id" "BACKUP_ARCHIVE_DIGEST_${mount_idx}" \
			"${BACKUP_METADATA_DIGESTS[$digest_key]}"
	done
	state_set "$context" "$namespace" "$migration_id" "VERIFY_OLD_GENERATION" "$BACKUP_METADATA_GENERATION"
	state_set "$context" "$namespace" "$migration_id" "VERIFY_OLD_MOUNT_COUNT" "$BACKUP_METADATA_MOUNT_COUNT"
}

verification_compare_sides() {
	local context="$1" namespace="$2" migration_id="$3"
	local old_count new_count mount_idx old_content new_content old_metadata new_metadata
	local old_digest new_digest old_metadata_digest new_metadata_digest all_ok=true

	old_count=$(state_get "$context" "$namespace" "$migration_id" "VERIFY_OLD_MOUNT_COUNT" || true)
	new_count=$(state_get "$context" "$namespace" "$migration_id" "VERIFY_NEW_MOUNT_COUNT" || true)
	if [[ -z "$old_count" || -z "$new_count" || "$old_count" != "$new_count" ]]; then
		log_error "Baseline verification failed: old/new mount counts differ."
		state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
		return 1
	fi

	for ((mount_idx = 1; mount_idx <= old_count; mount_idx++)); do
		old_content=$(verification_manifest_path "$context" "$namespace" "$migration_id" OLD "$mount_idx" content)
		new_content=$(verification_manifest_path "$context" "$namespace" "$migration_id" NEW "$mount_idx" content)
		old_metadata=$(verification_manifest_path "$context" "$namespace" "$migration_id" OLD "$mount_idx" metadata)
		new_metadata=$(verification_manifest_path "$context" "$namespace" "$migration_id" NEW "$mount_idx" metadata)
		if [[ ! -f "$old_content" || ! -f "$new_content" ||
			! -f "$old_metadata" || ! -f "$new_metadata" ]]; then
			log_error "Baseline manifest missing on mount $mount_idx."
			all_ok=false
			continue
		fi

		if ! cmp -s "$old_content" "$new_content"; then
			log_error "Baseline content mismatch on mount $mount_idx."
			all_ok=false
		fi
		if ! cmp -s "$old_metadata" "$new_metadata"; then
			log_error "Baseline metadata mismatch on mount $mount_idx."
			all_ok=false
		fi
		old_digest=$(verification_digest "$old_content")
		new_digest=$(verification_digest "$new_content")
		old_metadata_digest=$(verification_digest "$old_metadata")
		new_metadata_digest=$(verification_digest "$new_metadata")
		state_set "$context" "$namespace" "$migration_id" "VERIFY_OLD_CONTENT_DIGEST_${mount_idx}" "$old_digest"
		state_set "$context" "$namespace" "$migration_id" "VERIFY_NEW_CONTENT_DIGEST_${mount_idx}" "$new_digest"
		state_set "$context" "$namespace" "$migration_id" "VERIFY_OLD_METADATA_DIGEST_${mount_idx}" "$old_metadata_digest"
		state_set "$context" "$namespace" "$migration_id" "VERIFY_NEW_METADATA_DIGEST_${mount_idx}" "$new_metadata_digest"
	done

	if $all_ok; then
		state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "passed"
		return 0
	fi
	state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
	return 1
}

verification_capture_and_compare() {
	local context="$1" namespace="$2" migration_id="$3" nfs_host_old="$4" nfs_root_old="$5"
	local nfs_host_new="$6" nfs_root_new="$7"

	if ! verification_capture_side "$context" "$namespace" "$migration_id" OLD \
		"$nfs_host_old" "$nfs_root_old"; then
		state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
		return 1
	fi
	if ! verification_capture_side "$context" "$namespace" "$migration_id" NEW \
		"$nfs_host_new" "$nfs_root_new"; then
		state_set "$context" "$namespace" "$migration_id" "VERIFY_STATUS" "failed"
		return 1
	fi
	verification_compare_sides "$context" "$namespace" "$migration_id"
}
