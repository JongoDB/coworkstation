[< Back to README](../README.md)

# Cowork appliance — admin runbook

Operational procedures for a running appliance: provision, members, edge, distribution, backup, and recovery. Design: [design.md](design.md); phase specs: [phases.md](phases.md).

```bash
# Dev bootstrap — clone and run; the wizard prompts for anything
# missing (hostname, API token file, Access allow list):
git clone https://github.com/JongoDB/coworkstation
sudo claude-desktop-debian/appliance/setup.sh

# The three commands you will use after that:
sudo appliance/member.sh add alice                      # add a member
appliance/setup.sh doctor                               # health check
appliance/gen-sshconfigs.sh --host claude.example.com --per-member
```

## Initial provision

### Zero-touch (recommended)

One command from a bare OS, given a scoped Cloudflare API token
(Account > Cloudflare Tunnel:Edit, Account > Access: Apps and
Policies:Edit, Zone > DNS:Edit — create it at dash.cloudflare.com >
My Profile > API Tokens):

```bash
printf '%s' 'YOUR-API-TOKEN' > /root/cf-token && chmod 600 /root/cf-token
sudo appliance/setup.sh --hostname claude.example.com \
	--cf-api-token-file /root/cf-token \
	--access-allow 'you@example.com'
```

That provisions everything: engine, session stack, kasmVNC, the
remotely-managed tunnel, the proxied DNS record, **and the Access
application with an allow policy** for the emails/domains in
`--access-allow` (required — a tunneled hostname without an Access
app is public). Then: open `https://claude.example.com`, pass the
Access login, sign into Claude, run `appliance/setup.sh doctor`.

### Manual tunnel (no API token)

1. Fresh Debian 12+/Ubuntu 24.04+ box (x86_64 or arm64), DNS name
   picked (e.g. `claude.example.com`), Cloudflare zone for it.
2. `sudo appliance/setup.sh --hostname claude.example.com`
   - engine auto-selection: official apt build where `/dev/kvm`
     exists; this repo's build with the bwrap Cowork backend where it
     doesn't. Force with `--engine`. The decision is recorded in
     `/etc/claude-appliance/engine.conf`.
   - add `--dry-run` first if you want to review the full plan.
3. Finish the tunnel (interactive, one time):
   ```bash
   cloudflared tunnel login
   cloudflared tunnel create claude-appliance
   # set "tunnel:" + "credentials-file:" in /etc/cloudflared/config.yml
   cloudflared tunnel route dns claude-appliance claude.example.com
   cloudflared service install && systemctl start cloudflared
   ```
4. In Cloudflare Zero Trust, create an **Access application** for the
   hostname with your IdP (SSO/MFA) policy. No port forwarding, no
   public binds — the doctor fails loudly if it ever finds one.
5. Log into the session once (browser → the hostname), sign into
   Claude, let the keyring initialize. Run
   `appliance/setup.sh doctor` and get to zero FAILs.

Test environments for validating all of this (VPS → mini PC → Pi 5)
are specified in
[phases.md](phases.md#test-environments).

## Member lifecycle

```bash
sudo appliance/member.sh add alice --quota-mem 6G --quota-cpu 200%
sudo appliance/member.sh remove bob --keep-home
appliance/member.sh list
```

`add` creates the account, systemd slice quota, kasmVNC session on
its own display/port, ingress hostname (`alice.claude.example.com`),
and autostart. In **zero-touch (api) mode** the member's DNS record
and Access application are created automatically too, leaving one
manual follow-up; in manual mode there are two:

1. **Access policy** for the new hostname (manual mode only).
2. **First login** by the member: sign into their own Claude account;
   the keyring unlocks via PAM at session login from then on.

Sizing guidance: ~1–2 GB per active Cowork member on bwrap, ~4 GB on
KVM, plus the Electron sessions. Watch `systemd-cgtop` — quotas are
slices, so a noisy member throttles before starving the box.

## Cloud storage (keep project data off the appliance disk)

```bash
sudo appliance/storage.sh add --user alice --provider gdrive --name drive
```

The wizard tells the member to run `rclone authorize "drive"` on
their laptop and paste the token. Their Drive then appears at
`~/CloudDrives/drive` with a bounded local cache (default 10G,
`--cache-max` to change); Cowork/Code project folders are selected
inside it, exactly like pointing macOS Cowork at a synced Drive
folder. `storage.sh list --user alice` shows remotes and mount
health; `remove` detaches without touching provider data.

## Test bench

```bash
sudo appliance/testbench/setup.sh --user alice
```

Registers the `desktop-control` (nested-display GUI control) and
`vm-bench` (experimental QEMU targets) MCP servers in the member's
`claude_desktop_config.json`, merge-safe. For web/Electron work the
deterministic route is Playwright MCP:
`claude mcp add playwright -- npx @playwright/mcp@latest`.

vm-bench guests need a disk image under the member's control; base
images are never written (qemu `-snapshot`). Windows guests need a
license; macOS guests are not offered (Apple licensing — use a Mac
node over SSH-target mode instead).

## SSH-target mode (members' own desktop apps)

Generate the managed-settings block and distribute it via your
device-management channel:

```bash
appliance/gen-sshconfigs.sh --host claude.example.com --per-member \
	--start-dir '~/projects' --allowlist
# or merge into an existing managed settings file:
appliance/gen-sshconfigs.sh --host claude.example.com --per-member \
	--merge /path/to/managed-settings.json
```

Members' desktop apps then show the appliance in the environment
dropdown; sessions run on the appliance with connectors, plugins, and
MCP intact. Tailscale SSH or ordinary keys both work — the entry is
plain `user@host`.

## Break-glass access

If the tunnel or IdP is down: `sudo tailscale up --ssh` (overlay
profile installs tailscale; `setup.sh --profile overlay` if it was
never installed). xrdp/kasmVNC stay loopback-bound; reach them
through the tailnet. Remove the node from the tailnet when the edge
is healthy again if clientless-only is your policy.

## Backup and restore

Back up:

- `/etc/claude-appliance/` (engine.conf, appliance.conf, members.tsv)
- `/etc/cloudflared/` (tunnel config + credentials)
- member homes (`/home/*`) — contains Claude config, MCP configs,
  keyrings
- your Cloudflare Access policies (export or IaC)

Do **not** back up: `~/.config/Claude/vm_bundles/` (re-downloaded;
wiping it is the documented recovery for daemon startup failures),
`~/.config/Claude/claude-code-vm/` (CLI cache), vm-bench guest
overlays (disposable by design).

Restore drill: fresh box → `setup.sh` → restore `/etc/claude-appliance`
+ `/etc/cloudflared` → `member.sh add` each member (idempotent over
restored homes: existing accounts are adopted, configs kept) →
doctor to zero FAILs.

## Troubleshooting

Symptom-keyed, in the house style:

### Doctor: "session port bound publicly"

Something rebound kasmVNC/xrdp beyond loopback (config drift or a
package update). Fix the bind in `~/.vnc/kasmvnc.yaml`
(`interface: 127.0.0.1`) or `/etc/xrdp/xrdp.ini`
(`port=tcp://127.0.0.1:3389`), restart the service, re-run doctor.

### Member session up but Cowork won't start

Run `claude-desktop --doctor` inside the member's session — it knows
the Cowork isolation stack (bwrap/KVM deps, AppArmor userns on
Ubuntu 24.04+). The appliance doctor checks the appliance layer, not
the app's own stack; the two are complementary.

### Sign-in doesn't persist across restarts

Keyring problem. Check `appliance/setup.sh doctor` (non-empty
keyring check) and that `libpam-gnome-keyring` lines survived any
PAM changes. First-login-creates-keyring is normal (WARN, not FAIL).

### Cowork daemon dies mid-session

See [learnings/cowork-vm-daemon.md](https://github.com/aaddrick/claude-desktop-debian/blob/main/docs/learnings/cowork-vm-daemon.md) —
the respawn cooldown, log locations, and the vm_bundles wipe
recovery all apply unchanged inside appliance sessions.
