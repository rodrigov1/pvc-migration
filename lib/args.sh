# ---- Command-line argument helpers ----

CLI_CONTEXT=""
CLI_NAMESPACE=""
CLI_MIGRATION=""
CLI_ARGS=()
DISCOVERY_DEPLOY=""
DISCOVERY_PVC=""
COPY_COMPRESS=false

cli_usage_error() {
	local command="$1" message="$2"
	log_error "$message"
	usage "$command" 1 || true
	return 1
}

parse_common_args() {
	local command="$1"
	shift

	CLI_CONTEXT=""
	CLI_NAMESPACE=""
	CLI_MIGRATION=""
	CLI_ARGS=()

	local context_seen=false namespace_seen=false migration_seen=false
	local value
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--context | -c)
			if [[ $# -lt 2 || -z "${2:-}" || "${2:0:1}" == "-" ]]; then
				cli_usage_error "$command" "Missing value for $1 (expected a context name)." || true
				return 1
			fi
			if $context_seen; then
				cli_usage_error "$command" "Option --context/-c was specified more than once." || true
				return 1
			fi
			CLI_CONTEXT="$2"
			context_seen=true
			shift 2
			;;
		--context=*)
			value="${1#*=}"
			if [[ -z "$value" ]]; then
				cli_usage_error "$command" "Missing value for --context (expected a context name)." || true
				return 1
			fi
			if $context_seen; then
				cli_usage_error "$command" "Option --context/-c was specified more than once." || true
				return 1
			fi
			CLI_CONTEXT="$value"
			context_seen=true
			shift
			;;
		--namespace | -n)
			if [[ $# -lt 2 || -z "${2:-}" || "${2:0:1}" == "-" ]]; then
				cli_usage_error "$command" "Missing value for $1 (expected a namespace)." || true
				return 1
			fi
			if $namespace_seen; then
				cli_usage_error "$command" "Option --namespace/-n was specified more than once." || true
				return 1
			fi
			CLI_NAMESPACE="$2"
			namespace_seen=true
			shift 2
			;;
		--namespace=*)
			value="${1#*=}"
			if [[ -z "$value" ]]; then
				cli_usage_error "$command" "Missing value for --namespace (expected a namespace)." || true
				return 1
			fi
			if $namespace_seen; then
				cli_usage_error "$command" "Option --namespace/-n was specified more than once." || true
				return 1
			fi
			CLI_NAMESPACE="$value"
			namespace_seen=true
			shift
			;;
		--migration | -m)
			if [[ $# -lt 2 || -z "${2:-}" || "${2:0:1}" == "-" ]]; then
				cli_usage_error "$command" "Missing value for $1 (expected a migration label)." || true
				return 1
			fi
			if $migration_seen; then
				cli_usage_error "$command" "Option --migration/-m was specified more than once." || true
				return 1
			fi
			CLI_MIGRATION="$2"
			migration_seen=true
			shift 2
			;;
		--migration=*)
			value="${1#*=}"
			if [[ -z "$value" ]]; then
				cli_usage_error "$command" "Missing value for --migration (expected a migration label)." || true
				return 1
			fi
			if $migration_seen; then
				cli_usage_error "$command" "Option --migration/-m was specified more than once." || true
				return 1
			fi
			CLI_MIGRATION="$value"
			migration_seen=true
			shift
			;;
		*)
			CLI_ARGS+=("$1")
			shift
			;;
		esac
	done
}

require_common_args() {
	local command="$1"
	local -a missing=()
	[[ -n "$CLI_CONTEXT" ]] || missing+=("--context/-c")
	[[ -n "$CLI_NAMESPACE" ]] || missing+=("--namespace/-n")
	[[ -n "$CLI_MIGRATION" ]] || missing+=("--migration/-m")

	if [[ ${#missing[@]} -gt 0 ]]; then
		cli_usage_error "$command" "Missing required option(s): ${missing[*]}." || true
		return 1
	fi
}

require_no_command_args() {
	local command="$1"
	if [[ ${#CLI_ARGS[@]} -gt 0 ]]; then
		cli_usage_error "$command" "Unexpected option or positional argument: ${CLI_ARGS[0]}" || true
		return 1
	fi
}

parse_discovery_args() {
	local command="$1"
	local option value
	DISCOVERY_DEPLOY=""
	DISCOVERY_PVC=""

	while [[ ${#CLI_ARGS[@]} -gt 0 ]]; do
		option="${CLI_ARGS[0]}"
		case "$option" in
		--deploy)
			if [[ ${#CLI_ARGS[@]} -lt 2 || -z "${CLI_ARGS[1]}" || "${CLI_ARGS[1]:0:1}" == "-" ]]; then
				cli_usage_error "$command" "Missing value for --deploy." || true
				return 1
			fi
			if [[ -n "$DISCOVERY_DEPLOY" ]]; then
				cli_usage_error "$command" "Option --deploy was specified more than once." || true
				return 1
			fi
			DISCOVERY_DEPLOY="${CLI_ARGS[1]}"
			CLI_ARGS=("${CLI_ARGS[@]:2}")
			;;
		--pvc)
			if [[ ${#CLI_ARGS[@]} -lt 2 || -z "${CLI_ARGS[1]}" || "${CLI_ARGS[1]:0:1}" == "-" ]]; then
				cli_usage_error "$command" "Missing value for --pvc." || true
				return 1
			fi
			if [[ -n "$DISCOVERY_PVC" ]]; then
				cli_usage_error "$command" "Option --pvc was specified more than once." || true
				return 1
			fi
			DISCOVERY_PVC="${CLI_ARGS[1]}"
			CLI_ARGS=("${CLI_ARGS[@]:2}")
			;;
		--deploy=*)
			value="${option#*=}"
			if [[ -z "$value" ]]; then
				cli_usage_error "$command" "Missing value for --deploy." || true
				return 1
			fi
			if [[ -n "$DISCOVERY_DEPLOY" ]]; then
				cli_usage_error "$command" "Option --deploy was specified more than once." || true
				return 1
			fi
			DISCOVERY_DEPLOY="$value"
			CLI_ARGS=("${CLI_ARGS[@]:1}")
			;;
		--pvc=*)
			value="${option#*=}"
			if [[ -z "$value" ]]; then
				cli_usage_error "$command" "Missing value for --pvc." || true
				return 1
			fi
			if [[ -n "$DISCOVERY_PVC" ]]; then
				cli_usage_error "$command" "Option --pvc was specified more than once." || true
				return 1
			fi
			DISCOVERY_PVC="$value"
			CLI_ARGS=("${CLI_ARGS[@]:1}")
			;;
		*)
			cli_usage_error "$command" "Unknown option or positional argument: $option" || true
			return 1
			;;
		esac
	done
}

parse_copy_args() {
	local command="$1"
	COPY_COMPRESS=false

	while [[ ${#CLI_ARGS[@]} -gt 0 ]]; do
		case "${CLI_ARGS[0]}" in
		--compress)
			if $COPY_COMPRESS; then
				cli_usage_error "$command" "Option --compress was specified more than once." || true
				return 1
			fi
			COPY_COMPRESS=true
			CLI_ARGS=("${CLI_ARGS[@]:1}")
			;;
		*)
			cli_usage_error "$command" "Unknown option or positional argument: ${CLI_ARGS[0]}" || true
			return 1
			;;
		esac
	done
}
