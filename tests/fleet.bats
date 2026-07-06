#!/usr/bin/env bats
#
# fleet.bats
# Read-only fleet reporting (lib/fleet.sh): usage scan over Claude
# Code JSONL logs (dedup, malformed lines, empty state) and the
# sessions table plumbing.
#

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"

setup() {
	TEST_TMP=$(mktemp -d)
	export TEST_TMP
	export APPLIANCE_ETC="$TEST_TMP/etc"
	mkdir -p "$APPLIANCE_ETC"
	# shellcheck source=lib/common.sh
	source "$SCRIPT_DIR/../lib/common.sh"
	# shellcheck source=lib/fleet.sh
	source "$SCRIPT_DIR/../lib/fleet.sh"
	appliance_etc="$APPLIANCE_ETC"
}

teardown() {
	[[ -n $TEST_TMP && -d $TEST_TMP ]] && rm -rf "$TEST_TMP"
}

make_jsonl_home() {
	local home="$TEST_TMP/home"
	mkdir -p "$home/.claude/projects/p1"
	cat > "$home/.claude/projects/p1/s1.jsonl" << 'EOF'
{"type":"assistant","requestId":"r1","timestamp":"2026-07-01T10:00:00Z","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":5,"cache_creation_input_tokens":7}}}
{"type":"user","timestamp":"2026-07-01T10:00:01Z"}
not json at all
{"type":"assistant","requestId":"r1","timestamp":"2026-07-01T10:00:02Z","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":20}}}
{"type":"assistant","requestId":"r2","timestamp":"2026-07-02T09:00:00Z","message":{"id":"m2","usage":{"input_tokens":50,"output_tokens":10,"cache_read_input_tokens":1}}}
EOF
	printf '%s' "$home"
}

@test "fleet_usage_scan: sums, dedups by requestId, survives junk" {
	local home
	home=$(make_jsonl_home)
	user_home() { printf '%s' "$TEST_TMP/home"; }
	run fleet_usage_scan alice
	[[ $status -eq 0 ]]
	# 2 unique requests: 100+50 in, 20+10 out, 5+1 cache-read, 7 write
	[[ $output == $'2\t150\t30\t6\t7\t2026-07-02T09:00:00Z' ]]
}

@test "fleet_usage_scan: no logs at all is a zero row, not an error" {
	mkdir -p "$TEST_TMP/home2"
	user_home() { printf '%s' "$TEST_TMP/home2"; }
	run fleet_usage_scan bob
	[[ $status -eq 0 ]]
	[[ $output == $'0\t0\t0\t0\t0\t-' ]]
}

@test "fleet_usage: table with header, warns on unknown user" {
	local home
	home=$(make_jsonl_home)
	user_home() { printf '%s' "$TEST_TMP/home"; }
	id() { [[ $1 == alice ]]; }
	run fleet_usage alice ghost
	[[ $status -eq 0 ]]
	[[ ${lines[0]} == USER*MSGS*INPUT* ]]
	[[ $output == *alice*150* ]]
	[[ $output == *'no such user: ghost'* ]]
	[[ $output != *ghost$'\t'* ]]
}

@test "fleet_user_port: registry row wins, control user gets base" {
	printf 'alice\t2\t8444\t4G\t200%%\n' > "$APPLIANCE_ETC/members.tsv"
	appliance_kasm_base_port=8443
	[[ $(fleet_user_port alice) == 8444 ]]
	[[ $(fleet_user_port cowork) == 8443 ]]
}

@test "fleet_sessions: reports active state, clients and header" {
	fleet_users() { printf 'alice\n'; }
	user_systemctl() {
		case "$2" in
			is-active) printf 'active\n' ;;
			show) printf '2026-07-05 10:00:00 UTC\n' ;;
		esac
	}
	fleet_port_clients() { printf '3'; }
	run fleet_sessions
	[[ $status -eq 0 ]]
	[[ ${lines[0]} == USER*DESKTOP*CLIENTS*SINCE ]]
	[[ ${lines[1]} == alice*active*3*'2026-07-05 10:00:00 UTC' ]]
}

@test "fleet_sessions: inactive desktop shows dash for since" {
	fleet_users() { printf 'bob\n'; }
	user_systemctl() { return 3; }
	fleet_port_clients() { printf '0'; }
	run fleet_sessions
	[[ $status -eq 0 ]]
	[[ ${lines[1]} == bob*inactive*0*- ]]
}

@test "cws: sessions, usage and audit dispatch through the CLI" {
	run "$SCRIPT_DIR/../cws" help
	[[ $status -eq 0 ]]
	[[ $output == *'cws sessions'* ]]
	[[ $output == *'cws usage [USER...]'* ]]
	[[ $output == *'cws audit'* ]]
}

@test "fleet_devices: renders the bridge device registry per user" {
	fleet_users() { printf 'alice\n'; }
	local home="$TEST_TMP/homed"
	mkdir -p "$home/.config/cws-bridge"
	cat > "$home/.config/cws-bridge/devices.json" << 'EOF'
{"0a1b2c3d-e5f6":{"identity":"alice@corp.com","lastSeen":1751709600000,
 "hits":42,"ua":"Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X)"}}
EOF
	user_home() { printf '%s' "$TEST_TMP/homed"; }
	run fleet_devices
	[[ $status -eq 0 ]]
	[[ ${lines[0]} == USER*DEVICE*IDENTITY*LAST_SEEN*HITS*AGENT ]]
	[[ ${lines[1]} == alice*0a1b2c3d*alice@corp.com*42*'Mozilla/5.0 (iPad'* ]]
}

@test "fleet_devices: empty registry says so instead of a bare header" {
	fleet_users() { printf 'bob\n'; }
	user_home() { printf '%s' "$TEST_TMP/nothere"; }
	run fleet_devices
	[[ $status -eq 0 ]]
	[[ ${#lines[@]} -eq 2 ]]
	[[ ${lines[1]} == '(none yet)'* ]]
}

@test "fleet_audit_record: appends actor+action, keeps 0600" {
	SUDO_USER=admin fleet_audit_record session-stop alice
	local f="$APPLIANCE_ETC/audit.log"
	[[ -f $f ]]
	[[ $(stat -c %a "$f") == 600 ]]
	run cat "$f"
	[[ $output == *$'\tadmin\tsession-stop\talice' ]]
}

@test "fleet_session_ctl: runs systemctl, records, validates input" {
	local home="$TEST_TMP/homec"
	mkdir -p "$home/.config/systemd/user"
	: > "$home/.config/systemd/user/kasmvnc.service"
	user_home() { printf '%s' "$TEST_TMP/homec"; }
	local called="$TEST_TMP/called"
	user_systemctl() { printf '%s %s %s\n' "$1" "$2" "$3" > "$called"; }
	run fleet_session_ctl restart alice
	[[ $status -eq 0 ]]
	[[ $(cat "$called") == 'alice restart kasmvnc.service' ]]
	grep -q $'session-restart\talice' "$APPLIANCE_ETC/audit.log"
	run fleet_session_ctl explode alice
	[[ $status -ne 0 ]]
	[[ $output == *'unknown session action'* ]]
	run fleet_session_ctl stop ''
	[[ $status -ne 0 ]]
}

@test "fleet_session_ctl: refuses a user with no provisioned session" {
	mkdir -p "$TEST_TMP/plain"
	user_home() { printf '%s' "$TEST_TMP/plain"; }
	run fleet_session_ctl stop bob
	[[ $status -ne 0 ]]
	[[ $output == *'no session provisioned'* ]]
}

@test "fleet_reclaim: off by default, says how to enable" {
	run fleet_reclaim
	[[ $status -eq 0 ]]
	[[ $output == *'idle reclaim is off'* ]]
}

@test "fleet_reclaim: stops only cold sessions, records, spares live" {
	printf 'idle_hours=2\n' > "$APPLIANCE_ETC/reclaim.conf"
	fleet_users() { printf 'cold\ncold2\nfresh\n'; }
	user_systemctl() {
		if [[ $2 == 'is-active' ]]; then printf 'active\n'; return 0; fi
		printf '%s %s\n' "$1" "$2" >> "$TEST_TMP/stopped"
	}
	fleet_user_port() { printf '8443'; }
	fleet_port_clients() { printf '0'; }
	fleet_last_activity() {
		case "$1" in
			fresh) date +%s ;;
			*) printf '1' ;;
		esac
	}
	run fleet_reclaim
	[[ $status -eq 0 ]]
	[[ $output == *'reclaimed: cold'* ]]
	[[ $output == *'reclaimed: cold2'* ]]
	[[ $output != *'reclaimed: fresh'* ]]
	grep -q 'cold stop' "$TEST_TMP/stopped"
	grep -q $'session-reclaim\tcold' "$APPLIANCE_ETC/audit.log"
}

@test "fleet_reclaim: live connections spare an idle-looking session" {
	printf 'idle_hours=2\n' > "$APPLIANCE_ETC/reclaim.conf"
	fleet_users() { printf 'busy\n'; }
	user_systemctl() {
		if [[ $2 == 'is-active' ]]; then printf 'active\n'; return 0; fi
		printf 'STOPPED\n' >> "$TEST_TMP/stopped2"
	}
	fleet_user_port() { printf '8443'; }
	fleet_port_clients() { printf '2'; }
	fleet_last_activity() { printf '1'; }
	run fleet_reclaim
	[[ $status -eq 0 ]]
	[[ ! -f $TEST_TMP/stopped2 ]]
}

@test "fleet_reclaim: dry-run reports and touches nothing" {
	printf 'idle_hours=2\n' > "$APPLIANCE_ETC/reclaim.conf"
	fleet_users() { printf 'cold\n'; }
	user_systemctl() {
		if [[ $2 == 'is-active' ]]; then printf 'active\n'; return 0; fi
		printf 'STOPPED\n' >> "$TEST_TMP/stopped3"
	}
	fleet_user_port() { printf '8443'; }
	fleet_port_clients() { printf '0'; }
	fleet_last_activity() { printf '1'; }
	run fleet_reclaim dry-run
	[[ $status -eq 0 ]]
	[[ $output == *'would reclaim: cold'* ]]
	[[ ! -f $TEST_TMP/stopped3 ]]
}

@test "fleet_reclaim: per-member idle_hours override wins" {
	printf 'idle_hours=0\nidle_hours.night=1\n' \
		> "$APPLIANCE_ETC/reclaim.conf"
	[[ $(fleet_reclaim_idle_hours) == 0 ]]
	[[ $(fleet_reclaim_idle_hours night) == 1 ]]
	[[ $(fleet_reclaim_idle_hours other) == 0 ]]
	fleet_users() { printf 'night\nother\n'; }
	user_systemctl() {
		if [[ $2 == 'is-active' ]]; then printf 'active\n'; return 0; fi
		printf '%s\n' "$1" >> "$TEST_TMP/stopped4"
	}
	fleet_user_port() { printf '8443'; }
	fleet_port_clients() { printf '0'; }
	fleet_last_activity() { printf '1'; }
	run fleet_reclaim
	[[ $status -eq 0 ]]
	[[ $output == *'reclaimed: night'* ]]
	[[ $output != *'reclaimed: other'* ]]
	[[ $(cat "$TEST_TMP/stopped4") == 'night' ]]
}

@test "fleet_sessions: stopped + long-idle shows DORMANT" {
	printf 'dormant_days=30\n' > "$APPLIANCE_ETC/reclaim.conf"
	fleet_users() { printf 'ghost\n'; }
	user_systemctl() { return 3; }
	fleet_port_clients() { printf '0'; }
	fleet_last_activity() { printf '1'; }
	run fleet_sessions
	[[ $status -eq 0 ]]
	[[ ${lines[1]} == ghost*DORMANT* ]]
}

@test "fleet_reclaim units: oneshot service + hourly persistent timer" {
	local svc timer
	svc=$(fleet_reclaim_service_unit)
	timer=$(fleet_reclaim_timer_unit)
	[[ $svc == *'Type=oneshot'* ]]
	[[ $svc == *'/usr/local/bin/cws reclaim'* ]]
	[[ $timer == *'OnCalendar=hourly'* ]]
	[[ $timer == *'Persistent=true'* ]]
	[[ $timer == *'WantedBy=timers.target'* ]]
}

@test "fleet_audit_access: manual mode points at the dashboard" {
	tunnel_conf_get() { printf 'manual'; }
	run fleet_audit_access 5
	[[ $status -eq 0 ]]
	[[ $output == *'Cloudflare dashboard'* ]]
}

@test "fleet_audit_access: fetch failure prints the permission hint" {
	tunnel_conf_get() {
		case "$1" in
			mode) printf 'api' ;;
			token_file) printf '/dev/null' ;;
			account_id) printf 'acc1' ;;
		esac
	}
	tunnel_api_load_token() { return 0; }
	cf_call() { return 1; }
	run fleet_audit_access 5
	[[ $status -ne 0 ]]
	[[ $output == *'Audit Logs'* ]]
	[[ $output != *IDENTITY* ]]
}

@test "fleet_sessions: extra sessions from the registry are listed" {
	printf 'alice\t50\t8492\ta-s50.x\n' > "$APPLIANCE_ETC/sessions.tsv"
	fleet_users() { printf 'alice\n'; }
	user_systemctl() {
		if [[ $2 == 'is-active' ]]; then printf 'active\n'; return 0; fi
		printf 'now\n'
	}
	fleet_port_clients() { printf '1'; }
	run fleet_sessions
	[[ $status -eq 0 ]]
	[[ $output == *alice:s50*active* ]]
}

@test "tunnel_api_child_hostname: flattens below the zone, dots at apex" {
	# shellcheck source=lib/tunnel-api.sh
	source "$SCRIPT_DIR/../lib/tunnel-api.sh"
	tunnel_conf_get() { printf 'example.com'; }
	[[ $(tunnel_api_child_hostname bob cws.example.com) == 'bob-cws.example.com' ]]
	[[ $(tunnel_api_child_hostname bob example.com) == 'bob.example.com' ]]
	tunnel_conf_get() { return 1; }
	[[ $(tunnel_api_child_hostname bob cws.example.com) == 'bob.cws.example.com' ]]
}

@test "fleet_audit_access: api mode renders the log rows" {
	tunnel_conf_get() {
		case "$1" in
			mode) printf 'api' ;;
			token_file) printf '/dev/null' ;;
			account_id) printf 'acc1' ;;
		esac
	}
	tunnel_api_load_token() { return 0; }
	# real cf_call emits the UNWRAPPED .result — mocking the envelope
	# here once hid a live bug (empty table with the header)
	cf_call() {
		printf '%s' '[{"created_at":"2026-07-05T10:00:00Z","user_email":"a@b.co","app_domain":"cws.example.com","allowed":true,"ip_address":"1.2.3.4"}]'
	}
	run fleet_audit_access 5
	[[ $status -eq 0 ]]
	[[ ${lines[0]} == TIME*IDENTITY*HOSTNAME*RESULT*FROM ]]
	[[ ${lines[1]} == *$'a@b.co\tcws.example.com\tallowed\t1.2.3.4' ]]
}

@test "tunnel_api_member_add: --allow override replaces the box list" {
	# shellcheck source=lib/tunnel-api.sh
	source "$SCRIPT_DIR/../lib/tunnel-api.sh"
	tunnel_conf_get() {
		case "$1" in
			token_file) printf '/dev/null' ;;
			account_id) printf 'acc1' ;;
			tunnel_id) printf 'tun1' ;;
			zone_id) printf 'z1' ;;
			access_allow) printf 'everyone@corp.com' ;;
		esac
	}
	tunnel_api_load_token() { return 0; }
	cf_tunnel_get_ingress() { printf '[]'; }
	ingress_json_add() { printf '[]'; }
	cf_tunnel_put_ingress() { return 0; }
	cf_dns_ensure_cname() { return 0; }
	local seen="$TEST_TMP/allow"
	cf_access_ensure_app() { printf '%s' "$3" > "$seen"; }
	tunnel_api_member_add m.cws.example.com 8444 'alice@corp.com'
	[[ $(cat "$seen") == 'alice@corp.com' ]]
	tunnel_api_member_add m.cws.example.com 8444
	[[ $(cat "$seen") == 'everyone@corp.com' ]]
}
