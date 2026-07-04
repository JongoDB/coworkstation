# shellcheck shell=bash
#===============================================================================
# Cloudflare API helpers — zero-touch tunnel provisioning (Phase 1.5)
#
# With a scoped API token (Account > Cloudflare Tunnel:Edit, Account >
# Access: Apps and Policies:Edit, Zone > DNS:Edit), the whole edge can
# be provisioned non-interactively: a remotely-managed tunnel, its
# ingress config, the proxied DNS CNAME, and the Access application
# that gates the hostname. Without a token, setup.sh falls back to the
# guided manual flow (cloudflared tunnel login ...).
#
# All calls go through cf_api(), which BATS overrides with fixtures.
# Every ensure_* function is idempotent: GET-by-name before POST.
#
# Consumers: appliance/setup.sh, appliance/member.sh.
# Sourced globals: cf_api_token (set by tunnel_api_load_token).
#===============================================================================

appliance_etc="${APPLIANCE_ETC:-/etc/claude-appliance}"

cf_api_base='https://api.cloudflare.com/client/v4'

# Transport. $1=method $2=path (starts with /) $3=optional JSON body.
# Emits the raw response JSON on stdout.
cf_api() {
	local method="$1"
	local path="$2"
	local body="${3:-}"
	local args=(-sS -X "$method" "$cf_api_base$path"
		-H "Authorization: Bearer $cf_api_token"
		-H 'Content-Type: application/json')
	if [[ -n $body ]]; then
		args+=(--data "$body")
	fi
	curl "${args[@]}"
}

# Wrapper that fails loudly when .success != true.
# Usage: cf_call <method> <path> [body]  → .result JSON on stdout
cf_call() {
	local response
	response=$(cf_api "$@") || return 1
	if [[ $(jq -r '.success' <<< "$response") != 'true' ]]; then
		log_err "Cloudflare API $1 $2 failed:"
		jq -r '.errors[]?.message // "unknown error"' \
			<<< "$response" >&2
		return 1
	fi
	jq '.result' <<< "$response"
}

# Read the token from a file (never argv — argv leaks via ps).
tunnel_api_load_token() {
	local file="$1"
	if [[ ! -f $file ]]; then
		log_err "token file not found: $file"
		return 1
	fi
	cf_api_token=$(< "$file")
	cf_api_token="${cf_api_token//[$'\r\n\t ']/}"
	if [[ -z $cf_api_token ]]; then
		log_err "token file is empty: $file"
		return 1
	fi
	cf_call GET /user/tokens/verify > /dev/null || {
		log_err 'Cloudflare API token failed verification'
		return 1
	}
}

# First (usually only) account the token can see.
cf_account_id() {
	cf_call GET /accounts | jq -r '.[0].id // empty'
}

# Walk the hostname right-to-left until a zone matches.
# Echoes "zone_id zone_name"; fails when no suffix is a zone.
cf_zone_for_hostname() {
	local hostname="$1"
	local candidate="$hostname"
	local zone_id
	while [[ $candidate == *.* ]]; do
		zone_id=$(cf_call GET "/zones?name=$candidate" \
			| jq -r '.[0].id // empty') || return 1
		if [[ -n $zone_id ]]; then
			printf '%s %s' "$zone_id" "$candidate"
			return 0
		fi
		candidate="${candidate#*.}"
	done
	log_err "no Cloudflare zone found for $hostname"
	return 1
}

# Create-or-adopt a remotely-managed tunnel by name. Echoes tunnel id.
cf_tunnel_ensure() {
	local account="$1"
	local name="$2"
	local id
	id=$(cf_call GET \
		"/accounts/$account/cfd_tunnel?name=$name&is_deleted=false" \
		| jq -r '.[0].id // empty') || return 1
	if [[ -n $id ]]; then
		# stdout is this function's return value; log to stderr.
		log_info "adopting existing tunnel '$name' ($id)" >&2
		printf '%s' "$id"
		return 0
	fi
	cf_call POST "/accounts/$account/cfd_tunnel" \
		"$(jq -n --arg n "$name" \
			'{name: $n, config_src: "cloudflare"}')" \
		| jq -r '.id'
}

# Connector token for `cloudflared service install`.
cf_tunnel_token() {
	local account="$1"
	local tunnel="$2"
	cf_call GET "/accounts/$account/cfd_tunnel/$tunnel/token" \
		| jq -r '.'
}

# Current remote ingress array (JSON). Empty array when unset.
cf_tunnel_get_ingress() {
	local account="$1"
	local tunnel="$2"
	cf_call GET \
		"/accounts/$account/cfd_tunnel/$tunnel/configurations" \
		| jq '.config.ingress // []'
}

# Pure transform: insert hostname->port before the catch-all, keeping
# the catch-all last and existing rules intact. Reads ingress JSON on
# stdin, writes the new array on stdout. Idempotent per hostname.
ingress_json_add() {
	local hostname="$1"
	local port="$2"
	jq --arg h "$hostname" --arg p "$port" '
		if any(.[]; .hostname == $h) then .
		else
			[.[] | select(.service != "http_status:404")]
			+ [{hostname: $h,
			    service: ("http://127.0.0.1:" + $p)}]
			+ [{service: "http_status:404"}]
		end'
}

# Pure transform: drop a hostname rule. stdin/stdout as above.
ingress_json_remove() {
	local hostname="$1"
	jq --arg h "$hostname" '[.[] | select(.hostname != $h)]'
}

# PUT the full ingress array back. $3 = ingress JSON.
cf_tunnel_put_ingress() {
	local account="$1"
	local tunnel="$2"
	local ingress="$3"
	cf_call PUT \
		"/accounts/$account/cfd_tunnel/$tunnel/configurations" \
		"$(jq -n --argjson i "$ingress" '{config: {ingress: $i}}')" \
		> /dev/null
}

# Proxied CNAME hostname -> <tunnel>.cfargotunnel.com, once.
cf_dns_ensure_cname() {
	local zone="$1"
	local hostname="$2"
	local tunnel="$3"
	local existing
	existing=$(cf_call GET \
		"/zones/$zone/dns_records?type=CNAME&name=$hostname" \
		| jq -r '.[0].id // empty') || return 1
	if [[ -n $existing ]]; then
		log_info "DNS record for $hostname already present"
		return 0
	fi
	cf_call POST "/zones/$zone/dns_records" \
		"$(jq -n --arg n "$hostname" --arg t "$tunnel" \
			'{type: "CNAME", name: $n, proxied: true,
			  content: ($t + ".cfargotunnel.com")}')" > /dev/null
}

cf_dns_remove_cname() {
	local zone="$1"
	local hostname="$2"
	local id
	id=$(cf_call GET \
		"/zones/$zone/dns_records?type=CNAME&name=$hostname" \
		| jq -r '.[0].id // empty') || return 1
	[[ -z $id ]] && return 0
	cf_call DELETE "/zones/$zone/dns_records/$id" > /dev/null
}

# Build the Access policy include array from a comma list where each
# entry is an email (contains @) or an email domain.
access_include_json() {
	local allow_csv="$1"
	jq -n --arg csv "$allow_csv" '
		[$csv | split(",")[] | gsub("^\\s+|\\s+$"; "")
		 | select(length > 0)
		 | if contains("@") then {email: {email: .}}
		   else {email_domain: {domain: .}} end]'
}

# Access application + allow policy for a hostname, once. Without an
# Access app a proxied tunnel hostname is PUBLIC, so setup refuses to
# run api-mode without --access-allow.
cf_access_ensure_app() {
	local account="$1"
	local hostname="$2"
	local allow_csv="$3"
	local app_id
	app_id=$(cf_call GET "/accounts/$account/access/apps" \
		| jq -r --arg d "$hostname" \
			'[.[] | select(.domain == $d)][0].id // empty') \
		|| return 1
	if [[ -z $app_id ]]; then
		app_id=$(cf_call POST "/accounts/$account/access/apps" \
			"$(jq -n --arg d "$hostname" \
				'{name: ("Claude appliance " + $d),
				  domain: $d, type: "self_hosted",
				  session_duration: "24h"}')" \
			| jq -r '.id') || return 1
		log_info "created Access app for $hostname"
	else
		log_info "Access app for $hostname already present"
	fi
	local policies
	policies=$(cf_call GET \
		"/accounts/$account/access/apps/$app_id/policies" \
		| jq 'length') || return 1
	if [[ $policies -eq 0 ]]; then
		cf_call POST \
			"/accounts/$account/access/apps/$app_id/policies" \
			"$(jq -n --argjson inc \
				"$(access_include_json "$allow_csv")" \
				'{name: "appliance members", decision: "allow",
				  include: $inc}')" > /dev/null || return 1
		log_info "created allow policy ($allow_csv)"
	fi
}

cf_access_remove_app() {
	local account="$1"
	local hostname="$2"
	local app_id
	app_id=$(cf_call GET "/accounts/$account/access/apps" \
		| jq -r --arg d "$hostname" \
			'[.[] | select(.domain == $d)][0].id // empty') \
		|| return 1
	[[ -z $app_id ]] && return 0
	cf_call DELETE "/accounts/$account/access/apps/$app_id" \
		> /dev/null
}

# Persist the api-mode deployment shape for member.sh and the doctor.
# Args: tunnel_id account_id zone_id zone_name token_file allow_csv
tunnel_api_write_conf() {
	{
		printf 'mode=api\n'
		printf 'tunnel_id=%s\n' "$1"
		printf 'account_id=%s\n' "$2"
		printf 'zone_id=%s\n' "$3"
		printf 'zone_name=%s\n' "$4"
		printf 'token_file=%s\n' "$5"
		printf 'access_allow=%s\n' "$6"
	} | appliance_force=1 write_file "$appliance_etc/tunnel.conf" 600
}

# Read one key from tunnel.conf; fails when absent.
tunnel_conf_get() {
	local key="$1"
	local conf="$appliance_etc/tunnel.conf"
	[[ -f $conf ]] || return 1
	local value
	value=$(grep -E "^$key=" "$conf" | head -1 | cut -d= -f2-)
	[[ -n $value ]] || return 1
	printf '%s' "$value"
}

# End-to-end zero-touch provisioning for one hostname.
# Args: hostname port token_file allow_csv
tunnel_api_provision() {
	local hostname="$1"
	local port="$2"
	local token_file="$3"
	local allow_csv="$4"

	# Dry-run must never touch the network: print the plan and stop.
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: cloudflare api provisioning plan:\n'
		printf '    verify token from %s\n' "$token_file"
		printf '    ensure tunnel "claude-appliance" (remote-managed)\n'
		printf '    ingress: %s -> http://127.0.0.1:%s\n' \
			"$hostname" "$port"
		printf '    proxied CNAME %s -> <tunnel>.cfargotunnel.com\n' \
			"$hostname"
		printf '    Access app + allow policy (%s)\n' "$allow_csv"
		printf '    write %s/tunnel.conf; cloudflared service install\n' \
			"$appliance_etc"
		return 0
	fi

	tunnel_api_load_token "$token_file" || return 1
	local account
	account=$(cf_account_id) || return 1
	if [[ -z $account ]]; then
		log_err 'token cannot list any Cloudflare account'
		return 1
	fi
	local zone_pair zone_id zone_name
	zone_pair=$(cf_zone_for_hostname "$hostname") || return 1
	zone_id="${zone_pair%% *}"
	zone_name="${zone_pair#* }"
	if [[ -z $zone_id || -z $zone_name ]]; then
		return 1
	fi

	local tunnel
	tunnel=$(cf_tunnel_ensure "$account" 'claude-appliance') \
		|| return 1

	local ingress
	ingress=$(cf_tunnel_get_ingress "$account" "$tunnel" \
		| ingress_json_add "$hostname" "$port") || return 1
	cf_tunnel_put_ingress "$account" "$tunnel" "$ingress" || return 1

	cf_dns_ensure_cname "$zone_id" "$hostname" "$tunnel" || return 1
	cf_access_ensure_app "$account" "$hostname" "$allow_csv" \
		|| return 1

	# Cloudflare Universal SSL covers the apex and ONE wildcard level
	# (*.zone). Per-member hostnames are NAME.$hostname; when $hostname
	# is itself below the apex, those are two levels deep and have no
	# cert (TLS handshake failure), even though the single-user
	# $hostname works. Warn so multi-member deploys provision an
	# advanced cert for *.$hostname first.
	if [[ ${hostname%."$zone_name"} != "$zone_name" \
		&& $hostname != *.*."$zone_name" ]]; then
		log_warn "multi-member note: member hostnames" \
			"(NAME.$hostname) sit two levels below $zone_name and" \
			"are NOT covered by Cloudflare Universal SSL. Before" \
			"using member.sh, provision an advanced certificate" \
			"for *.$hostname (or host the appliance at the zone" \
			"apex)."
	fi

	tunnel_api_write_conf "$tunnel" "$account" "$zone_id" \
		"$zone_name" "$token_file" "$allow_csv" || return 1

	# Connector install. The token lands in the systemd unit that
	# `cloudflared service install` writes; the brief argv exposure
	# is root-local on a box we just provisioned as root.
	local conn_token
	conn_token=$(cf_tunnel_token "$account" "$tunnel") || return 1
	if command -v systemctl > /dev/null 2>&1 \
		&& systemctl is-active --quiet cloudflared; then
		log_info 'cloudflared service already active'
	else
		run_cmd cloudflared service install "$conn_token" || return 1
	fi
	log_info "zero-touch tunnel ready: https://$hostname"
	log_info "  Access allow list: $allow_csv"
}

# Member-level api-mode operations (called by member.sh when
# tunnel.conf says mode=api).
# Args: member_hostname port
tunnel_api_member_add() {
	local hostname="$1"
	local port="$2"
	local token_file account tunnel zone_id allow_csv
	token_file=$(tunnel_conf_get token_file) || return 1
	account=$(tunnel_conf_get account_id) || return 1
	tunnel=$(tunnel_conf_get tunnel_id) || return 1
	zone_id=$(tunnel_conf_get zone_id) || return 1
	allow_csv=$(tunnel_conf_get access_allow) || return 1

	tunnel_api_load_token "$token_file" || return 1
	local ingress
	ingress=$(cf_tunnel_get_ingress "$account" "$tunnel" \
		| ingress_json_add "$hostname" "$port") || return 1
	cf_tunnel_put_ingress "$account" "$tunnel" "$ingress" || return 1
	cf_dns_ensure_cname "$zone_id" "$hostname" "$tunnel" || return 1
	cf_access_ensure_app "$account" "$hostname" "$allow_csv"
}

# Args: member_hostname
tunnel_api_member_remove() {
	local hostname="$1"
	local token_file account tunnel zone_id
	token_file=$(tunnel_conf_get token_file) || return 1
	account=$(tunnel_conf_get account_id) || return 1
	tunnel=$(tunnel_conf_get tunnel_id) || return 1
	zone_id=$(tunnel_conf_get zone_id) || return 1

	tunnel_api_load_token "$token_file" || return 1
	local ingress
	ingress=$(cf_tunnel_get_ingress "$account" "$tunnel" \
		| ingress_json_remove "$hostname") || return 1
	cf_tunnel_put_ingress "$account" "$tunnel" "$ingress" || return 1
	cf_dns_remove_cname "$zone_id" "$hostname" || return 1
	cf_access_remove_app "$account" "$hostname"
}
