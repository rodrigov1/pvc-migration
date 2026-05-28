# ---- Kubernetes helpers ----

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

get_pvc_volume_name() {
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

# NOTE: hardcodes containers[0] — multi-container pods not yet supported.
# TODO: accept optional container name or iterate all containers.
get_volume_mounts_from_deploy() {
	local ctx="$1" ns="$2" deploy="$3" vol_name="$4"
	kubectl get deployment "$deploy" -n "$ns" --context="$ctx" \
		-o jsonpath="{range .spec.template.spec.containers[0].volumeMounts[?(@.name=='$vol_name')]}@{.mountPath}|{.subPath}{'\n'}{end}" 2>/dev/null || true
}

deployment_exists() {
	local ctx="$1" ns="$2" deploy="$3"
	kubectl get deployment "$deploy" -n "$ns" --context="$ctx" &>/dev/null
}

pvc_exists() {
	local ctx="$1" ns="$2" pvc="$3"
	kubectl get pvc "$pvc" -n "$ns" --context="$ctx" &>/dev/null
}

pv_exists() {
	local ctx="$1" pv="$2"
	kubectl get pv "$pv" --context="$ctx" &>/dev/null
}

scale_deployment() {
	local ctx="$1" ns="$2" deploy="$3" replicas="$4"
	kubectl scale deployment "$deploy" -n "$ns" --context="$ctx" --replicas="$replicas" 2>/dev/null || true
}

get_deployment_replicas() {
	local ctx="$1" ns="$2" deploy="$3"
	kubectl get deployment "$deploy" -n "$ns" --context="$ctx" \
		-o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0"
}
