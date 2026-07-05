#!/usr/bin/env bash
#===============================================================================
# Coworkstation network installer
#
# Downloads Coworkstation to /opt/coworkstation and runs setup.sh. This is
# the prod entry point — the equivalent of a "download and run" for a
# script-based orchestrator (Coworkstation installs the Claude Desktop
# engine; it is not itself a binary app).
#
# Usage (defaults to the latest release, falls back to main):
#   curl -fsSL https://raw.githubusercontent.com/jongodb/coworkstation/main/install.sh | sudo bash
#
# Pass setup.sh flags through after `-s --`:
#   curl -fsSL .../install.sh | sudo bash -s -- \
#       --hostname cws.example.com --cf-api-token-file /root/cf-token \
#       --access-allow you@example.com
#
# Override the source ref/dir with env vars:
#   COWORKSTATION_REF=v0.1.0  COWORKSTATION_DIR=/opt/coworkstation
#===============================================================================

set -u

repo='jongodb/coworkstation'
ref="${COWORKSTATION_REF:-main}"
dir="${COWORKSTATION_DIR:-/opt/coworkstation}"
pin_sha="${COWORKSTATION_SHA:-}"

log() { printf '[coworkstation-install] %s\n' "$*"; }
die() { printf '[coworkstation-install] ERROR: %s\n' "$*" >&2; exit 1; }

# $dir is rm -rf'd below; refuse values that could nuke the system if a
# stray COWORKSTATION_DIR leaks in from the environment. Checked before
# the root gate so the most dangerous misconfiguration fails first.
case "$dir" in
	/|/bin|/boot|/dev|/etc|/home|/lib|/proc|/root|/run|/sbin|/srv|\
	/sys|/tmp|/usr|/var|'')
		die "refusing to install into '$dir'"
		;;
	/*) ;;
	*)
		die "COWORKSTATION_DIR must be an absolute path (got '$dir')"
		;;
esac

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
	die 'run as root (pipe into: sudo bash)'
fi

for tool in curl tar; do
	command -v "$tool" > /dev/null 2>&1 || die "missing dependency: $tool"
done

# Prefer git when available (keeps the tree updatable); else tarball.
if command -v git > /dev/null 2>&1; then
	if [[ -d $dir/.git ]]; then
		log "updating existing checkout in $dir"
		git -C "$dir" fetch --depth 1 origin "$ref" \
			|| die 'git fetch failed'
		git -C "$dir" checkout -q FETCH_HEAD || die 'git checkout failed'
	else
		log "cloning $repo@$ref into $dir"
		rm -rf "$dir"
		# Clone the requested ref explicitly. Do NOT fall back to the
		# default branch on failure: a moved/deleted tag or a transient
		# error must surface, not silently downgrade a pin to whatever
		# `main` currently is (that would be an unattended code swap).
		git clone --depth 1 --branch "$ref" \
			"https://github.com/$repo" "$dir" \
			|| die "git clone of ref '$ref' failed"
	fi
else
	log "downloading $repo@$ref tarball into $dir (git not found)"
	rm -rf "$dir"; mkdir -p "$dir"
	curl -fsSL "https://github.com/$repo/archive/$ref.tar.gz" \
		| tar xz -C "$dir" --strip-components=1 \
		|| die 'tarball download/extract failed'
fi

# Supply-chain pin: with COWORKSTATION_SHA set, the checked-out commit
# must match exactly — a moved tag or tampered branch fails loudly
# instead of running whatever arrived. (Tarball path can't verify.)
if [[ -n $pin_sha ]]; then
	if [[ ! -d $dir/.git ]]; then
		die 'COWORKSTATION_SHA requires git (tarball cannot verify)'
	fi
	got=$(git -C "$dir" rev-parse HEAD) || die 'rev-parse failed'
	if [[ $got != "$pin_sha" ]]; then
		die "checkout is $got, expected $pin_sha — refusing to run"
	fi
	log "verified checkout matches pinned SHA"
fi

if [[ ! -f $dir/setup.sh ]]; then
	die "download looks wrong: $dir/setup.sh is missing"
fi
chmod +x "$dir"/*.sh "$dir"/cws "$dir"/testbench/*.sh 2> /dev/null || true
ln -sf "$dir/cws" /usr/local/bin/cws
log "cws CLI installed (run 'cws' any time for the interactive menu)"

log "running setup.sh"
exec "$dir/setup.sh" "$@"
