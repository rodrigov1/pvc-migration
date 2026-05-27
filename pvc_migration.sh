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

  copy-data <context> <namespace> <migration-id> [--backup]
    Copy data from old NFS path to new NFS path.
    Scales down deployments, copies via tar-pipe over SSH, verifies.

  validate <context> <namespace> <migration-id>
    Scale up the new deployment, wait for readiness, verify files inside the pod.

  cleanup <context> <namespace> <migration-id>
    Remove old deployment and notify about old PVC retention.

  status <context> <namespace> <migration-id>
    Show current state file contents.

State files: \$STATE_BASE/<context>/<namespace>/<migration-id>.env

Examples:
  \$SCRIPT_NAME discover-old prod n8n redis-famaf --deploy n8n-redis-famaf --pvc n8n-redis-famaf-deployment-pvc
  \$SCRIPT_NAME discover-new prod n8n redis-famaf --deploy redis-famaf
  \$SCRIPT_NAME copy-data prod n8n redis-famaf --backup
  \$SCRIPT_NAME validate prod n8n redis-famaf
  \$SCRIPT_NAME cleanup prod n8n redis-famaf
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
		find "$mount_path" -type f -exec ls -ln {} \; 2>/dev/null |
		strip_path_prefix "$base_path" >"$outfile" || {
		log_warn "kubectl exec failed (may be transient)."
		return 1
	}
	# Capture md5 for each file (batch with + for speed)
	kubectl exec "$pod" -n "$ns" --context="$ctx" -- \
		find "$mount_path" -type f -exec md5sum {} + 2>/dev/null >"${outfile}.md5" || true
	log_ok "Manifest saved: $outfile"
}

capture_file_manifest_nfs() {
	local nfs_host="$1" nfs_path="$2" outfile="$3"
	log_info "Capturing file manifest via SSH to $nfs_host:$nfs_path ..."
	ssh "$nfs_host" "find '$nfs_path' -type f -printf '%s %U %G %P\n'" 2>/dev/null >"$outfile" || {
		log_error "SSH to $nfs_host failed"
		return 1
	}
	ssh "$nfs_host" "find '$nfs_path' -type f -exec md5sum {} +" 2>/dev/null >"${outfile}.md5" || true
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

	# Find the volume name from the PVC to look up mount info
	local vol_name
	vol_name=$pvc_old
	# The volume name in the deployment might differ from PVC name.
	# Let's find it via the deployment spec
	local mount_info mount_path subpath
	mount_info=$(kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" \
		-o jsonpath="{range .spec.template.spec.containers[0].volumeMounts[*]}{.name}|{.mountPath}|{.subPath}{'\n'}{end}" 2>/dev/null) || true

	if [[ -n "$mount_info" ]]; then
		# Pick the volume mount that matches our PVC's claim name
		local claim_name
		claim_name="$pvc_old"
		local vol_in_deploy
		vol_in_deploy=$(kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" \
			-o jsonpath="{range .spec.template.spec.volumes[?(@.persistentVolumeClaim.claimName=='$claim_name')]}{.name}{'\n'}{end}" 2>/dev/null) || true

		if [[ -n "$vol_in_deploy" ]]; then
			mount_info=$(kubectl get deployment "$deploy_old" -n "$namespace" --context="$context" \
				-o jsonpath="{range .spec.template.spec.containers[0].volumeMounts[?(@.name=='$vol_in_deploy')]}@{.mountPath}|{.subPath}{'\n'}{end}" 2>/dev/null) || true
			if [[ -n "$mount_info" ]]; then
				mount_path=$(echo "$mount_info" | cut -d'|' -f1 | tr -d '@')
				subpath=$(echo "$mount_info" | cut -d'|' -f2)
				log_info "Mount path: $mount_path"
				log_info "SubPath: ${subpath:-<none>}"

				state_set "$context" "$namespace" "$migration_id" "MOUNT_OLD" "$mount_path"
				state_set "$context" "$namespace" "$migration_id" "SUBPATH_OLD" "${subpath:-}"
			fi
		fi
	fi

	# Build the NFS path
	local nfs_host nfs_share_base pv_uid subpath_val nfs_path_old
	nfs_host=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST" || true)
	nfs_share_base=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_SHARE_BASE" || true)
	pv_uid=$(state_get "$context" "$namespace" "$migration_id" "OLD_PV_UID" || true)
	subpath_val=$(state_get "$context" "$namespace" "$migration_id" "SUBPATH_OLD" || true)

	if [[ -n "$nfs_host" && -n "$nfs_share_base" && -n "$pv_uid" ]]; then
		if [[ -n "$subpath_val" ]]; then
			nfs_path_old="${nfs_share_base}/${pv_uid}/${subpath_val}/"
		else
			nfs_path_old="${nfs_share_base}/${pv_uid}/"
		fi
		state_set "$context" "$namespace" "$migration_id" "NFS_PATH_OLD" "$nfs_path_old"
		log_ok "Old NFS path: $nfs_host:$nfs_path_old"
	else
		log_warn "Could not construct NFS path. Set NFS_PATH_OLD manually."
		log_info "  nfs_host=$nfs_host"
		log_info "  nfs_share_base=$nfs_share_base"
		log_info "  pv_uid=$pv_uid"
		log_info "  subpath=$subpath_val"
	fi

	# Capture file manifest via NFS (preferred) or from running pod (fallback)
	if [[ -n "$nfs_host" && -n "${nfs_path_old:-}" ]]; then
		local manifest_file
		manifest_file="$STATE_BASE/$context/$namespace/${migration_id}.old.manifest"
		if ssh "$nfs_host" "test -d '$nfs_path_old'" 2>/dev/null; then
			capture_file_manifest_nfs "$nfs_host" "$nfs_path_old" "$manifest_file" || true
		else
			log_warn "NFS path not accessible via SSH: $nfs_host:$nfs_path_old"
		fi
	fi
	# Fallback: capture manifest from running pod
	if [[ ! -f "$manifest_file" ]]; then
		local manifest_file
		manifest_file="$STATE_BASE/$context/$namespace/${migration_id}.old.manifest"
		local pod_name mount_path
		mount_path=$(state_get "$context" "$namespace" "$migration_id" "MOUNT_OLD" || true)
		pod_name=$(get_pod_for_deploy "$context" "$namespace" "$deploy_old")
		if [[ -n "$pod_name" && -n "$mount_path" ]]; then
			capture_file_manifest "$context" "$namespace" "$pod_name" "$mount_path" "$manifest_file" || true
		else
			log_info "No running pod available to capture manifest (pod may be scaled down)."
		fi
	fi

	# Compute total size from manifest or NFS
	local old_total_bytes
	if [[ -f "$manifest_file" ]]; then
		old_total_bytes=$(compute_total_size_manifest "$manifest_file")
	else
		old_total_bytes=$(compute_total_size_nfs "$nfs_host" "$nfs_path_old")
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
					log_info "Using first match: $deploy_new"
				fi
			else
				log_warn "Multiple deployments match '$migration_id':"
				echo "$matches"
				deploy_new=$(echo "$matches" | head -1)
				log_info "Using first match: $deploy_new"
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
					log_info "Using first match: $pvc_new"
				fi
			else
				log_warn "Multiple PVCs match '$migration_id':"
				echo "$matches"
				pvc_new=$(echo "$matches" | head -1)
				log_info "Using first match: $pvc_new"
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

	# Find mount info from new deployment
	local claim_name vol_in_deploy mount_info mount_path subpath
	claim_name="$pvc_new"
	vol_in_deploy=$(kubectl get deployment "$deploy_new" -n "$namespace" --context="$context" \
		-o jsonpath="{range .spec.template.spec.volumes[?(@.persistentVolumeClaim.claimName=='$claim_name')]}{.name}{'\n'}{end}" 2>/dev/null) || true

	if [[ -n "$vol_in_deploy" ]]; then
		mount_info=$(kubectl get deployment "$deploy_new" -n "$namespace" --context="$context" \
			-o jsonpath="{range .spec.template.spec.containers[0].volumeMounts[?(@.name=='$vol_in_deploy')]}@{.mountPath}|{.subPath}{'\n'}{end}" 2>/dev/null) || true
		if [[ -n "$mount_info" ]]; then
			mount_path=$(echo "$mount_info" | cut -d'|' -f1 | tr -d '@')
			subpath=$(echo "$mount_info" | cut -d'|' -f2)
			log_info "New mount path: $mount_path"
			log_info "New SubPath: ${subpath:-<none>}"
			state_set "$context" "$namespace" "$migration_id" "MOUNT_NEW" "$mount_path"
			state_set "$context" "$namespace" "$migration_id" "SUBPATH_NEW" "${subpath:-}"
		fi
	fi

	# Build NFS path
	local nfs_host nfs_share_base pv_uid nfs_path_new
	nfs_host=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_HOST" || true)
	nfs_share_base=$(state_get "$context" "$namespace" "$migration_id" "NEW_NFS_SHARE_BASE" || true)
	pv_uid=$(state_get "$context" "$namespace" "$migration_id" "NEW_PV_UID" || true)
	subpath=$(state_get "$context" "$namespace" "$migration_id" "SUBPATH_NEW" || true)

	if [[ -n "$nfs_host" && -n "$nfs_share_base" && -n "$pv_uid" ]]; then
		if [[ -n "$subpath" ]]; then
			nfs_path_new="${nfs_share_base}/${pv_uid}/${subpath}/"
		else
			nfs_path_new="${nfs_share_base}/${pv_uid}/"
		fi
		state_set "$context" "$namespace" "$migration_id" "NFS_PATH_NEW" "$nfs_path_new"
		log_ok "New NFS path: $nfs_host:$nfs_path_new"
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
	local context="" namespace="" migration_id="" do_backup=false

	context="$1"
	shift || true
	namespace="$1"
	shift || true
	migration_id="$1"
	shift || true

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--backup)
			do_backup=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			usage
			;;
		esac
	done

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME copy-data [--backup] <context> <namespace> <migration-id>"
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
	log_info "Verifying SSH access to old NFS host: $nfs_host_old ..."
	if ! ssh "$nfs_host_old" "test -d '$nfs_path_old'" 2>/dev/null; then
		log_warn "Old NFS path not accessible via SSH: $nfs_host_old:$nfs_path_old"
		log_warn "Contents of parent directory:"
		ssh "$nfs_host_old" "ls -lah '$(dirname "$nfs_path_old")'" 2>/dev/null || log_error "Cannot access old NFS at all."
		if ! confirm "Continue anyway?"; then
			log_info "Aborted."
			return
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

	# Optional backup
	if $do_backup; then
		local backup_file="/tmp/${namespace}-${migration_id}-pre-migracion.tgz"
		log_info "Creating backup: $backup_file"
		if confirm "Create backup tarball on $nfs_host_old?"; then
			ssh "$nfs_host_old" "tar -czf '$backup_file' -C '$nfs_path_old' ." 2>/dev/null || log_warn "Backup failed (continuing)"
			log_ok "Backup created: $nfs_host_old:$backup_file"
		fi
	fi

	# Create destination directory on new NFS
	log_info "Creating destination directory: $nfs_path_new"
	ssh "$nfs_host_new" "mkdir -p '$nfs_path_new'" 2>/dev/null || {
		log_error "Failed to create destination directory on $nfs_host_new"
		log_error "You may need to create the parent share first."
		exit 1
	}

	# Copy data
	echo ""
	log_info "Starting data copy from $nfs_host_old to $nfs_host_new ..."
	log_info "Command: tar-pipe via SSH"

	if ! confirm "Execute the copy now?"; then
		log_info "Aborted. NFS paths are still scaled down."
		log_info "Manual copy command:"
		echo "  ssh $nfs_host_old \"tar -czf - -C '$nfs_path_old' .\" | ssh $nfs_host_new \"tar -xzf - -C '$nfs_path_new'\""
		return
	fi

	local start_time end_time elapsed
	start_time=$(date +%s)

	# Copy via tar-pipe
	if ! ssh "$nfs_host_old" "tar -czf - -C '$nfs_path_old' ." | ssh "$nfs_host_new" "tar -xzf - -C '$nfs_path_new'"; then
		log_error "Data copy failed!"
		log_error "Check SSH connectivity and NFS paths."
		log_error "Old: ssh $nfs_host_old ls -lah '$nfs_path_old'"
		log_error "New: ssh $nfs_host_new ls -lah '$nfs_path_new'"
		exit 1
	fi

	end_time=$(date +%s)
	elapsed=$((end_time - start_time))
	log_ok "Data copy completed in ${elapsed}s"

	# Verify copy
	echo ""
	log_info "Verifying copy: file count and sizes..."

	local old_count new_count2
	old_count=$(ssh "$nfs_host_old" "find '$nfs_path_old' -type f | wc -l" 2>/dev/null || echo "0")
	new_count2=$(ssh "$nfs_host_new" "find '$nfs_path_new' -type f | wc -l" 2>/dev/null || echo "0")

	log_info "Old file count: $old_count"
	log_info "New file count: $new_count2"

	if [[ "$old_count" != "$new_count2" ]]; then
		log_warn "File count mismatch! Old=$old_count New=$new_count2"
	else
		log_ok "File count matches."
	fi

	# Verify md5 (compare hashes only, paths differ between old and new NFS backends)
	log_info "Computing md5 sums..."
	local old_md5 new_md5
	old_md5=$(ssh "$nfs_host_old" "find '$nfs_path_old' -type f -exec md5sum {} \; | awk '{print \$1}' | sort | md5sum" 2>/dev/null || echo "")
	new_md5=$(ssh "$nfs_host_new" "find '$nfs_path_new' -type f -exec md5sum {} \; | awk '{print \$1}' | sort | md5sum" 2>/dev/null || echo "")

	if [[ -n "$old_md5" && -n "$new_md5" ]]; then
		if [[ "$old_md5" == "$new_md5" ]]; then
			log_ok "md5 checksums MATCH."
		else
			log_warn "md5 checksums DIFFER!"
			log_warn "Old aggregate md5: $old_md5"
			log_warn "New aggregate md5: $new_md5"
		fi
	else
		log_warn "Could not compute md5 sums (one side may be empty)."
	fi

	# Check uid:gid and permissions (compare mode+uid+gid only, paths differ between NFS hosts)
	log_info "Checking permissions (mode, uid, gid)..."
	local old_perm new_perm
	old_perm=$(ssh "$nfs_host_old" "find '$nfs_path_old' -type f -exec ls -ln {} \; | awk '{print \$1, \$3, \$4}' | sort" 2>/dev/null || true)
	new_perm=$(ssh "$nfs_host_new" "find '$nfs_path_new' -type f -exec ls -ln {} \; | awk '{print \$1, \$3, \$4}' | sort" 2>/dev/null || true)

	if [[ "$old_perm" == "$new_perm" ]]; then
		log_ok "Permissions match."
	else
		log_warn "Permissions differ:"
		diff <(echo "$old_perm") <(echo "$new_perm") || true
	fi

	# Record copy in state
	state_set "$context" "$namespace" "$migration_id" "PHASE" "copied"
	state_set "$context" "$namespace" "$migration_id" "COPY_TIMESTAMP" "$(date -Iseconds)"
	state_set "$context" "$namespace" "$migration_id" "COPY_FILE_COUNT_OLD" "$old_count"
	state_set "$context" "$namespace" "$migration_id" "COPY_FILE_COUNT_NEW" "$new_count2"

	echo ""
	log_ok "copy-data complete for $migration_id in $context/$namespace"
	echo ""
	echo "===== Next steps ====="
	echo "1. Run: $SCRIPT_NAME validate $context $namespace $migration_id"
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

	# Verify files inside the pod
	if [[ -n "$mount_new" ]]; then
		echo ""
		log_info "Checking files in pod at $mount_new ..."

		# List files
		if ! kubectl exec "$pod_name" -n "$namespace" --context="$context" -- \
			ls -lah "$mount_new" 2>/dev/null; then
			log_warn "kubectl exec failed (transient error)."
			log_warn "Check manually: kubectl exec -n $namespace --context=$context $pod_name -- ls -lah $mount_new"
		fi

		# Compare with old manifest if available
		local manifest_old
		manifest_old="$STATE_BASE/$context/$namespace/${migration_id}.old.manifest"
		if [[ -f "$manifest_old" ]]; then
			echo ""
			log_info "Comparing with old file manifest..."
			local manifest_new
			manifest_new=$(mktemp)
			local base_path="${mount_new%/}/"
			if kubectl exec "$pod_name" -n "$namespace" --context="$context" -- \
				find "$mount_new" -type f -exec ls -ln {} \; 2>/dev/null |
				strip_path_prefix "$base_path" >"$manifest_new" 2>/dev/null; then
				if diff <(sort "$manifest_old") <(sort "$manifest_new") &>/dev/null; then
					log_ok "Files in pod match old manifest."
				else
					log_warn "Files differ from old manifest:"
					diff <(sort "$manifest_old") <(sort "$manifest_new") || true
				fi
			else
				log_warn "Could not compare manifests (kubectl exec issue)."
			fi
			rm -f "$manifest_new"
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
