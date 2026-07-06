# shellcheck shell=bash
#===============================================================================
# Backup — encrypted whole-workstation backup via restic (ADR-009)
#
# The self-hoster's table-stakes feature: every session home,
# encrypted client-side by restic, to any target restic speaks —
# a local disk, SFTP, S3, or an rclone remote (we already ship
# rclone for cloud drives, so `rclone:remote:bucket` reuses that
# auth). Restore stays a documented restic command rather than a
# wrapper: a restore tool you got wrong is worse than none.
#
#   cws backup setup REPO     init the repo + generate the key
#   cws backup run [USER...]  snapshot session homes (default: all)
#   cws backup list           snapshots in the repo
#
# Config: $APPLIANCE_ETC/backup.conf (repo=...), key file 0600 at
# $APPLIANCE_ETC/backup.key — LOSING THE KEY LOSES THE BACKUPS;
# setup says so loudly. Runs are recorded in the ops log.
#
# Sourced by cws (with lib/common.sh and lib/fleet.sh).
#===============================================================================

backup_conf_file() {
	printf '%s/backup.conf' "${appliance_etc:-/etc/coworkstation}"
}

backup_key_file() {
	printf '%s/backup.key' "${appliance_etc:-/etc/coworkstation}"
}

backup_repo() {
	local conf
	conf=$(backup_conf_file)
	[[ -r $conf ]] || return 1
	local repo
	repo=$(grep -m1 '^repo=' "$conf" | cut -d= -f2-)
	[[ -n $repo ]] || return 1
	printf '%s' "$repo"
}

backup_install_packages() {
	if command -v restic > /dev/null 2>&1; then
		return 0
	fi
	# no-recommends: plain pkg_install drags in doc fonts and sphinx
	# themes (~38 MB) for a single binary — seen live.
	run_cmd env DEBIAN_FRONTEND=noninteractive \
		apt-get install -y --no-install-recommends restic
}

# restic with the repo + key wired in. Args pass through.
backup_restic() {
	local repo
	repo=$(backup_repo) || {
		log_err 'no backup repo configured; run: cws backup setup REPO'
		return 1
	}
	RESTIC_REPOSITORY="$repo" \
		RESTIC_PASSWORD_FILE="$(backup_key_file)" \
		restic "$@"
}

# One-time: record the repo, mint the key, init the repository.
backup_setup() {
	local repo="$1"
	if [[ -z $repo ]]; then
		log_err 'usage: cws backup setup REPO'
		log_err '  e.g. /backup/cws, sftp:user@host:/backup,'
		log_err '       rclone:gdrive:cws-backup'
		return 1
	fi
	backup_install_packages || return 1
	local key
	key=$(backup_key_file)
	if [[ ! -f $key ]]; then
		head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > "$key" \
			|| return 1
		chmod 600 "$key"
	fi
	printf 'repo=%s\n' "$repo" \
		| appliance_force=1 write_file "$(backup_conf_file)" 600 \
		|| return 1
	backup_restic init || {
		log_err 'restic init failed (already initialized is fine:' \
			're-run cws backup run)'
		return 1
	}
	log_info "backup repo ready: $repo"
	log_warn "COPY $key SOMEWHERE SAFE OFF THIS BOX —" \
		'losing it loses every backup'
}

# Snapshot session homes. $@ = users (default: every session account).
backup_run() {
	local -a users=("$@")
	if [[ ${#users[@]} -eq 0 ]]; then
		mapfile -t users < <(fleet_users)
	fi
	if [[ ${#users[@]} -eq 0 ]]; then
		log_warn 'no session accounts found; nothing to back up'
		return 0
	fi
	local -a paths=()
	local user home
	for user in "${users[@]}"; do
		home=$(user_home "$user" 2> /dev/null) || {
			log_warn "no such user: $user"
			continue
		}
		[[ -d $home ]] && paths+=("$home")
	done
	if [[ ${#paths[@]} -eq 0 ]]; then
		log_err 'no home directories to back up'
		return 1
	fi
	backup_restic backup \
		--exclude '*/.cache' \
		--exclude '*/.vnc/*.log' \
		--exclude '*/ClientSync/.stversions' \
		--tag coworkstation \
		"${paths[@]}" || return 1
	fleet_audit_record 'backup-run' "${users[*]}"
	log_info "backed up: ${paths[*]}"
	log_info 'restore (files land under TARGET with full paths):'
	log_info "  sudo cws backup restic restore latest --target /tmp/restore"
}

backup_list() {
	backup_restic snapshots --tag coworkstation
}
