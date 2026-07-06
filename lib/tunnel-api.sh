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

appliance_etc="${APPLIANCE_ETC:-/etc/coworkstation}"

cf_api_base='https://api.cloudflare.com/client/v4'

# Transport. $1=method $2=path (starts with /) $3=optional JSON body.
# Emits the raw response JSON on stdout.
#
# The Authorization header is fed through `curl --config -` (stdin), NOT
# argv: this box is multi-user and /proc/<pid>/cmdline is world-readable,
# so a token on curl's argv would be scrapeable by any member. The token
# is edge-wide (Tunnel/DNS/Access edit), so this matters.
cf_api() {
	local method="$1"
	local path="$2"
	local body="${3:-}"
	local args=(-sS -X "$method" "$cf_api_base$path"
		-H 'Content-Type: application/json'
		--config -)
	if [[ -n $body ]]; then
		args+=(--data "$body")
	fi
	printf 'header = "Authorization: Bearer %s"\n' "$cf_api_token" \
		| curl "${args[@]}"
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
	if [[ $cf_api_token == 'YOUR-CF-API-TOKEN' ]]; then
		log_err "that's the README placeholder, not a token —" \
			"put your real Cloudflare API token in $file"
		return 1
	fi
	if [[ ${#cf_api_token} -lt 30 ]]; then
		log_err "token in $file is ${#cf_api_token} chars —" \
			'Cloudflare API tokens are ~40; did the paste truncate?'
		return 1
	fi
	cf_call GET /user/tokens/verify > /dev/null || {
		log_err 'Cloudflare API token failed verification — check it'
		log_err '  is Active in the dashboard and has the three'
		log_err '  permissions from the README (Tunnel/Access/DNS)'
		return 1
	}
}

# First (usually only) account the token can see. Note: a token scoped
# only to specific resources (DNS/Tunnel/Access edit) CANNOT list
# /accounts — Cloudflare returns an empty array (success:true, result:[]),
# not an error — so this yields empty for exactly the tokens the README
# tells users to create. cf_account_for_zone is the robust primary.
# (All helpers capture cf_call before jq: piping into jq would mask a
# transport failure as an empty result.)
cf_account_id() {
	local resp
	resp=$(cf_call GET /accounts) || return 1
	jq -r '.[0].id // empty' <<< "$resp"
}

# Account that owns a zone. cf_call has already unwrapped .result, so the
# account object is at .account. This works with a resource-scoped token
# (the one setup.sh asks for) because it only needs to read the zone the
# hostname lives in — no account-list permission required.
cf_account_for_zone() {
	local zone_id="$1"
	local resp
	resp=$(cf_call GET "/zones/$zone_id") || return 1
	jq -r '.account.id // empty' <<< "$resp"
}

# Walk the hostname right-to-left until a zone matches.
# Echoes "zone_id zone_name"; fails when no suffix is a zone.
cf_zone_for_hostname() {
	local hostname="$1"
	local candidate="$hostname"
	local zone_id resp
	while [[ $candidate == *.* ]]; do
		resp=$(cf_call GET "/zones?name=$candidate") || return 1
		zone_id=$(jq -r '.[0].id // empty' <<< "$resp")
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
	local id resp
	# Capture cf_call separately: piping straight into jq would mask a
	# transient GET failure (jq exits 0 on empty input), and an empty id
	# then falls through to POST — creating a SECOND tunnel of the same
	# name (Cloudflare allows duplicates) and breaking adopt-existing.
	resp=$(cf_call GET \
		"/accounts/$account/cfd_tunnel?name=$name&is_deleted=false") \
		|| return 1
	id=$(jq -r '.[0].id // empty' <<< "$resp")
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
	local resp
	resp=$(cf_call GET "/accounts/$account/cfd_tunnel/$tunnel/token") \
		|| return 1
	jq -r '.' <<< "$resp"
}

# Current remote ingress array (JSON). Empty array when unset.
cf_tunnel_get_ingress() {
	local account="$1"
	local tunnel="$2"
	local resp
	resp=$(cf_call GET \
		"/accounts/$account/cfd_tunnel/$tunnel/configurations") \
		|| return 1
	jq '.config.ingress // []' <<< "$resp"
}

# Pure transform: insert hostname->port before the catch-all, keeping
# the catch-all last and existing rules intact. Reads ingress JSON on
# stdin, writes the new array on stdout. Idempotent per hostname AND
# reconciling: an existing rule whose service differs (a member's port
# moved) is updated in place, not silently kept stale.
ingress_json_add() {
	local hostname="$1"
	local port="$2"
	jq --arg h "$hostname" --arg p "$port" '
		("http://127.0.0.1:" + $p) as $svc
		| if any(.[]; .hostname == $h and .service == $svc) then .
		  elif any(.[]; .hostname == $h) then
			[.[] | if .hostname == $h
			       then .service = $svc else . end]
		  else
			[.[] | select(.service != "http_status:404")]
			+ [{hostname: $h, service: $svc}]
			+ [{service: "http_status:404"}]
		  end'
}

# Pure transform: add a PATH rule (hostname + path -> port). Cloudflared
# evaluates ingress in order and a bare-hostname rule swallows every
# path, so the path rule is inserted BEFORE the first rule for the same
# hostname (or before the catch-all when the hostname has no plain rule
# yet). Idempotent + reconciling like ingress_json_add.
# Args: hostname path_regex port
ingress_json_add_path() {
	local hostname="$1"
	local path_re="$2"
	local port="$3"
	jq --arg h "$hostname" --arg pa "$path_re" --arg p "$port" '
		("http://127.0.0.1:" + $p) as $svc
		| {hostname: $h, path: $pa, service: $svc} as $rule
		| if any(.[]; .hostname == $h and .path == $pa
			and .service == $svc) then .
		  elif any(.[]; .hostname == $h and .path == $pa) then
			[.[] | if .hostname == $h and .path == $pa
			       then .service = $svc else . end]
		  else
			(map(.hostname == $h and (has("path") | not))
				| index(true)) as $host_i
			| ([.[] | .service == "http_status:404"]
				| index(true)) as $catch_i
			| ($host_i // $catch_i // length) as $at
			| .[:$at] + [$rule] + .[$at:]
		  end'
}

# Route /bridge/* on a session hostname to a local port, through the
# recorded api-mode tunnel. Args: hostname port
tunnel_api_bridge_route() {
	local hostname="$1"
	local port="$2"
	local token_file account tunnel
	token_file=$(tunnel_conf_get token_file) || return 1
	account=$(tunnel_conf_get account_id) || return 1
	tunnel=$(tunnel_conf_get tunnel_id) || return 1

	tunnel_api_load_token "$token_file" || return 1
	local ingress
	ingress=$(cf_tunnel_get_ingress "$account" "$tunnel" \
		| ingress_json_add_path "$hostname" '^/bridge(/.*)?$' \
			"$port") || return 1
	cf_tunnel_put_ingress "$account" "$tunnel" "$ingress" || return 1
	log_info "bridge route ready: https://$hostname/bridge/"
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
	local resp existing
	resp=$(cf_call GET \
		"/zones/$zone/dns_records?type=CNAME&name=$hostname") \
		|| return 1
	existing=$(jq -r '.[0].id // empty' <<< "$resp")
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
	local resp id
	resp=$(cf_call GET \
		"/zones/$zone/dns_records?type=CNAME&name=$hostname") \
		|| return 1
	id=$(jq -r '.[0].id // empty' <<< "$resp")
	[[ -z $id ]] && return 0
	cf_call DELETE "/zones/$zone/dns_records/$id" > /dev/null
}

# Validate --access-allow BEFORE any provisioning (pure bash: runs
# before jq is installed on a fresh box). Rules:
#   - at least one well-formed entry must survive parsing (an empty
#     include array would provision a policy that admits no one — or
#     worse, be rejected mid-provision after the tunnel exists);
#   - each entry is an email (user@domain.tld) or a bare domain;
#   - a PUBLIC mail provider as a bare domain (gmail.com, ...) would
#     admit every account at that provider — hard error, since it is
#     never what an operator means.
validate_access_allow() {
	local allow_csv="$1"
	local entry ok=0
	local -a parts
	IFS=',' read -ra parts <<< "$allow_csv"
	for entry in "${parts[@]}"; do
		# trim surrounding whitespace
		entry="${entry#"${entry%%[![:space:]]*}"}"
		entry="${entry%"${entry##*[![:space:]]}"}"
		[[ -z $entry ]] && continue
		if [[ $entry == *@* ]]; then
			if [[ ! $entry =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]
			then
				log_err "--access-allow entry '$entry' is not a" \
					'valid email'
				return 1
			fi
		else
			if [[ ! $entry =~ ^[a-z0-9]([a-z0-9-]*)(\.[a-z0-9]([a-z0-9-]*))+$ ]]
			then
				log_err "--access-allow entry '$entry' is not a" \
					'valid email domain'
				return 1
			fi
			case "$entry" in
				gmail.com|googlemail.com|outlook.com|hotmail.com|\
				live.com|yahoo.com|icloud.com|me.com|aol.com|\
				proton.me|protonmail.com|gmx.com|mail.com)
					log_err "--access-allow domain '$entry' is a" \
						'PUBLIC mail provider: it would admit EVERY' \
						"account there. List emails instead:" \
						"you@$entry"
					return 1
					;;
			esac
		fi
		ok=1
	done
	if [[ $ok -ne 1 ]]; then
		log_err '--access-allow contains no usable entries'
		return 1
	fi
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
	local apps_resp app_id
	apps_resp=$(cf_call GET "/accounts/$account/access/apps") \
		|| return 1
	app_id=$(jq -r --arg d "$hostname" \
		'[.[] | select(.domain == $d)][0].id // empty' \
		<<< "$apps_resp")
	if [[ -z $app_id ]]; then
		app_id=$(cf_call POST "/accounts/$account/access/apps" \
			"$(jq -n --arg d "$hostname" \
				'{name: ("Coworkstation " + $d),
				  domain: $d, type: "self_hosted",
				  session_duration: "24h"}')" \
			| jq -r '.id') || return 1
		log_info "created Access app for $hostname"
	else
		log_info "Access app for $hostname already present"
	fi
	# Create the allow policy, or reconcile an existing one whose
	# include list no longer matches --access-allow (a changed allow
	# list used to be silently ignored on re-run).
	local resp want have policy_id
	resp=$(cf_call GET \
		"/accounts/$account/access/apps/$app_id/policies") || return 1
	want=$(access_include_json "$allow_csv")
	if [[ $(jq 'length' <<< "$resp") -eq 0 ]]; then
		cf_call POST \
			"/accounts/$account/access/apps/$app_id/policies" \
			"$(jq -n --argjson inc "$want" \
				'{name: "coworkstation members", decision: "allow",
				  include: $inc}')" > /dev/null || return 1
		log_info "created allow policy ($allow_csv)"
		return 0
	fi
	policy_id=$(jq -r '.[0].id' <<< "$resp")
	have=$(jq -cS '[.[0].include[]? | {email: .email, email_domain:
		.email_domain} | with_entries(select(.value != null))]' \
		<<< "$resp")
	# Quote the RHS: inside [[ ]] an unquoted != operand is a glob
	# pattern, and JSON's [ ] { } make it one that never matches.
	if [[ $have != "$(jq -cS . <<< "$want")" ]]; then
		cf_call PUT \
			"/accounts/$account/access/apps/$app_id/policies/$policy_id" \
			"$(jq -n --argjson inc "$want" \
				'{name: "coworkstation members", decision: "allow",
				  include: $inc}')" > /dev/null || return 1
		log_info "updated allow policy to match ($allow_csv)"
	fi
}

cf_access_remove_app() {
	local account="$1"
	local hostname="$2"
	local resp app_id
	resp=$(cf_call GET "/accounts/$account/access/apps") || return 1
	app_id=$(jq -r --arg d "$hostname" \
		'[.[] | select(.domain == $d)][0].id // empty' <<< "$resp")
	[[ -z $app_id ]] && return 0
	cf_call DELETE "/accounts/$account/access/apps/$app_id" \
		> /dev/null
}

# Persist the api-mode deployment shape for member.sh and the doctor.
# Connector unit generator: our OWN unit name, token via a 0600
# EnvironmentFile (cloudflared reads TUNNEL_TOKEN) — never on argv.
cws_cloudflared_unit() {
	cat << 'EOF'
[Unit]
Description=Coworkstation tunnel connector (cloudflared)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/coworkstation/tunnel-token
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

# Install the session-tunnel connector under cws-cloudflared.service.
# NEVER the distro unit name: an operator's pre-existing
# cloudflared.service (an SSH tunnel, say) made the old
# is-active-check skip our install entirely — the session hostnames
# then 530/1033 the moment anything actually needs the tunnel (found
# live; Access had been answering at the edge and masking it).
# A pre-existing cloudflared.service carrying OUR tunnel's token
# (earlier installs used `cloudflared service install`) is disabled;
# one carrying a foreign token is left alone and noted.
# Args: connector_token tunnel_id
tunnel_api_install_connector() {
	local conn_token="$1"
	local tunnel="$2"
	if [[ ${appliance_dry_run:-0} -eq 1 ]]; then
		printf 'DRY-RUN: install cws-cloudflared.service (tunnel %s)\n' \
			"$tunnel"
		return 0
	fi
	printf 'TUNNEL_TOKEN=%s\n' "$conn_token" \
		| appliance_force=1 write_file "$appliance_etc/tunnel-token" 600 \
		|| return 1
	cws_cloudflared_unit \
		| write_file \
			"${APPLIANCE_SYSTEMD_DIR:-/etc/systemd/system}/cws-cloudflared.service" \
		|| return 1
	# Migrate/coexist with a pre-existing distro-named service.
	if systemctl list-unit-files cloudflared.service \
		--no-legend 2> /dev/null | grep -q .; then
		local old_t
		old_t=$(systemctl cat cloudflared 2> /dev/null \
			| grep -oP -- '--token \K\S+' | head -1 \
			| base64 -d 2> /dev/null | jq -r '.t // empty' 2> /dev/null)
		if [[ $old_t == "$tunnel" ]]; then
			log_info 'migrating old cloudflared.service (same tunnel)' \
				'to cws-cloudflared.service'
			run_cmd systemctl disable --now cloudflared.service
		elif [[ -n $old_t ]]; then
			log_info "leaving cloudflared.service alone (foreign" \
				"tunnel ${old_t:0:8}…, e.g. your own SSH tunnel)"
		fi
	fi
	run_cmd systemctl daemon-reload || return 1
	run_cmd systemctl enable --now cws-cloudflared.service
}

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
		printf '    ensure tunnel "coworkstation-%s" (remote-managed)\n' \
			"${hostname//./-}"
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
	local zone_pair zone_id zone_name
	zone_pair=$(cf_zone_for_hostname "$hostname") || return 1
	zone_id="${zone_pair%% *}"
	zone_name="${zone_pair#* }"
	if [[ -z $zone_id || -z $zone_name ]]; then
		return 1
	fi
	# Derive the account from the zone (the scoped token can read it);
	# fall back to /accounts only for broadly-scoped tokens.
	local account
	account=$(cf_account_for_zone "$zone_id")
	if [[ -z $account ]]; then
		account=$(cf_account_id)
	fi
	if [[ -z $account ]]; then
		log_err "could not determine Cloudflare account for $hostname" \
			'(token needs Zone:Read on its zone, or Account:Read)'
		return 1
	fi

	# Tunnel name is derived from the hostname: a FIXED name means two
	# Coworkstation boxes in one Cloudflare account would adopt the SAME
	# tunnel and merge their ingress — each hostname then routes through
	# whichever box's connector picks up, which cannot reach the other
	# box's loopback. Per-hostname names keep boxes independent.
	local tunnel tunnel_name
	tunnel_name="coworkstation-${hostname//./-}"
	tunnel=$(cf_tunnel_ensure "$account" "$tunnel_name") \
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

	local conn_token
	conn_token=$(cf_tunnel_token "$account" "$tunnel") || return 1
	tunnel_api_install_connector "$conn_token" "$tunnel" || return 1
	log_info "zero-touch tunnel ready: https://$hostname"
	log_info "  Access allow list: $allow_csv"
}

# Hostname for a child surface (member, extra session) under the
# session hostname. Cloudflare's free Universal SSL only covers ONE
# label below the zone, so NAME.cws.zone (two deep) fails TLS at the
# edge — found live. When the zone is known (api mode records
# zone_name) and the base sits below the zone, flatten to
# NAME-<baselabel>.zone; at the zone apex, NAME.zone is fine.
# Manual mode (no zone recorded) keeps the dotted form and the
# caller should warn about certificate depth.
tunnel_api_child_hostname() {
	local name="$1"
	local base="$2"
	local zone
	zone=$(tunnel_conf_get zone_name 2> /dev/null) || zone=''
	if [[ -z $zone || $base == "$zone" ]]; then
		printf '%s.%s' "$name" "$base"
	else
		printf '%s-%s.%s' "$name" "${base%%.*}" "$zone"
	fi
}

# Member-level api-mode operations (called by member.sh when
# tunnel.conf says mode=api).
# Args: member_hostname port [allow_csv]
# A non-empty allow_csv scopes the member hostname's Access policy
# to just those identities (forced per-member auth) instead of the
# box-wide allow list.
tunnel_api_member_add() {
	local hostname="$1"
	local port="$2"
	local allow_override="${3:-}"
	local token_file account tunnel zone_id allow_csv
	token_file=$(tunnel_conf_get token_file) || return 1
	account=$(tunnel_conf_get account_id) || return 1
	tunnel=$(tunnel_conf_get tunnel_id) || return 1
	zone_id=$(tunnel_conf_get zone_id) || return 1
	allow_csv=$(tunnel_conf_get access_allow) || return 1
	if [[ -n $allow_override ]]; then
		allow_csv="$allow_override"
	fi

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
