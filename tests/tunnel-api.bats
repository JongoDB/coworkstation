#!/usr/bin/env bats
#
# appliance-tunnel-api.bats
# Tests for the zero-touch Cloudflare provisioning layer
# (appliance/lib/tunnel-api.sh), driven against a stubbed cf_api.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"
	mkdir -p "$APPLIANCE_ETC"

	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"
	# shellcheck source=lib/tunnel-api.sh
	source "$SCRIPT_DIR/../lib/tunnel-api.sh"

	appliance_dry_run=0
	appliance_force=0
	cf_api_token='test-token'

	CALL_LOG="$TEST_TMP/calls.log"
	export CALL_LOG

	# Default happy-path Cloudflare API stub. Individual tests
	# override cf_api again when they need different fixtures.
	cf_api() {
		printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CALL_LOG"
		case "$1 $2" in
			'GET /user/tokens/verify')
				printf '{"success":true,"result":{"status":"active"}}'
				;;
			'GET /accounts')
				printf '{"success":true,"result":[{"id":"acct-1"}]}'
				;;
			'GET /zones?name=claude.example.com')
				printf '{"success":true,"result":[]}'
				;;
			'GET /zones?name=example.com')
				printf '{"success":true,"result":[{"id":"zone-1","name":"example.com"}]}'
				;;
			'GET /zones/zone-1')
				printf '{"success":true,"result":{"id":"zone-1","name":"example.com","account":{"id":"acct-1"}}}'
				;;
			'GET /accounts/acct-1/cfd_tunnel?name=coworkstation-claude-example-com&is_deleted=false')
				printf '{"success":true,"result":[]}'
				;;
			'POST /accounts/acct-1/cfd_tunnel'*)
				printf '{"success":true,"result":{"id":"tun-1","token":"conn-token"}}'
				;;
			'GET /accounts/acct-1/cfd_tunnel/tun-1/token')
				printf '{"success":true,"result":"conn-token"}'
				;;
			'GET /accounts/acct-1/cfd_tunnel/tun-1/configurations')
				printf '{"success":true,"result":{"config":{"ingress":[]}}}'
				;;
			'PUT /accounts/acct-1/cfd_tunnel/tun-1/configurations'*)
				printf '{"success":true,"result":{}}'
				;;
			'GET /zones/zone-1/dns_records?type=CNAME&name='*)
				printf '{"success":true,"result":[]}'
				;;
			'POST /zones/zone-1/dns_records'*)
				printf '{"success":true,"result":{"id":"dns-1"}}'
				;;
			'GET /accounts/acct-1/access/apps')
				printf '{"success":true,"result":[]}'
				;;
			'POST /accounts/acct-1/access/apps'*)
				printf '{"success":true,"result":{"id":"app-1"}}'
				;;
			'GET /accounts/acct-1/access/apps/app-1/policies')
				printf '{"success":true,"result":[]}'
				;;
			'POST /accounts/acct-1/access/apps/app-1/policies'*)
				printf '{"success":true,"result":{"id":"pol-1"}}'
				;;
			*)
				printf '{"success":false,"errors":[{"message":"unstubbed: %s %s"}]}' \
					"$1" "$2"
				;;
		esac
	}
}

teardown() {
	if [[ -n $TEST_TMP && -d $TEST_TMP ]]; then
		rm -rf "$TEST_TMP"
	fi
}

# =============================================================================
# Pure JSON transforms
# =============================================================================

@test "ingress_json_add: inserts before catch-all, keeps others" {
	local out
	out=$(printf '[{"hostname":"a.example.com","service":"http://127.0.0.1:8443"},{"service":"http_status:404"}]' \
		| ingress_json_add b.example.com 8444)
	[[ $(jq -r '.[1].hostname' <<< "$out") == 'b.example.com' ]]
	[[ $(jq -r '.[1].service' <<< "$out") == 'http://127.0.0.1:8444' ]]
	[[ $(jq -r '.[2].service' <<< "$out") == 'http_status:404' ]]
	[[ $(jq 'length' <<< "$out") == '3' ]]
}

@test "ingress_json_add: idempotent for an existing hostname" {
	local once twice
	once=$(printf '[]' | ingress_json_add a.example.com 8443)
	twice=$(printf '%s' "$once" | ingress_json_add a.example.com 8443)
	[[ $once == "$twice" ]]
}

@test "ingress_json_remove: drops only the named hostname" {
	local conf out
	conf=$(printf '[]' | ingress_json_add a.example.com 8443 \
		| ingress_json_add b.example.com 8444)
	out=$(printf '%s' "$conf" | ingress_json_remove a.example.com)
	[[ $(jq -r '.[0].hostname' <<< "$out") == 'b.example.com' ]]
	[[ $out != *'a.example.com'* ]]
}

@test "access_include_json: emails and domains, trimmed" {
	local out
	out=$(access_include_json ' alice@example.com, example.com ')
	[[ $(jq -r '.[0].email.email' <<< "$out") == 'alice@example.com' ]]
	[[ $(jq -r '.[1].email_domain.domain' <<< "$out") == \
		'example.com' ]]
}

# =============================================================================
# API helpers against the stub
# =============================================================================

@test "cf_call: surfaces API errors and fails" {
	cf_api() {
		printf '{"success":false,"errors":[{"message":"nope"}]}'
	}
	run cf_call GET /anything
	[[ $status -ne 0 ]]
	[[ $output == *'nope'* ]]
}

@test "cf_zone_for_hostname: walks labels to the registered zone" {
	local out
	out=$(cf_zone_for_hostname claude.example.com)
	[[ $out == 'zone-1 example.com' ]]
}

@test "cf_zone_for_hostname: fails when no suffix is a zone" {
	cf_api() { printf '{"success":true,"result":[]}'; }
	run cf_zone_for_hostname claude.nozone.test
	[[ $status -ne 0 ]]
	[[ $output == *'no Cloudflare zone'* ]]
}

@test "cf_tunnel_ensure: creates when absent" {
	local id
	id=$(cf_tunnel_ensure acct-1 coworkstation-claude-example-com)
	[[ $id == 'tun-1' ]]
	grep -q 'POST /accounts/acct-1/cfd_tunnel' "$CALL_LOG"
}

@test "cf_tunnel_ensure: adopts an existing tunnel without POST" {
	cf_api() {
		printf '%s %s\n' "$1" "$2" >> "$CALL_LOG"
		printf '{"success":true,"result":[{"id":"tun-existing"}]}'
	}
	local id
	id=$(cf_tunnel_ensure acct-1 coworkstation-claude-example-com)
	[[ $id == 'tun-existing' ]]
	! grep -q '^POST' "$CALL_LOG"
}

@test "tunnel_api_load_token: rejects placeholder and short tokens" {
	printf 'YOUR-CF-API-TOKEN' > "$TEST_TMP/placeholder"
	run tunnel_api_load_token "$TEST_TMP/placeholder"
	[[ $status -ne 0 ]]
	[[ $output == *'README placeholder'* ]]
	printf 'shorty' > "$TEST_TMP/short"
	run tunnel_api_load_token "$TEST_TMP/short"
	[[ $status -ne 0 ]]
	[[ $output == *'~40'* ]]
}

@test "tunnel_api_load_token: rejects missing and empty files" {
	run tunnel_api_load_token "$TEST_TMP/absent"
	[[ $status -ne 0 ]]
	printf '  \n' > "$TEST_TMP/empty"
	run tunnel_api_load_token "$TEST_TMP/empty"
	[[ $status -ne 0 ]]
	[[ $output == *'empty'* ]]
}

@test "tunnel_api_load_token: fails on verification error" {
	printf 'bad-token-that-is-long-enough-to-verify\n' > "$TEST_TMP/token"
	cf_api() { printf '{"success":false,"errors":[{"message":"invalid"}]}'; }
	run tunnel_api_load_token "$TEST_TMP/token"
	[[ $status -ne 0 ]]
	[[ $output == *'verification'* ]]
}

# =============================================================================
# End-to-end provisioning against the stub
# =============================================================================

@test "tunnel_api_provision: full happy path writes tunnel.conf" {
	printf 'test-token-that-is-long-enough-yes\n' > "$TEST_TMP/token"
	export APPLIANCE_SYSTEMD_DIR="$TEST_TMP/systemd"
	mkdir -p "$APPLIANCE_SYSTEMD_DIR"
	run_cmd() { printf 'RUN: %s\n' "$*" >> "$CALL_LOG"; }
	command() {
		if [[ $1 == '-v' && $2 == 'systemctl' ]]; then
			return 1
		fi
		builtin command "$@"
	}
	run tunnel_api_provision claude.example.com 8443 \
		"$TEST_TMP/token" 'alice@example.com'
	[[ $status -eq 0 ]]
	[[ $output == *'zero-touch tunnel ready'* ]]

	local conf="$APPLIANCE_ETC/tunnel.conf"
	[[ -f $conf ]]
	grep -q '^mode=api$' "$conf"
	grep -q '^tunnel_id=tun-1$' "$conf"
	grep -q '^zone_name=example.com$' "$conf"
	grep -q '^access_allow=alice@example.com$' "$conf"
	# connector installed under OUR unit with the token in the env
	# file (never `cloudflared service install` / the distro unit)
	grep -q 'RUN: systemctl enable --now cws-cloudflared.service' \
		"$CALL_LOG"
	grep -q '^TUNNEL_TOKEN=conn-token$' "$APPLIANCE_ETC/tunnel-token"
	[[ $(stat -c %a "$APPLIANCE_ETC/tunnel-token") == 600 ]]
	grep -q 'EnvironmentFile=/etc/coworkstation/tunnel-token' \
		"$APPLIANCE_SYSTEMD_DIR/cws-cloudflared.service"
	# DNS + Access app + policy all created
	grep -q 'POST /zones/zone-1/dns_records' "$CALL_LOG"
	grep -q 'POST /accounts/acct-1/access/apps ' "$CALL_LOG" \
		|| grep -q 'POST /accounts/acct-1/access/apps{' "$CALL_LOG" \
		|| grep -qE 'POST /accounts/acct-1/access/apps [^/]' "$CALL_LOG"
	grep -q 'POST /accounts/acct-1/access/apps/app-1/policies' \
		"$CALL_LOG"
}

@test "tunnel_api_reroute: reconciles the hostname to the new port" {
	tunnel_conf_get() {
		case "$1" in
			token_file) printf '%s' "$TEST_TMP/token" ;;
			account_id) printf 'acct' ;;
			tunnel_id)  printf 'tun' ;;
		esac
	}
	tunnel_api_load_token() { return 0; }
	cf_tunnel_get_ingress() {
		printf '%s' '[{"hostname":"cws.example.com","service":"http://127.0.0.1:8443"},{"service":"http_status:404"}]'
	}
	cf_tunnel_put_ingress() { printf '%s' "$3" > "$TEST_TMP/put"; }
	run tunnel_api_reroute cws.example.com 8701
	[[ $status -eq 0 ]]
	# the plain hostname rule now points at the gateway port; catch-all intact
	[[ $(jq -r '.[] | select(.hostname=="cws.example.com") | .service' \
		"$TEST_TMP/put") == 'http://127.0.0.1:8701' ]]
	[[ $(jq -r '.[-1].service' "$TEST_TMP/put") == 'http_status:404' ]]
}

@test "tunnel_conf_get: reads keys and fails on absence" {
	printf 'mode=api\ntunnel_id=tun-9\n' > "$APPLIANCE_ETC/tunnel.conf"
	[[ $(tunnel_conf_get mode) == 'api' ]]
	[[ $(tunnel_conf_get tunnel_id) == 'tun-9' ]]
	run tunnel_conf_get nonexistent
	[[ $status -ne 0 ]]
}

# =============================================================================
# CLI validation (setup.sh)
# =============================================================================

@test "setup: api token without --access-allow is refused" {
	run bash "$SCRIPT_DIR/../setup.sh" \
		--cf-api-token-file "$TEST_TMP/token" \
		--hostname claude.example.com --user nobody --dry-run
	[[ $status -ne 0 ]]
	[[ $output == *'--access-allow'* ]]
}

@test "setup: api token without --hostname is refused" {
	run bash "$SCRIPT_DIR/../setup.sh" \
		--cf-api-token-file "$TEST_TMP/token" \
		--access-allow alice@example.com --user nobody --dry-run
	[[ $status -ne 0 ]]
	[[ $output == *'--hostname'* ]]
}

# =============================================================================
# member.sh api-mode dispatch
# =============================================================================

@test "member add: api mode routes to the API, not the local file" {
	# shellcheck source=member.sh
	source "$SCRIPT_DIR/../member.sh"
	printf 'profile=kasmvnc\nhostname=claude.example.com\n' \
		> "$APPLIANCE_ETC/appliance.conf"
	printf 'mode=api\ntunnel_id=tun-1\n' > "$APPLIANCE_ETC/tunnel.conf"
	id() {
		if [[ $1 == '-u' ]]; then printf '1042'; return 0; fi
		return 1
	}
	getent() {
		printf 'x:x:1042:1042::%s/home:/bin/bash\n' "$TEST_TMP"
	}
	mkdir -p "$TEST_TMP/home"
	chown() { return 0; }
	appliance_dry_run=1
	run cmd_add alice 6G 200%
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: api ingress+dns+access for alice.claude.example.com'* ]]
	[[ $output != *'rewrite'* ]]
}

@test "member add: --allow is validated before any account changes" {
	# shellcheck source=member.sh
	source "$SCRIPT_DIR/../member.sh"
	useradd() { printf 'USERADD RAN\n'; }
	run cmd_add alice 6G 200% 'not-an-email-or-domain'
	[[ $status -ne 0 ]]
	[[ $output != *'USERADD RAN'* ]]
}

# =============================================================================
# Dry-run network guard + interactive wizard
# =============================================================================

@test "tunnel_api_provision: dry-run prints a plan, never calls the API" {
	appliance_dry_run=1
	cf_api() { printf 'CALLED\n' >> "$CALL_LOG"; }
	run tunnel_api_provision claude.example.com 8443 \
		"$TEST_TMP/token" 'alice@example.com'
	[[ $status -eq 0 ]]
	[[ $output == *'DRY-RUN: cloudflare api provisioning plan'* ]]
	[[ $output == *'claude.example.com -> http://127.0.0.1:8443'* ]]
	[[ ! -f $CALL_LOG ]] || ! grep -q 'CALLED' "$CALL_LOG"
}

@test "setup wizard: prompts fill missing flags on a TTY" {
	run bash -c 'printf "\n" | APPLIANCE_ASSUME_TTY=1 \
		bash "'"$SCRIPT_DIR"'/../setup.sh" \
		--user ghost --dry-run 2>&1'
	[[ $status -ne 0 ]]
	[[ $output == *'Public hostname'* ]]
	[[ $output == *"user 'ghost' does not exist"* ]]
}

@test "setup wizard: silent without a TTY (cloud-init/CI safe)" {
	run bash -c 'printf "" | \
		bash "'"$SCRIPT_DIR"'/../setup.sh" \
		--user ghost --dry-run 2>&1'
	[[ $status -ne 0 ]]
	[[ $output != *'Public hostname'* ]]
}

@test "setup wizard: token answer cascades to access-allow prompt" {
	printf 'tok\n' > "$TEST_TMP/tokfile"
	run bash -c 'printf "claude.example.com\n%s\n\n" \
		"'"$TEST_TMP"'/tokfile" | APPLIANCE_ASSUME_TTY=1 \
		bash "'"$SCRIPT_DIR"'/../setup.sh" \
		--user ghost --dry-run 2>&1'
	[[ $status -ne 0 ]]
	[[ $output == *'Cloudflare API token file'* ]]
	[[ $output == *'Access allow list'* ]]
	# blank allow answer + token set => api-mode validation fires
	[[ $output == *'--access-allow'* ]]
}

# =============================================================================
# Reconcile-on-rerun (changed port / changed allow list)
# =============================================================================

@test "ingress_json_add: updates the service when a port changes" {
	local out
	out=$(printf '[{"hostname":"a.example.com","service":"http://127.0.0.1:8444"},{"service":"http_status:404"}]' \
		| ingress_json_add a.example.com 8445)
	[[ $(jq -r '.[0].service' <<< "$out") == 'http://127.0.0.1:8445' ]]
	[[ $(jq 'length' <<< "$out") == '2' ]]
}

@test "cf_access_ensure_app: updates a policy whose include drifted" {
	cf_api() {
		printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CALL_LOG"
		case "$1 $2" in
			'GET /accounts/acct-1/access/apps')
				printf '{"success":true,"result":[{"id":"app-1","domain":"cws.example.com"}]}'
				;;
			'GET /accounts/acct-1/access/apps/app-1/policies')
				printf '{"success":true,"result":[{"id":"pol-1","include":[{"email":{"email":"old@example.com"}}]}]}'
				;;
			'PUT /accounts/acct-1/access/apps/app-1/policies/pol-1'*)
				printf '{"success":true,"result":{"id":"pol-1"}}'
				;;
			*) printf '{"success":true,"result":[]}' ;;
		esac
	}
	run cf_access_ensure_app acct-1 cws.example.com 'new@example.com'
	[[ $status -eq 0 ]]
	[[ $output == *'updated allow policy'* ]]
	grep -q 'PUT /accounts/acct-1/access/apps/app-1/policies/pol-1' \
		"$CALL_LOG"
}

@test "cf_access_ensure_app: matching include is left untouched" {
	cf_api() {
		printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$CALL_LOG"
		case "$1 $2" in
			'GET /accounts/acct-1/access/apps')
				printf '{"success":true,"result":[{"id":"app-1","domain":"cws.example.com"}]}'
				;;
			'GET /accounts/acct-1/access/apps/app-1/policies')
				printf '{"success":true,"result":[{"id":"pol-1","include":[{"email":{"email":"same@example.com"}}]}]}'
				;;
			*) printf '{"success":true,"result":[]}' ;;
		esac
	}
	run cf_access_ensure_app acct-1 cws.example.com 'same@example.com'
	[[ $status -eq 0 ]]
	! grep -qE '^(PUT|POST) .*policies' "$CALL_LOG"
}

# =============================================================================
# validate_access_allow (pre-provisioning gate, pure bash)
# =============================================================================

@test "validate_access_allow: accepts emails and org domains" {
	validate_access_allow 'alice@example.com'
	validate_access_allow ' alice@example.com , example.com '
	validate_access_allow 'corp.example.co.uk'
}

@test "validate_access_allow: rejects a PUBLIC mail provider domain" {
	run validate_access_allow 'gmail.com'
	[[ $status -ne 0 ]]
	[[ $output == *'PUBLIC mail provider'* ]]
	# ...but a specific address AT that provider is fine
	validate_access_allow 'someone@gmail.com'
}

@test "validate_access_allow: rejects malformed and empty input" {
	run validate_access_allow 'not an email'
	[[ $status -ne 0 ]]
	run validate_access_allow '@nope.com'
	[[ $status -ne 0 ]]
	run validate_access_allow ' , ,, '
	[[ $status -ne 0 ]]
	[[ $output == *'no usable entries'* ]]
}
