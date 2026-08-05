usage() {
	local command="${1:-}" exit_code="${2:-1}"

	case "$command" in
	""|global)
		cat <<EOF
Usage: $SCRIPT_NAME <subcommand> [options]

Migrate PVC/PV data between NFS backends for K8s applications.
Supports multi-mount PVCs, backup/restore, and cross-host copy.

Common options (required by every subcommand):
  -c, --context <name>       kubectl context, for example: prod
  -n, --namespace <name>     Kubernetes namespace, for example: n8n
  -m, --migration <label>    Local migration/state label, for example: n8n-2026-08

Subcommands:
  discover-old   Discover old PVC/PV/NFS state. Requires --deploy and --pvc.
  backup         Quiesce the old deployment and create a verified backup.
  discover-new   Discover new resources after chart deployment.
  copy-data      Copy/restore data and run baseline SHA-256 verification.
  validate       Require baseline success, then validate the new pod mounts.
  status         Display the migration state file.

Operational flow:
  Retain (backup optional):
    discover-old -> deploy chart -> discover-new -> copy-data -> validate

  Delete (backup required before chart deploy):
    discover-old -> backup -> deploy chart -> discover-new -> copy-data -> validate

Operational impact:
  copy-data scales BOTH deployments to 0.
  validate scales the new deployment to 1; restore the desired replica count afterward.
  backup/copy-data can wrap the COMPLETE workflow in tmux/screen when available.

Use '$SCRIPT_NAME help <subcommand>' for command-specific options and examples.
EOF
		;;
	discover-old|discover_old)
		cat <<EOF
Usage: $SCRIPT_NAME discover-old -c <context> -n <namespace> -m <migration> \\
  --deploy <old-deployment> --pvc <old-pvc>

Discovers the old PVC, PV, NFS backend, reclaim policy, and mounts.
Prints a compact source summary; full values remain in the migration state.
The source baseline is captured later, after writers are quiesced.
The ReclaimPolicy is Delete, run backup before deploying the new chart.
EOF
		;;
	backup)
		cat <<EOF
Usage: $SCRIPT_NAME backup -c <context> -n <namespace> -m <migration>

Creates compressed per-mount backups on the old NFS host.
Run this before deploying the new chart when the old PV policy is Delete.
EOF
		;;
	discover-new|discover_new)
		cat <<EOF
Usage: $SCRIPT_NAME discover-new -c <context> -n <namespace> -m <migration> \\
  [--deploy <new-deployment>] [--pvc <new-pvc>]

Discovers the new resources after the chart is deployed.
If --deploy/--pvc are omitted, resources are auto-discovered using the migration label.
Explicit --deploy and --pvc are recommended for production migrations.
EOF
		;;
	copy-data|copy_data)
		cat <<EOF
Usage: $SCRIPT_NAME copy-data -c <context> -n <namespace> -m <migration> [--compress]

Scales BOTH deployments to 0, copies/restores through SSH/tar, and compares
baseline manifests containing SHA-256 content and POSIX metadata.
Use --compress for slow links. Review the copy plan before confirming.
When tmux/screen is used, the session log and exit code are printed when it
finishes; reattach if you detached before completion.
EOF
		;;
	validate)
		cat <<EOF
Usage: $SCRIPT_NAME validate -c <context> -n <namespace> -m <migration>

Requires a passed baseline verification, scales the new deployment to 1, and
checks every migrated mount from the pod,
prints rollout diagnostics if the pod is not available, and prints a PV cleanup
assessment. Restore the desired replica count afterward.
EOF
		;;
	status)
		cat <<EOF
Usage: $SCRIPT_NAME status -c <context> -n <namespace> -m <migration>

Displays the migration state, phase, and old PV reclaim policy.
EOF
		;;
	*)
		log_error "Unknown help topic: $command"
		usage "" 1 || true
		return 1
		;;
	esac

	return "$exit_code"
}
