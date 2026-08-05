# ---- Full-workflow persistent session wrapper ----

PERSISTENT_SESSION_NAME=""
PERSISTENT_SESSION_COMMAND=""
PERSISTENT_SESSION_DIR=""
PERSISTENT_SESSION_WRAPPER=""
PERSISTENT_SESSION_LOG=""
PERSISTENT_SESSION_RESULT=""
PERSISTENT_SESSION_EXIT_CODE=""

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
	PERSISTENT_SESSION_DIR="$STATE_BASE/sessions"
	PERSISTENT_SESSION_WRAPPER="$PERSISTENT_SESSION_DIR/$PERSISTENT_SESSION_NAME.sh"
	PERSISTENT_SESSION_LOG="$PERSISTENT_SESSION_DIR/$PERSISTENT_SESSION_NAME.log"
	PERSISTENT_SESSION_RESULT="$PERSISTENT_SESSION_DIR/$PERSISTENT_SESSION_NAME.result"
	PERSISTENT_SESSION_EXIT_CODE=""
	printf -v PERSISTENT_SESSION_COMMAND 'env PVC_MIGRATION_SESSION=1 %q %q' "$SCRIPT_DIR/pvc-migration.sh" "$subcommand"
	for argument in "$@"; do
		printf -v quoted '%q' "$argument"
		PERSISTENT_SESSION_COMMAND+=" $quoted"
	done
}

session_result_code() {
	local result_line

	PERSISTENT_SESSION_EXIT_CODE=""
	if [[ ! -f "$PERSISTENT_SESSION_RESULT" ]]; then
		return 1
	fi
	if ! result_line=$(awk 'NF { count++; line=$0 } END { if (count != 1) exit 1; print line }' \
		"$PERSISTENT_SESSION_RESULT"); then
		return 1
	fi
	if [[ ! "$result_line" =~ ^exit_code=[0-9]+$ ]]; then
		return 1
	fi

	PERSISTENT_SESSION_EXIT_CODE="${result_line#exit_code=}"
}

persistent_session_exists() {
	local terminal="$1" session_name="$2"

	if [[ "$terminal" == tmux ]]; then
		tmux has-session -t "$session_name" 2>/dev/null
	else
		screen -S "$session_name" -Q select . >/dev/null 2>&1
	fi
}

write_persistent_session_wrapper() {
	local subcommand="$1"
	shift
	local previous_umask write_status=0

	previous_umask=$(umask)
	umask 077
	if ! mkdir -p "$PERSISTENT_SESSION_DIR" || ! rm -f "$PERSISTENT_SESSION_RESULT"; then
		umask "$previous_umask"
		return 1
	fi

	{
		printf '%s\n' '#!/usr/bin/env bash' 'set -u'
		printf 'export PATH=%q\n' "$PATH"
		printf 'export HOME=%q\n' "$HOME"
		if [[ -n "${STATE_BASE:-}" ]]; then
			printf 'export STATE_BASE=%q\n' "$STATE_BASE"
		fi
		if [[ -n "${KUBECONFIG:-}" ]]; then
			printf 'export KUBECONFIG=%q\n' "$KUBECONFIG"
		fi
		printf 'session_name=%q\n' "$PERSISTENT_SESSION_NAME"
		printf 'log_file=%q\n' "$PERSISTENT_SESSION_LOG"
		printf 'result_file=%q\n' "$PERSISTENT_SESSION_RESULT"
		printf 'command=(env PVC_MIGRATION_SESSION=1 %q %q' "$SCRIPT_DIR/pvc-migration.sh" "$subcommand"
		for argument in "$@"; do
			printf ' %q' "$argument"
			done
		printf ')\n'
		printf '{\n'
		printf '  printf "[INFO] Persistent workflow started at %%s\\n" "$(date -Iseconds)"\n'
		printf '  "${command[@]}"\n'
		printf '} 2>&1 | tee -a "$log_file"\n'
		printf 'status="${PIPESTATUS[0]}"\n'
		printf 'result_tmp="${result_file}.$$"\n'
		printf 'printf "exit_code=%%s\\n" "$status" >"$result_tmp" && mv -f -- "$result_tmp" "$result_file"\n'
		printf 'if [[ "$status" -eq 0 ]]; then\n'
		printf '  printf "[OK] Persistent workflow completed successfully (exit code 0).\\n" | tee -a "$log_file"\n'
		printf 'else\n'
		printf '  printf "[ERROR] Persistent workflow failed (exit code %%s).\\n" "$status" | tee -a "$log_file"\n'
		printf 'fi\n'
		printf 'printf "[INFO] Session log: %%s\\n" "$log_file" | tee -a "$log_file"\n'
		printf 'printf "[INFO] Result file: %%s\\n" "$result_file" | tee -a "$log_file"\n'
		printf 'printf "[INFO] Press Enter to close this session, or detach and reattach later.\\n" | tee -a "$log_file"\n'
		printf 'IFS= read -r _ || true\n'
		printf 'exit "$status"\n'
	} >"$PERSISTENT_SESSION_WRAPPER" || write_status=$?
	umask "$previous_umask"
	if ((write_status != 0)); then
		return "$write_status"
	fi
	chmod 700 "$PERSISTENT_SESSION_WRAPPER"
}

persistent_session_preflight() {
	local subcommand="$1"
	shift

	case "$subcommand" in
	copy-data | copy_data)
		parse_common_args "$subcommand" "$@" || return 1
		parse_copy_args "$subcommand" || return 1
		;;
	backup)
		parse_common_args "$subcommand" "$@" || return 1
		require_no_command_args "$subcommand" || return 1
		;;
	*)
		return 0
		;;
	esac
	require_common_args "$subcommand" || return 1

	local sf
	sf=$(state_file_path "$CLI_CONTEXT" "$CLI_NAMESPACE" "$CLI_MIGRATION")
	if [[ ! -f "$sf" ]]; then
		log_error "State file not found: $sf"
		log_error "Run 'discover-old' first."
		return 1
	fi
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
	if persistent_session_exists "$terminal" "$PERSISTENT_SESSION_NAME"; then
		log_error "Persistent session '$PERSISTENT_SESSION_NAME' already exists."
		if [[ "$terminal" == tmux ]]; then
			log_info "Reattach with: tmux attach -t $PERSISTENT_SESSION_NAME"
		else
			log_info "Reattach with: screen -r $PERSISTENT_SESSION_NAME"
		fi
		return 1
	fi
	if ! write_persistent_session_wrapper "$subcommand" "$@"; then
		log_error "Could not create persistent session files under $PERSISTENT_SESSION_DIR."
		return 1
	fi

	log_info "Starting complete workflow in $terminal session '$PERSISTENT_SESSION_NAME'."
	if [[ "$terminal" == tmux ]]; then
		local tmux_command
		tmux_command="bash $(printf '%q' "$PERSISTENT_SESSION_WRAPPER")"
		if ! tmux new-session -s "$PERSISTENT_SESSION_NAME" "$tmux_command"; then
			if session_result_code; then
				log_error "Persistent workflow failed with exit code $PERSISTENT_SESSION_EXIT_CODE."
				log_info "Session log: $PERSISTENT_SESSION_LOG"
				return "$PERSISTENT_SESSION_EXIT_CODE"
			fi
			log_error "Could not start tmux session '$PERSISTENT_SESSION_NAME'."
			return 1
		fi
	else
		if ! screen -S "$PERSISTENT_SESSION_NAME" bash "$PERSISTENT_SESSION_WRAPPER"; then
			if session_result_code; then
				log_error "Persistent workflow failed with exit code $PERSISTENT_SESSION_EXIT_CODE."
				log_info "Session log: $PERSISTENT_SESSION_LOG"
				return "$PERSISTENT_SESSION_EXIT_CODE"
			fi
			log_error "Could not start screen session '$PERSISTENT_SESSION_NAME'."
			return 1
		fi
	fi

	if session_result_code; then
		if [[ "$PERSISTENT_SESSION_EXIT_CODE" -eq 0 ]]; then
			log_ok "Persistent workflow completed successfully."
		else
			log_error "Persistent workflow failed with exit code $PERSISTENT_SESSION_EXIT_CODE."
		fi
		log_info "Session log: $PERSISTENT_SESSION_LOG"
		return "$PERSISTENT_SESSION_EXIT_CODE"
	fi

	log_info "Workflow is still running in session '$PERSISTENT_SESSION_NAME'."
	if [[ "$terminal" == tmux ]]; then
		log_info "Reattach with: tmux attach -t $PERSISTENT_SESSION_NAME"
	else
		log_info "Reattach with: screen -r $PERSISTENT_SESSION_NAME"
	fi
	log_info "Session log: $PERSISTENT_SESSION_LOG"
	return 10
}
