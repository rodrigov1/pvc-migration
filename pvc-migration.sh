#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/env.sh"
source "$SCRIPT_DIR/ui/logging.sh"
source "$SCRIPT_DIR/ui/prompts.sh"
source "$SCRIPT_DIR/ui/usage.sh"
source "$SCRIPT_DIR/lib/args.sh"
source "$SCRIPT_DIR/lib/session.sh"
source "$SCRIPT_DIR/lib/policy.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/kube.sh"
source "$SCRIPT_DIR/lib/nfs.sh"
source "$SCRIPT_DIR/lib/remote.sh"
source "$SCRIPT_DIR/lib/verification.sh"
source "$SCRIPT_DIR/lib/mounts.sh"

source "$SCRIPT_DIR/commands/discover_old.sh"
source "$SCRIPT_DIR/commands/discover_new.sh"
source "$SCRIPT_DIR/commands/backup.sh"
source "$SCRIPT_DIR/commands/copy_data.sh"
source "$SCRIPT_DIR/commands/validate.sh"
source "$SCRIPT_DIR/commands/status.sh"

main() {
	if [[ $# -lt 1 ]]; then
		usage "" 1 || true
		return 1
	fi

	local subcommand="$1"
	if [[ "$subcommand" == "-h" || "$subcommand" == "--help" || "$subcommand" == "help" ]]; then
		if [[ $# -gt 2 ]]; then
			log_error "Too many arguments for help."
			usage "" 1 || true
			return 1
		fi
		if [[ -n "${2:-}" ]]; then
			usage "$2" 0 || return $?
		else
			usage "" 0 || return $?
		fi
		return 0
	fi
	if [[ "$subcommand" == "-h" || "$subcommand" == "--help" || "${2:-}" == "-h" || "${2:-}" == "--help" ]]; then
		usage "$subcommand" 0 || return $?
		return 0
	fi
	local session_result=0
	maybe_run_in_persistent_session "$subcommand" "${@:2}" || session_result=$?
	if [[ "$session_result" -eq 10 ]]; then
		return 0
	elif [[ "$session_result" -ne 0 ]]; then
		return "$session_result"
	fi

	check_dependencies

	shift

	case "$subcommand" in
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
		log_error "Unknown subcommand: ${subcommand:-<empty>}"
		usage "" 1 || true
		return 1
		;;
	esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
