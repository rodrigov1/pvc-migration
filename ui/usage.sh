usage() {
	cat <<EOF
Usage: $SCRIPT_NAME <subcommand> <context> <namespace> <migration-id> [options]

Migrate PVC/PV data between NFS backends for K8s applications.
Supports multi-mount PVCs, backup/restore, and cross-host copy.

Subcommands:

  discover-old <context> <namespace> <migration-id> --deploy <deploy> --pvc <pvc>
    Discover old PVC, PV, NFS state and capture file manifests.

  backup <context> <namespace> <migration-id>
    Create compressed backup tarballs on the old NFS host.
    Required BEFORE deploying the new chart if ReclaimPolicy is Delete.

  discover-new <context> <namespace> <migration-id> [--deploy <deploy>] [--pvc <pvc>]
    Discover new deployment, PVC, PV and NFS state after chart deploy.

  copy-data <context> <namespace> <migration-id> [--compress]
    Copy data from old NFS to new NFS via tar-pipe over SSH.
    If old NFS source is gone, auto-restores from backup tarballs.
    Add --compress for gzip on slow links.

  validate <context> <namespace> <migration-id>
    Scale up the new deployment, verify files inside the pod
    against old manifests, and print cleanup assessment.

  status <context> <namespace> <migration-id>
    Show current state file contents.

Flows:

  Retain (no backup needed):
    discover-old -> deploy chart -> discover-new -> copy-data -> validate

  Delete (backup before chart deploy):
    discover-old -> backup -> deploy chart -> discover-new -> copy-data -> validate

EOF
	exit 1
}
