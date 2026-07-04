#!/usr/bin/env bash
#===============================================================================
# Managed-settings generator — Phase 4 (team distribution)
#
# Emits the `sshConfigs` block (and optional `sshHostAllowlist`) that
# makes the appliance appear in every member's Claude Desktop
# environment dropdown as a managed SSH target. Output goes to
# stdout; --merge folds it into an existing managed-settings JSON
# file without disturbing unrelated keys.
#
# Usage:
#   ./gen-sshconfigs.sh --host claude.example.com
#       [--ssh-user NAME]      # one entry for a single shared account
#       [--per-member]         # one entry per members.tsv row instead
#       [--start-dir ~/work]
#       [--allowlist]          # also emit sshHostAllowlist
#       [--merge FILE]         # merge into FILE (jq), print result
#
# Spec: docs/phases.md (Phase 4)
#===============================================================================

cws_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# shellcheck source=lib/common.sh
source "$cws_dir/lib/common.sh"

appliance_etc="${APPLIANCE_ETC:-/etc/claude-appliance}"

# One sshConfigs entry as JSON. Args: id name ssh_host start_dir
ssh_entry() {
	jq -n --arg id "$1" --arg name "$2" --arg host "$3" \
		--arg dir "$4" '
		{ id: $id, name: $name, sshHost: $host, sshPort: 22 }
		+ (if $dir == "" then {} else { startDirectory: $dir } end)'
}

# Emit the managed-settings JSON document on stdout.
# Args: host ssh_user per_member allowlist start_dir registry_file
gen_settings() {
	local host="$1"
	local ssh_user="$2"
	local per_member="$3"
	local allowlist="$4"
	local start_dir="$5"
	local registry="$6"

	local entries='[]'
	if [[ $per_member -eq 1 ]]; then
		if [[ ! -f $registry ]]; then
			log_err "no member registry at $registry"
			return 1
		fi
		local name _rest entry
		while IFS=$'\t' read -r name _rest; do
			[[ -z $name ]] && continue
			entry=$(ssh_entry "appliance-$name" \
				"Cowork appliance ($name)" \
				"$name@$host" "$start_dir") || return 1
			entries=$(jq --argjson e "$entry" '. + [$e]' \
				<<< "$entries") || return 1
		done < "$registry"
	else
		local entry
		entry=$(ssh_entry 'cowork-appliance' 'Cowork appliance' \
			"$ssh_user@$host" "$start_dir") || return 1
		entries=$(jq --argjson e "$entry" '. + [$e]' \
			<<< "$entries") || return 1
	fi

	local doc
	doc=$(jq -n --argjson c "$entries" '{ sshConfigs: $c }') || return 1
	if [[ $allowlist -eq 1 ]]; then
		doc=$(jq --arg h "$host" '. + { sshHostAllowlist: [$h] }' \
			<<< "$doc") || return 1
	fi
	printf '%s\n' "$doc"
}

main() {
	local host='' ssh_user='' per_member=0 allowlist=0
	local start_dir='' merge_file=''

	while [[ $# -gt 0 ]]; do
		case "$1" in
			--host)       require_value "$@" || return 1
			              host="$2"; shift 2 ;;
			--ssh-user)   require_value "$@" || return 1
			              ssh_user="$2"; shift 2 ;;
			--per-member) per_member=1; shift ;;
			--start-dir)  require_value "$@" || return 1
			              start_dir="$2"; shift 2 ;;
			--allowlist)  allowlist=1; shift ;;
			--merge)      require_value "$@" || return 1
			              merge_file="$2"; shift 2 ;;
			-h|--help)
				sed -n '2,19p' "${BASH_SOURCE[0]}" \
					| sed 's/^# \{0,1\}//'
				return 0
				;;
			*)
				log_err "unknown argument '$1'"
				return 1
				;;
		esac
	done

	if [[ -z $host ]]; then
		log_err '--host is required'
		return 1
	fi
	if [[ $per_member -eq 0 && -z $ssh_user ]]; then
		log_err 'pass --ssh-user NAME or --per-member'
		return 1
	fi

	local settings
	settings=$(gen_settings "$host" "$ssh_user" "$per_member" \
		"$allowlist" "$start_dir" "$appliance_etc/members.tsv") \
		|| return 1

	if [[ -n $merge_file ]]; then
		if [[ ! -f $merge_file ]]; then
			log_err "merge target $merge_file does not exist"
			return 1
		fi
		jq -s '.[0] * .[1]' "$merge_file" <(printf '%s' "$settings")
	else
		printf '%s\n' "$settings"
	fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
