#!/usr/bin/env bash
#===============================================================================
# Test bench provisioning — Phase 3
#
# Installs the Tier 1/2 dependencies (nested displays, input, capture,
# accessibility) and registers the two MCP servers into a member's
# claude_desktop_config.json (merge, never overwrite).
#
# Usage:
#   sudo appliance/testbench/setup.sh [--user NAME] [--dry-run]
#
# Spec: docs/phases.md (Phase 3)
#===============================================================================

testbench_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$testbench_dir/../lib/common.sh"

install_testbench_packages() {
	pkg_install xvfb xdotool imagemagick jq \
		at-spi2-core python3-pyatspi qemu-utils
}

# Merge the MCP server entries into the member's config. jq handles
# the merge so unrelated keys (their own MCP servers) are preserved
# byte-for-byte in value terms.
# $1 = user
register_mcp_servers() {
	local user="$1"
	local home
	home=$(user_home "$user") || return 1
	local conf_dir="$home/.config/Claude"
	local conf="$conf_dir/claude_desktop_config.json"

	local addition
	addition=$(mcp_config_snippet "$testbench_dir")

	run_as_user "$user" mkdir -p "$conf_dir" || return 1

	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: merge into %s:\n%s\n' "$conf" "$addition"
		return 0
	fi

	local base='{}'
	if [[ -s $conf ]]; then
		base=$(cat "$conf")
	fi
	local merged
	merged=$(jq -s '.[0] * .[1]' \
		<(printf '%s' "$base") <(printf '%s' "$addition")) || {
		log_err "existing $conf is not valid JSON; not touching it"
		return 1
	}
	printf '%s\n' "$merged" > "$conf" || return 1
	chown "$user:$user" "$conf"
	log_info "registered test bench MCP servers in $conf"
}

# The mcpServers fragment pointing at this checkout's server scripts.
# $1 = directory containing the MCP server .js files
mcp_config_snippet() {
	local dir="$1"
	cat << EOF
{
  "mcpServers": {
    "desktop-control": {
      "command": "node",
      "args": ["${dir}/desktop-control-mcp.js"]
    },
    "vm-bench": {
      "command": "node",
      "args": ["${dir}/vm-bench-mcp.js"]
    }
  }
}
EOF
}

main() {
	local user=''
	appliance_dry_run=0
	appliance_force=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--user)    require_value "$@" || return 1
			           user="$2"; shift 2 ;;
			--dry-run) appliance_dry_run=1; shift ;;
			-h|--help)
				sed -n '2,13p' "${BASH_SOURCE[0]}" \
					| sed 's/^# \{0,1\}//'
				return 0
				;;
			*)
				log_err "unknown argument '$1'"
				return 1
				;;
		esac
	done

	user=$(resolve_target_user "$user") || return 1
	require_root || return 1

	install_testbench_packages || return 1
	register_mcp_servers "$user" || return 1

	log_info 'test bench ready. Playwright MCP for web/Electron work:'
	log_info '  claude mcp add playwright -- npx @playwright/mcp@latest'
	log_info 'vm-bench needs a guest disk image; see the phase spec.'
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
