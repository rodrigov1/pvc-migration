state_file_path() {
	echo "$STATE_BASE/$1/$2/$3.env"
}

state_require() {
	local sf
	sf=$(state_file_path "$1" "$2" "$3")
	if [[ ! -f "$sf" ]]; then
		log_error "State file not found: $sf"
		log_error "Run 'discover-old' first."
		exit 1
	fi
	# shellcheck disable=SC1090
	source "$sf"
}

state_get() {
	local sf key
	sf=$(state_file_path "$1" "$2" "$3")
	key="$4"
	if [[ -f "$sf" ]]; then
		grep "^${key}=" "$sf" 2>/dev/null | cut -d= -f2- || true
	fi
}

state_set() {
	local sf key value
	sf=$(state_file_path "$1" "$2" "$3")
	key="$4"
	value="$5"
	mkdir -p "$(dirname "$sf")"
	if grep -q "^${key}=" "$sf" 2>/dev/null; then
		sed -i "/^${key}=/d" "$sf"
	fi
	printf '%s=%s\n' "$key" "$value" >>"$sf"
}

state_append() {
	local sf key value current
	sf=$(state_file_path "$1" "$2" "$3")
	key="$4"
	value="$5"
	mkdir -p "$(dirname "$sf")"
	current=$(state_get "$1" "$2" "$3" "$key" || true)
	if [[ -n "$current" ]]; then
		state_set "$1" "$2" "$3" "$key" "${current}__${value}"
	else
		state_set "$1" "$2" "$3" "$key" "$value"
	fi
}

state_del() {
	local sf key
	sf=$(state_file_path "$1" "$2" "$3")
	key="$4"
	if [[ -f "$sf" ]]; then
		sed -i "/^${key}=/d" "$sf"
	fi
}

state_del_prefix() {
	local sf prefix
	sf=$(state_file_path "$1" "$2" "$3")
	prefix="$4"
	if [[ -f "$sf" ]]; then
		sed -i "/^${prefix}/d" "$sf"
	fi
}
