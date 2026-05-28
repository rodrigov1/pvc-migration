# ---- Copy / backup / restore helpers ----

write_temp_script() {
	local tmp_script="$1"
	cat >"$tmp_script" <<-'TMPSCRIPTHEADER'
#!/bin/bash
set -euo pipefail
result_file="$(mktemp /tmp/pvc-mig-result-XXXXXX)"
trap 'echo "EXIT_CODE=$?" > "$result_file"' EXIT
TMPSCRIPTHEADER
}

run_with_persistent_session() {
	local mode="$1" session_name="$2" cmd="$3" tmp_script="$4"
	local result_file="/tmp/pvc-mig-${session_name}-result"

	if [[ "$mode" == "tmux" ]]; then
		tmux new-session -d -s "$session_name" "bash '$tmp_script'; echo 'EXIT_CODE=\$?' > '$result_file'"
	elif [[ "$mode" == "screen" ]]; then
		screen -dmS "$session_name" bash -c "bash '$tmp_script'; echo 'EXIT_CODE=\$?' > '$result_file'"
	fi

	echo "Session '$session_name' started in $mode."
	echo "Monitor with: $mode attach -t $session_name"
	echo "Waiting for completion..."

	local waited=0
	while tmux has-session -t "$session_name" 2>/dev/null || screen -ls 2>/dev/null | grep -q "$session_name"; do
		sleep 10
		waited=$((waited + 10))
		if ((waited % 60 == 0)); then
			echo "... still waiting ($((waited / 60)) min)"
		fi
	done

	if [[ -f "$result_file" ]]; then
		local exit_code
		exit_code=$(grep -oP 'EXIT_CODE=\K\d+' "$result_file" 2>/dev/null || echo "1")
		rm -f "$result_file"
		return "$exit_code"
	fi

	return 1
}

build_progress_cmd() {
	local use_compress="$1"
	local progress_cmd="cat"
	if command -v pv &>/dev/null; then
		progress_cmd="pv -trab"
	fi
	if [[ "$use_compress" == "true" ]]; then
		if [[ "$progress_cmd" == "cat" ]]; then
			progress_cmd="gzip"
		else
			progress_cmd="pv -trab | gzip"
		fi
	fi
	echo "$progress_cmd"
}

backup_dir_name() {
	local migration_id="$1"
	echo "${migration_id}-backup"
}
