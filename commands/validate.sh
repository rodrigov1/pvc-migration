cmd_validate() {
	local context="$1" namespace="$2" migration_id="$3"

	if [[ -z "$context" || -z "$namespace" || -z "$migration_id" ]]; then
		log_error "Usage: $SCRIPT_NAME validate <context> <namespace> <migration-id>"
		exit 1
	fi

	state_require "$context" "$namespace" "$migration_id"

	local depl_new pvc_new
	depl_new=$(state_get "$context" "$namespace" "$migration_id" "DEPLOY_NEW")
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
		kubectl wait deployment "$depl_new" -n "$namespace" --context="$context" \
			--for=condition=Available --timeout=120s 2>/dev/null || true
	fi

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

	log_info "Recent logs (last 20 lines):"
	kubectl logs "$pod_name" -n "$namespace" --context="$context" --tail=20 2>/dev/null ||
		log_warn "Could not fetch logs (kubelet may be unavailable)."

	local manifest_base="$STATE_BASE/$context/$namespace/${migration_id}.old.manifest"
	local manifests_all_match=true

	state_get_mounts "$context" "$namespace" "$migration_id" "NEW"
	local mnt_idx=0

	for single_mount in "${MOUNTS_LIST[@]}"; do
		[[ -z "$single_mount" ]] && continue
		mnt_idx=$((mnt_idx + 1))
		echo ""
		log_info "Checking mount $mnt_idx: $single_mount ..."

		if ! kubectl exec "$pod_name" -n "$namespace" --context="$context" -- \
			ls -lah "$single_mount" 2>/dev/null; then
			log_warn "kubectl exec failed for $single_mount"
			log_warn "Check manually: kubectl exec -n $namespace --context=$context $pod_name -- ls -lah $single_mount"
		fi

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
	done

	if [[ "$mnt_idx" -gt 0 ]]; then
		if $manifests_all_match; then
			log_ok "All mounts verified against old manifests."
		else
			log_warn "Some mounts differ from old manifests. Review above."
		fi
	fi

	echo ""
	log_info "===== PV Cleanup Assessment ====="
	local pvc_old_name pvc_new_name pv_old_name
	pvc_old_name=$(state_get "$context" "$namespace" "$migration_id" "PVC_OLD" || true)
	pvc_new_name=$(state_get "$context" "$namespace" "$migration_id" "PVC_NEW" || true)
	pv_old_name=$(state_get "$context" "$namespace" "$migration_id" "PV_OLD" || true)

	local pvc_old_status="NotFound"
	if [[ -n "$pvc_old_name" ]]; then
		if kubectl get pvc "$pvc_old_name" -n "$namespace" --context="$context" &>/dev/null; then
			pvc_old_status="Exists"
		else
			pvc_old_status="Deleted (pruned by ArgoCD during sync)"
		fi
	fi

	local pv_old_status="" pv_old_reclaim="" pv_old_nfs_info=""
	if [[ -n "$pv_old_name" ]]; then
		if kubectl get pv "$pv_old_name" --context="$context" &>/dev/null; then
			pv_old_status=$(kubectl get pv "$pv_old_name" --context="$context" -o jsonpath='{.status.phase}' 2>/dev/null || echo "unknown")
			pv_old_reclaim=$(kubectl get pv "$pv_old_name" --context="$context" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null || echo "unknown")
		else
			pv_old_status="Deleted"
		fi
	fi
	local old_nfs_host_show old_nfs_path_show
	old_nfs_host_show=$(state_get "$context" "$namespace" "$migration_id" "OLD_NFS_HOST" || true)
	old_nfs_path_show=$(state_get "$context" "$namespace" "$migration_id" "NFS_PATH_OLD" || true)

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
