#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
source "$SCRIPT_DIR/commands/status.sh"

SUBCOMMAND="${1:-}"
shift || true

case "$SUBCOMMAND" in
discover-old | discover_old)
	cmd_discover_old "$@"
	;;
backup)
	cmd_backup "$@"
	;;
discover-new | discover_new)
	cmd_discover_new "$@"
	;;
copy-data | copy_data)
	cmd_copy_data "$@"
	;;
validate)
	cmd_validate "$@"
	;;
status)
	cmd_status "$@"
	;;
*)
	log_error "Unknown subcommand: ${SUBCOMMAND:-<empty>}"
	usage
	;;
esac
