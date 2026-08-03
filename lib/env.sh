SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
STATE_BASE="${STATE_BASE:-$HOME/.pvc-migration/state}"

check_dependencies() {
	local missing=false
	for cmd in kubectl ssh jq awk sed grep tar find; do
		if ! command -v "$cmd" &>/dev/null; then
			echo "Error: Required dependency '$cmd' is not installed." >&2
			missing=true
		fi
	done
	if $missing; then
		exit 1
	fi
}
