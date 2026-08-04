# ---- Full-workflow persistent session wrapper ----

PERSISTENT_SESSION_NAME=""
PERSISTENT_SESSION_COMMAND=""

build_persistent_session_command() {
	local subcommand="$1"
	shift
	local migration_id="migration" previous="" argument quoted
	for argument in "$@"; do
		if [[ "$previous" == "--migration" || "$previous" == "-m" ]]; then
			migration_id="$argument"
			break
		fi
		case "$argument" in
		--migration=*) migration_id="${argument#*=}"; break ;;
		esac
		previous="$argument"
	done
	migration_id="${migration_id//[^a-zA-Z0-9_.-]/-}"
	PERSISTENT_SESSION_NAME="pvc-mig-${subcommand//_/-}-${migration_id}"
	printf -v PERSISTENT_SESSION_COMMAND 'env PVC_MIGRATION_SESSION=1 %q %q' "$SCRIPT_DIR/pvc-migration.sh" "$subcommand"
	for argument in "$@"; do
		printf -v quoted '%q' "$argument"
		PERSISTENT_SESSION_COMMAND+=" $quoted"
	done
}

maybe_run_in_persistent_session() {
	local subcommand="$1"
	shift

	[[ "$subcommand" == "copy-data" || "$subcommand" == "copy_data" || "$subcommand" == "backup" ]] || return 0
	[[ -z "${TMUX:-}" && -z "${STY:-}" && -z "${PVC_MIGRATION_SESSION:-}" ]] || return 0
	[[ -t 0 && -t 1 ]] || return 0

	local terminal=""
	if command -v tmux &>/dev/null; then
		terminal=tmux
	elif command -v screen &>/dev/null; then
		terminal=screen
	else
		return 0
	fi
	if ! confirm_default_yes "Run the complete $subcommand workflow inside $terminal (survives disconnects)?"; then
		return 0
	fi

	build_persistent_session_command "$subcommand" "$@"

	log_info "Starting complete workflow in $terminal session '$PERSISTENT_SESSION_NAME'."
	if [[ "$terminal" == tmux ]]; then
		if ! tmux new-session -s "$PERSISTENT_SESSION_NAME" "$PERSISTENT_SESSION_COMMAND"; then
			log_error "Could not start tmux session '$PERSISTENT_SESSION_NAME'."
			return 1
		fi
	else
		if ! screen -S "$PERSISTENT_SESSION_NAME" bash -lc "$PERSISTENT_SESSION_COMMAND"; then
			log_error "Could not start screen session '$PERSISTENT_SESSION_NAME'."
			return 1
		fi
	fi
	return 10
}
