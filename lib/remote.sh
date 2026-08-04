# ---- Safe remote command helpers ----

ssh_run() {
	local host="$1"
	shift
	local remote_command="" quoted
	for argument in "$@"; do
		printf -v quoted '%q' "$argument"
		remote_command+="${remote_command:+ }${quoted}"
	done
	ssh "$host" "$remote_command"
}

ssh_bash() {
	local host="$1" script="$2"
	shift 2
	local remote_command quoted
	printf -v remote_command 'bash -c %q --' "$script"
	for argument in "$@"; do
		printf -v quoted '%q' "$argument"
		remote_command+=" $quoted"
	done
	ssh "$host" "$remote_command"
}
