#!/bin/bash
set -euo pipefail

SCRIPT_NAME=$(basename "$0")
STATE_BASE="$HOME/.pvc-migration/state"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

confirm() {
	local prompt="$1"
	local response
	echo -en "${YELLOW}${prompt} [y/N]${NC} "
	read -r response
	[[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}

confirm_default_yes() {
	local prompt="$1"
	local response
	echo -en "${YELLOW}${prompt} [Y/n]${NC} "
	read -r response
	[[ -z "$response" || "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}

usage() {
	cat <<EOF
Usage: $SCRIPT_NAME <subcommand> [options]

Subcommands:
  discover-old <context> <namespace> <migration-id> --deploy <deploy> --pvc <pvc>
    Discover and capture old-side PVC/PV/NFS state from the cluster.

  discover-new <context> <namespace> <migration-id> [--deploy <deploy>] [--pvc <pvc>]
    Discover and capture new-side PVC/PV/NFS state after chart impact.
    --deploy is needed if the new deployment name differs from the old one.

  backup <context> <namespace> <migration-id>
    Backup old NFS data to tarballs BEFORE deploying the new chart
    (required when PV has ReclaimPolicy:Delete). Creates per-mount .tgz
    files at share level on the old NFS host.

  copy-data <context> <namespace> <migration-id> [--compress]
    Copy data from old NFS path to new NFS path via tar-pipe over SSH.
    If the old NFS source is no longer available, automatically restores
    from backup created by the 'backup' subcommand.
    Add --compress for slow links. Shows progress via pv if available.

  validate <context> <namespace> <migration-id>
    Scale up the new deployment, wait for readiness, verify files inside the pod.

  cleanup <context> <namespace> <migration-id>
    Remove old deployment and notify about old PVC retention.

  status <context> <namespace> <migration-id>
    Show current state file contents.

State files: \$STATE_BASE/<context>/<namespace>/<migration-id>.env

Examples (retain — no backup needed):
  \$SCRIPT_NAME discover-old prod n8n redis-famaf --deploy n8n-redis-famaf --pvc n8n-redis-famaf-deployment-pvc
  \$SCRIPT_NAME discover-new prod n8n redis-famaf --deploy redis-famaf
  \$SCRIPT_NAME copy-data prod n8n redis-famaf
  \$SCRIPT_NAME validate prod n8n redis-famaf
  \$SCRIPT_NAME cleanup prod n8n redis-famaf

Examples (ReclaimPolicy:Delete — backup first):
  \$SCRIPT_NAME discover-old prod nahuel nahuel-java --deploy nahuel-nahuel-java --pvc nahuel-nfs-pvc
  \$SCRIPT_NAME backup prod nahuel nahuel-java
  # Now deploy the new chart (helm upgrade), then:
  \$SCRIPT_NAME discover-new prod nahuel nahuel-java --deploy nahuel-java
  \$SCRIPT_NAME copy-data prod nahuel nahuel-java
  \$SCRIPT_NAME validate prod nahuel nahuel-java
  \$SCRIPT_NAME cleanup prod nahuel nahuel-java
EOF
	exit 1
}

# ---- State file helpers ----

state_file_path() {
	echo "$STATE_BASE/$1/$2/$3.env"
}

state_require() {
	local sf
	sf=$(state_file_path "$1" "$2" "$3")
	if [[ ! -f "$sf" ]]; then
		log_error "State file not found: $sf"
		log_error "Run 'discover-old' first."
		exit 1
	fi
	# shellcheck disable=SC1090
	source "$sf"
}

state_get() {
	local sf key value
	sf=$(state_file_path "$1" "$2" "$3")
	key="$4"
	if [[ -f "$sf" ]]; then
		value=$(grep "^${key}=" "$sf" 2>/dev/null | cut -d= -f2-) || true
		echo "$value"
	fi
}

state_set() {
	local sf
	sf=$(state_file_path "$1" "$2" "$3")
	mkdir -p "$(dirname "$sf")"
	if [[ ! -f "$sf" ]]; then
		touch "$sf"
	fi
	# Escape & and / for sed
	local key="$4" value="$5"
	if grep -q "^${key}=" "$sf" 2>/dev/null; then
		sed -i "s|^${key}=.*|${key}=${value}|" "$sf"
	else
		echo "${key}=${value}" >>"$sf"
	fi
}

state_append() {
	local sf
	sf=$(state_file_path "$1" "$2" "$3")
	mkdir -p "$(dirname "$sf")"
	local key="$4" value="$5"
	local current
	current=$(state_get "$1" "$2" "$3" "$key" || true)
	if [[ -n "$current" ]]; then
		state_set "$1" "$2" "$3" "$key" "${current}__${value}"
	else
		state_set "$1" "$2" "$3" "$key" "$value"
	fi
}

state_del() {
	local sf
	sf=$(state_file_path "$1" "$2" "$3")
	local key="$4"
	if [[ -f "$sf" ]]; then
		sed -i "/^${key}=/d" "$sf"
	fi
}

# ---- NFS path helpers ----

parse_volume_handle() {
	local vh="$1"
	local var_prefix="$2" # e.g. "OLD" or "NEW"
	local host share pv_uid rest

	IFS='#' read -r host share pv_uid rest <<<"$vh"

	# Validate
	if [[ -z "$host" || -z "$share" || -z "$pv_uid" ]]; then
		log_warn "Could not parse volumeHandle: $vh"
		log_warn "Set ${var_prefix}_NFS_HOST, ${var_prefix}_NFS_SHARE, ${var_prefix}_PV_UID manually in state file."
		return 1
	fi

	# Remove trailing/leading whitespace
	host=$(echo "$host" | xargs)
	share=$(echo "$share" | xargs)
	pv_uid=$(echo "$pv_uid" | xargs)

	echo "${var_prefix}_NFS_HOST=${host}"
	echo "${var_prefix}_NFS_SHARE_BASE=/${share}"
	echo "${var_prefix}_PV_UID=${pv_uid}"
}

get_deploy_selector() {
	local ctx="$1" ns="$2" deploy="$3"
	kubectl get deployment "$deploy" -n "$ns" --context="$ctx" -o json 2>/dev/null |
		jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null || true
}

get_pod_for_deploy() {
	local ctx="$1" ns="$2" deploy="$3"
	local selector
	selector=$(get_deploy_selector "$ctx" "$ns" "$deploy")
	if [[ -z "$selector" ]]; then
		log_warn "Could not get selector for deployment $deploy, falling back to label app=$deploy"
		selector="app=$deploy"
	fi
	kubectl get pods -n "$ns" --context="$ctx" \
		-o jsonpath='{.items[0].metadata.name}' \
		-l "$selector" 2>/dev/null || true
}

get_deployments_by_pattern() {
	local ctx="$1" ns="$2" pattern="$3"
	kubectl get deployments -n "$ns" --context="$ctx" \
		-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
		grep -i "$pattern" || true
}

get_pvcs_by_pattern() {
	local ctx="$1" ns="$2" pattern="$3"
	kubectl get pvc -n "$ns" --context="$ctx" \
		-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
		grep -i "$pattern" || true
}

get_pv_from_pvc() {
	local ctx="$1" ns="$2" pvc="$3"
	kubectl get pvc "$pvc" -n "$ns" --context="$ctx" \
		-o jsonpath='{.spec.volumeName}' 2>/dev/null || true
}

get_volume_handle() {
	local ctx="$1" pv="$2"
	kubectl get pv "$pv" --context="$ctx" \
		-o jsonpath='{.spec.csi.volumeHandle}' 2>/dev/null || true
}

get_nfs_from_pv() {
	local ctx="$1" pv="$2"
	local server path
	server=$(kubectl get pv "$pv" --context="$ctx" -o jsonpath='{.spec.nfs.server}' 2>/dev/null || true)
	path=$(kubectl get pv "$pv" --context="$ctx" -o jsonpath='{.spec.nfs.path}' 2>/dev/null || true)
	if [[ -n "$server" && -n "$path" ]]; then
		echo "NFS_HOST=${server}"
		echo "NFS_SHARE_BASE=${path}"
	fi
}

get_volume_mounts_from_deploy() {
	local ctx="$1" ns="$2" deploy="$3" vol_name="$4"
	# Get the mount path from the deployment for the given volume
	kubectl get deployment "$deploy" -n "$ns" --context="$ctx" \
		-o jsonpath="{range .spec.template.spec.containers[0].volumeMounts[?(@.name=='$vol_name')]}@{.mountPath}|{.subPath}{'\n'}{end}" 2>/dev/null || true
}

get_pvc_volume_name() {
	local ctx="$1" ns="$2" pvc="$3"
	kubectl get pvc "$pvc" -n "$ns" --context="$ctx" \
		-o jsonpath='{.spec.volumeName}' 2>/dev/null || true
}

# ---- Size helpers ----

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
	# Ensure trailing / for clean strip
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

# ======================================================================
# SUBCOMMAND: discover-old
# ======================================================================
discover_old() {
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

	# Check existing state
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

	# Sanity check: detect if PVC looks like 4.3.2 naming (means chart was already synced)
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

	# Verify resources exist
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

	# Get PV
	local pv_old
	pv_old=$(get_pv_from_pvc "$context" "$namespace" "$pvc_old")
	log_info "Found PV: $pv_old"

	# Get volumeHandle
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

	# Write basic info to state
	state_set "$context" "$namespace" "$migration_id" "PHASE" "discovered-old"
	state_set "$context" "$namespace" "$migration_id" "CONTEXT" "$context"
	state_set "$context" "$namespace" "$migration_id" "NAMESPACE" "$namespace"
	state_set "$context" "$namespace" "$migration_id" "APP" "$migration_id"
	state_set "$context" "$namespace" "$migration_id" "DEPLOY_OLD" "$deploy_old"
	state_set "$context" "$namespace" "$migration_id" "PVC_OLD" "$pvc_old"
	state_set "$context" "$namespace" "$migration_id" "PV_OLD" "$pv_old"
	state_set "$context" "$namespace" "$migration_id" "VOLUME_HANDLE_OLD" "$volume_handle_old"

	# Parse volumeHandle to extract NFS info
	if [[ -n "$volume_handle_old" ]]; then
		local parsed
		parsed=$(parse_volume_handle "$volume_handle_old" "OLD") || true
		if [[ -n "$parsed" ]]; then
			echo "$parsed" | while IFS='=' read -r key value; do
				state_set "$context" "$namespace" "$migration_id" "$key" "$value"
			done
		fi
	fi

	# If we also have direct NFS from PV, use it
	local nfs_direct
	nfs_direct=$(get_nfs_from_pv "$context" "$pv_old") || true
	if [[ -n "$nfs_direct" ]]; then
		echo "$nfs_direct" | while IFS='=' read -r key value; do
			state_set "$context" "$namespace" "$migration_id" "OLD_${key}" "$value"
		done
	fi

	# Find the volume name from the PVC and capture ALL volume mounts
	local claim_name vol_in_deploy
	claim_name="$pvc_old"
	vol_in_deploy=$(kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" \
		-o jsonpath="{range .spec.template.spec.volumes[?(@.persistentVolumeClaim.claimName=='$claim_name')]}{.name}{'\n'}{end}" 2>/dev/null) || true

	if [[ -n "$vol_in_deploy" ]]; then
		log_info "Found volume in deployment: $vol_in_deploy"
		# Clear previous mount data (for re-discover)
		state_del "$context" "$namespace" "$migration_id" "MOUNT_OLD"
		state_del "$context" "$namespace" "$migration_id" "SUBPATH_OLD"

		# Iterate over ALL volume mounts for this volume (a PVC can have multiple mounts with different subPaths)
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
		# Fallback: try to find any mount that references this PVC
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

	# Build the NFS path (always PV root — subpaths appended per-mount during copy)
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

	# Capture file manifests
	local manifest_base="$STATE_BASE/$context/$namespace/${migration_id}.old.manifest"
	local pod_name
	pod_name=$(get_pod_for_deploy "$context" "$namespace" "$deploy_old")

	# Per-mount manifests from running pod (primary for multi-mount validate) — parallel
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
		# Combined NFS manifest as fallback (single-mount or no-pod scenarios)
		if [[ -n "$nfs_host" && -n "${nfs_path_old:-}" ]] && ssh "$nfs_host" "test -d '$nfs_path_old'" 2>/dev/null; then
			capture_file_manifest_nfs "$nfs_host" "$nfs_path_old" "$manifest_base" 2>/dev/null || true
		fi
	fi

	# Compute total size via du -sb (instant, filesystem-level)
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

# ======================================================================
# SUBCOMMAND: discover-new
# ======================================================================
discover_new() {
	local context="" namespace="" migration_id="" deploy_new="" pvc_new=""

	context="$1"
	shift || true
	namespace="$1"
	shift || true
	migration_id="$1"
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--deploy)
			deploy_new="$2"
			shift 2
			;;
		--pvc)
			pvc_new="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			usage
			;;
		esac
	done

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME discover-new <context> <namespace> <migration-id> [--deploy <deploy>] [--pvc <pvc>]"
		exit 1
	fi

	state_require "$context" "$namespace" "$migration_id"

	# Discover new deployment
	if [[ -z "$deploy_new" ]]; then
		local matches
		matches=$(get_deployments_by_pattern "$context" "$namespace" "$migration_id")
		if [[ -z "$matches" ]]; then
			log_error "No deployments found matching '$migration_id' in $context/$namespace"
			log_info "Available deployments:"
			kubectl get deployments -n "$namespace" --context="$context" \
				-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
				while IFS= read -r d; do echo "  - $d"; done
			log_error "Re-run with --deploy <name> to specify the correct deployment."
			exit 1
		fi
		local count
		count=$(echo "$matches" | wc -l)
		if [[ "$count" -gt 1 ]]; then
			local deploy_old
			deploy_old=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_OLD" || true)
			local filtered=""
			if [[ -n "$deploy_old" ]]; then
				filtered=$(echo "$matches" | grep -v "^${deploy_old}$" || true)
			fi
			if [[ -n "$filtered" ]]; then
				count=$(echo "$filtered" | wc -l)
				if [[ "$count" -eq 1 ]]; then
					deploy_new="$filtered"
				else
					log_warn "Multiple deployments match '$migration_id':"
					echo "$filtered"
					deploy_new=$(echo "$filtered" | head -1)
					log_info "Picked: $deploy_new"
					if ! confirm "Use this deployment?"; then
						log_error "Re-run with --deploy to specify the correct deployment."
						exit 1
					fi
				fi
			else
				log_warn "Multiple deployments match '$migration_id':"
				echo "$matches"
				deploy_new=$(echo "$matches" | head -1)
				log_info "Picked: $deploy_new"
				if ! confirm "Use this deployment?"; then
					log_error "Re-run with --deploy to specify the correct deployment."
					exit 1
				fi
			fi
		else
			deploy_new="$matches"
		fi
		log_info "Found new deployment: $deploy_new"
	else
		log_info "Using specified deployment: $deploy_new"
	fi

	# Discover new PVC
	if [[ -z "$pvc_new" ]]; then
		local matches
		matches=$(get_pvcs_by_pattern "$context" "$namespace" "$migration_id")
		if [[ -z "$matches" ]]; then
			log_error "No PVCs found matching '$migration_id' in $context/$namespace"
			log_info "Available PVCs:"
			kubectl get pvc -n "$namespace" --context="$context" \
				-o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null |
				while IFS= read -r p; do echo "  - $p"; done
			log_error "Re-run with --pvc <name> to specify the correct PVC."
			exit 1
		fi
		local count
		count=$(echo "$matches" | wc -l)
		if [[ "$count" -gt 1 ]]; then
			local pvc_old
			pvc_old=$(state_get "$context" "$namespace" "$migration_id" "PVC_OLD" || true)
			local filtered=""
			if [[ -n "$pvc_old" ]]; then
				filtered=$(echo "$matches" | grep -v "^${pvc_old}$" || true)
			fi
			if [[ -n "$filtered" ]]; then
				count=$(echo "$filtered" | wc -l)
				if [[ "$count" -eq 1 ]]; then
					pvc_new="$filtered"
				else
					log_warn "Multiple PVCs match '$migration_id':"
					echo "$filtered"
					pvc_new=$(echo "$filtered" | head -1)
					log_info "Picked: $pvc_new"
					if ! confirm "Use this PVC?"; then
						log_error "Re-run with --pvc to specify the correct PVC."
						exit 1
					fi
				fi
			else
				log_warn "Multiple PVCs match '$migration_id':"
				echo "$matches"
				pvc_new=$(echo "$matches" | head -1)
				log_info "Picked: $pvc_new"
				if ! confirm "Use this PVC?"; then
					log_error "Re-run with --pvc to specify the correct PVC."
					exit 1
				fi
			fi
		else
			pvc_new="$matches"
		fi
		log_info "Found new PVC: $pvc_new"
	else
		log_info "Using specified PVC: $pvc_new"
	fi

	# Get PV
	local pv_new
	pv_new=$(get_pv_from_pvc "$context" "$namespace" "$pvc_new")
	log_info "Found new PV: $pv_new"

	# Get volumeHandle
	local volume_handle_new
	volume_handle_new=$(get_volume_handle "$context" "$pv_new")
	if [[ -z "$volume_handle_new" ]]; then
		log_warn "No CSI volumeHandle found for PV $pv_new. Trying spec.nfs..."
		local nfs_info
		nfs_info=$(get_nfs_from_pv "$context" "$pv_new")
		if [[ -n "$nfs_info" ]]; then
			log_info "NFS info from PV: $nfs_info"
		fi
	else
		log_info "New VolumeHandle: $volume_handle_new"
	fi

	# Save direct NFS info from PV (spec.nfs) if available
	local nfs_direct_new
	nfs_direct_new=$(get_nfs_from_pv "$context" "$pv_new") || true
	if [[ -n "$nfs_direct_new" ]]; then
		echo "$nfs_direct_new" | while IFS='=' read -r key value; do
			state_set "$context" "$namespace" "$migration_id" "NEW_${key}" "$value"
		done
	fi

	# Write to state
	state_set "$context" "$namespace" "$migration_id" "PHASE" "discovered-new"
	state_set "$context" "$namespace" "$migration_id" "DEPLOY_NEW" "$deploy_new"
	state_set "$context" "$namespace" "$migration_id" "PVC_NEW" "$pvc_new"
	state_set "$context" "$namespace" "$migration_id" "PV_NEW" "$pv_new"
	state_set "$context" "$namespace" "$migration_id" "VOLUME_HANDLE_NEW" "$volume_handle_new"

	# Parse volumeHandle
	if [[ -n "$volume_handle_new" ]]; then
		local parsed
		parsed=$(parse_volume_handle "$volume_handle_new" "NEW") || true
		if [[ -n "$parsed" ]]; then
			echo "$parsed" | while IFS='=' read -r key value; do
				state_set "$context" "$namespace" "$migration_id" "$key" "$value"
			done
		fi
	fi

	# Find mount info from new deployment — capture ALL volume mounts
	local claim_name vol_in_deploy
	claim_name="$pvc_new"
	vol_in_deploy=$(kubectl get deployment "$deploy_new" -n "$namespace" --context="$context" \
		-o jsonpath="{range .spec.template.spec.volumes[?(@.persistentVolumeClaim.claimName=='$claim_name')]}{.name}{'\n'}{end}" 2>/dev/null) || true

	if [[ -n "$vol_in_deploy" ]]; then
		state_del "$context" "$namespace" "$migration_id" "MOUNT_NEW"
		state_del "$context" "$namespace" "$migration_id" "SUBPATH_NEW"

		local mount_idx=0 raw_mount raw_subpath
		while IFS='|' read -r raw_mount raw_subpath; do
			local mount_path="${raw_mount#@}"
			[[ -z "$mount_path" ]] && continue
			mount_idx=$((mount_idx + 1))
			log_info "New mount $mount_idx: $mount_path (subPath: ${raw_subpath:-<none>})"
			state_append "$context" "$namespace" "$migration_id" "MOUNT_NEW" "$mount_path"
			state_append "$context" "$namespace" "$migration_id" "SUBPATH_NEW" "${raw_subpath:-}"
		done < <(kubectl get deployment "$deploy_new" -n "$namespace" --context="$context" \
			-o jsonpath="{range .spec.template.spec.containers[0].volumeMounts[?(@.name=='$vol_in_deploy')]}@{.mountPath}|{.subPath}{'\n'}{end}" 2>/dev/null || true)
	else
		log_warn "Could not find volume name for PVC $pvc_new in deployment $deploy_new"
	fi

	# Build NFS path (always PV root — subpaths appended per-mount during copy)
	local nfs_host nfs_share_base pv_uid nfs_path_new
	nfs_host=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_HOST" || true)
	nfs_share_base=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_SHARE_BASE" || true)
	pv_uid=$(state_get "$context" "$namespace" "$migration_id" "NEW_PV_UID" || true)

	if [[ -n "$nfs_host" && -n "$nfs_share_base" && -n "$pv_uid" ]]; then
		nfs_path_new="${nfs_share_base}/${pv_uid}/"
		state_set "$context" "$namespace" "$migration_id" "NFS_PATH_NEW" "$nfs_path_new"
		log_ok "New NFS path (PV root): $nfs_host:$nfs_path_new"
	else
		log_warn "Could not construct new NFS path. Set NFS_PATH_NEW manually."
	fi

	# Check if old and new NFS backends differ
	local nfs_host_old nfs_path_old
	nfs_host_old=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST" || true)
	nfs_path_old=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD" || true)
	if [[ -n "$nfs_host" && -n "$nfs_host_old" && "$nfs_host" != "$nfs_host_old" ]]; then
		log_warn "NFS host changed: $nfs_host_old -> $nfs_host"
		log_warn "Cross-host copy will be required."
	fi

	# Check if new path exists
	if [[ -n "$nfs_host" && -n "${nfs_path_new:-}" ]]; then
		if ssh "$nfs_host" "test -d '$nfs_path_new'" 2>/dev/null; then
			log_warn "New NFS path ALREADY EXISTS: $nfs_host:$nfs_path_new"
			log_warn "Contents:"
			ssh "$nfs_host" "ls -lah '$nfs_path_new'" 2>/dev/null || true
			# Compute size if path already has data
			local new_total_bytes
			new_total_bytes=$(compute_total_size_nfs "$nfs_host" "$nfs_path_new")
			state_set "$context" "$namespace" "$migration_id" "NEW_TOTAL_SIZE" "$new_total_bytes"
			log_info "New data size: $(human_size "$new_total_bytes")"
		else
			log_info "New NFS path does not exist yet (expected). Will be created during copy-data."
			state_del "$context" "$namespace" "$migration_id" "NEW_TOTAL_SIZE"
		fi
	fi

	log_ok "discover-new complete for $migration_id in $context/$namespace"
	echo ""
	echo "===== Next steps ====="
	echo "1. Run: $SCRIPT_NAME copy-data $context $namespace $migration_id"
}

# ======================================================================
# SUBCOMMAND: copy-data
# ======================================================================
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
	{
		echo '#!/bin/bash'
		echo 'set -euo pipefail'
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

	if $use_persistent; then
		local session_name="pvc-mig-backup-${migration_id}"
		if [[ "$term_cmd" == "tmux" ]]; then
			tmux new-session -d -s "$session_name" "$tmp_script"
			log_info "tmux session '${session_name}' started"
			log_info "  Attach: tmux attach -t ${session_name}"
			while tmux has-session -t "$session_name" 2>/dev/null; do sleep 5; done
			if ! tmux capture-pane -t "$session_name" -p 2>/dev/null | tail -5 | grep -q "verified successfully"; then
				log_error "Backup tmux session encountered an error."
				rm -f "$tmp_script"
				return
			fi
		else
			screen -dmS "$session_name" bash "$tmp_script"
			log_info "screen session '${session_name}' started"
			log_info "  Attach: screen -r ${session_name}"
			while screen -list 2>/dev/null | grep -q "$session_name"; do sleep 5; done
		fi
	else
		log_info "Starting backup (inline)..."
		if ! bash "$tmp_script"; then
			log_error "Backup script failed — check output above."
			rm -f "$tmp_script"
			return
		fi
	fi

	end_time=$(date +%s)
	elapsed=$((end_time - start_time))
	rm -f "$tmp_script"

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
	echo "2. When satisfied, run: $SCRIPT_NAME cleanup $context $namespace $migration_id"
}

# ======================================================================
# SUBCOMMAND: cleanup
# ======================================================================
cleanup() {
	local context="$1" namespace="$2" migration_id="$3"

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME cleanup <context> <namespace> <migration-id>"
		exit 1
	fi

	state_require "$context" "$namespace" "$migration_id"

	local depl_old depl_new pvc_old pv_old pvc_new pv_new
	depl_old=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_OLD")
	depl_new=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_NEW")
	pvc_old=$(state_get "$context" "$namespace" "$migration_id" "PVC_OLD")
	pv_old=$(state_get "$context" "$namespace" "$migration_id" "PV_OLD")
	pvc_new=$(state_get "$context" "$namespace" "$migration_id" "PVC_NEW" || true)
	pv_new=$(state_get "$context" "$namespace" "$migration_id" "PV_NEW" || true)

	# --- Guard: old == new means there's nothing to clean up ---
	if [[ "$depl_old" == "$depl_new" ]]; then
		log_warn "Old deployment '$depl_old' is the SAME as the new deployment."
		log_warn "Nothing to clean up — the migration did not create a separate old deployment."
		return
	fi

	# --- Guard: verify old deployment exists ---
	if ! kubectl get deployment "$depl_old" -n "$namespace" --context="$context" &>/dev/null; then
		log_warn "Old deployment '$depl_old' no longer exists in the cluster."
		log_info "Nothing to delete. Marking phase as 'cleaned'."
		state_set "$context" "$namespace" "$migration_id" "PHASE" "cleaned"
		return
	fi

	# Check if old PVC/PV are distinct from new ones (to avoid misleading hints)
	local same_pvc=false
	if [[ -n "$pvc_new" && "$pvc_old" == "$pvc_new" ]]; then
		same_pvc=true
	fi

	echo ""
	log_warn "===== CLEANUP ====="
	echo ""
	log_warn "This WILL:"
	echo "  - Delete the OLD deployment: $depl_old"
	if $same_pvc; then
		echo "  - Old PVC is the same as new PVC, will NOT retain separately."
	else
		echo "  - Retain old PVC (for safety): $pvc_old (-> $pv_old)"
	fi
	echo "  - NFS data on OLD backend will NOT be deleted"
	echo ""
	log_warn "This will NOT:"
	echo "  - Delete new resources"
	if ! $same_pvc; then
		echo "  - Delete old PVC (you must delete manually when ready)"
	fi
	echo ""

	if ! confirm "Are you sure you want to clean up?"; then
		log_info "Aborted."
		return
	fi
	if ! confirm "REALLY delete deployment $depl_old?"; then
		log_info "Aborted."
		return
	fi

	log_info "Deleting old deployment $depl_old ..."
	kubectl delete deployment "$depl_old" -n "$namespace" --context="$context" --wait=true 2>/dev/null || {
		log_error "Failed to delete deployment $depl_old"
		exit 1
	}

	log_ok "Old deployment deleted."

	if ! $same_pvc; then
		echo ""
		log_warn "The following old resources still exist and should be reviewed manually:"
		echo "  - PVC: $pvc_old (namespace: $namespace)"
		echo "  - PV: $pv_old"
		echo "  - NFS data on old backend"
		echo ""
		log_info "To delete the old PVC when ready:"
		echo "  kubectl delete pvc $pvc_old -n $namespace --context=$context"
		echo ""
		log_info "To delete the old PV (only after PVC is deleted):"
		echo "  kubectl delete pv $pv_old --context=$context"
		echo ""
	fi

	state_set "$context" "$namespace" "$migration_id" "PHASE" "cleaned"

	log_ok "Cleanup complete for $migration_id in $context/$namespace"
}

# ======================================================================
# SUBCOMMAND: status
# ======================================================================
show_status() {
	local context="$1" namespace="$2" migration_id="$3"

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME status <context> <namespace> <migration-id>"
		exit 1
	fi

	local sf
	sf=$(state_file_path "$context" "$namespace" "$migration_id")
	if [[ ! -f "$sf" ]]; then
		log_error "No state file found at: $sf"
		exit 1
	fi

	echo "===== State: $context/$namespace/$migration_id ====="
	echo "File: $sf"
	echo ""
	cat "$sf"
	echo ""

	# Show migration summary if we have both old and new
	local phase
	phase=$(state_get "$context" "$namespace" "$migration_id" "PHASE" || true)
	echo "Current phase: ${phase:-<none>}"
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
cleanup)
	cleanup "$@"
	;;
status)
	show_status "$@"
	;;
*)
	log_error "Unknown subcommand: $SUBCOMMAND"
	usage
	;;
esac
