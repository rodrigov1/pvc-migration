confirm() {
	local prompt="$1"
	local response
	echo -ne "${CYAN}[?]${NC} $prompt [y/N] "
	read -r response
	[[ "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}

confirm_default_yes() {
	local prompt="$1"
	local response
	echo -ne "${CYAN}[?]${NC} $prompt [Y/n] "
	read -r response
	[[ -z "$response" || "$response" =~ ^[Yy]([Ee][Ss])?$ ]]
}
