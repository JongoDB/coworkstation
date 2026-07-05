[< Back to README](../README.md)

# Cowork appliance — admin runbook

Operational procedures for a running appliance: provision, members, edge, distribution, backup, and recovery. Design: [design.md](design.md); phase specs: [phases.md](phases.md).

```bash
# Dev bootstrap — clone and run; the wizard prompts for anything
# missing (hostname, API token file, Access allow list):
git clone https://github.com/jongodb/coworkstation
sudo ./setup.sh

# Day-2 management is the cws CLI (installed onto PATH by setup):
sudo cws                                        # interactive menu
sudo cws member add alice                       # add a member
cws doctor                                      # health check
cws ssh-config --host claude.example.com --per-member
```

## Choosing a host: KVM for Cowork

Cowork's VM feature needs `/dev/kvm` on the box — which means bare
metal, or a VPS whose provider enables nested virtualization. Test
before you commit: nearly every provider bills hourly, so deploy the
smallest instance, run the one-liner, destroy it if it fails.

```bash
[[ -e /dev/kvm ]] && echo 'KVM: yes' || echo 'KVM: no'
grep -cE 'vmx|svm' /proc/cpuinfo   # 0 = no hardware virt exposed
```

`cws doctor` reports the same thing after install (`backend=kvm` vs a
loud `backend=none` WARN). Everything except the Cowork VM — chat,
Code tab, MCP servers, projects, the client bridge — works either way.

Provider status **as of 2026-07** (this changes; the one-liner above
is the truth, and corrections are welcome):

| Host | `/dev/kvm` | Notes |
|---|---|---|
| Any mini-PC / home box / bare metal | **yes** | enable VT-x/AMD-V in the BIOS if missing |
| Dedicated servers (Hetzner Robot/auction, OVH, etc.) | **yes** | it's real hardware |
| AWS EC2 `*.metal` | **yes** | only the `.metal` instance types; regular EC2 VMs no |
| Google Cloud (most x86 VMs) | **yes, opt-in** | set `enableNestedVirtualization`; [docs](https://cloud.google.com/compute/docs/instances/nested-virtualization/overview) |
| Azure (v3-series and newer) | **yes** | Dv3/Ev3 onward; [docs](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/nested-virtualization) |
| Hetzner Cloud (CX/CPX/CAX) | **no** | nested virt not enabled on cloud servers; their dedicated line is the yes |
| DigitalOcean droplets | **unsupported** | officially "not a planned or supported feature"; `/dev/kvm` sometimes appears but is undocumented and slow — don't build on it |
| Linode/Akamai, Vultr cloud compute | **no** (reported) | community-reported as unavailable; run the one-liner to confirm |

Live price check with $/member math:
[`research/2026-07-05-hosting-prices.md`](research/2026-07-05-hosting-prices.md).
If Cowork-in-a-VM matters to you, the sweet spot is a mini-PC at home
(N100-class boxes run the whole stack) or a cheap dedicated/auction
server; among hourly clouds, GCP with the nested flag is the easiest
to test on.

## Initial provision

### Zero-touch (recommended)

One command from a bare OS, given a scoped Cloudflare API token
(Account > Cloudflare Tunnel:Edit, Account > Access: Apps and
Policies:Edit, Zone > DNS:Edit — create it at dash.cloudflare.com >
My Profile > API Tokens):

```bash
printf '%s' 'YOUR-API-TOKEN' > /root/cf-token && chmod 600 /root/cf-token
sudo ./setup.sh --hostname claude.example.com \
	--cf-api-token-file /root/cf-token \
	--access-allow 'you@example.com'
```

That provisions everything: engine, session stack, kasmVNC, the
remotely-managed tunnel, the proxied DNS record, **and the Access
application with an allow policy** for the emails/domains in
`--access-allow` (required — a tunneled hostname without an Access
app is public). Then: open `https://claude.example.com`, pass the
Access login, sign into Claude, run `./setup.sh doctor`.

### Manual tunnel (no API token)

1. Fresh Debian 12+/Ubuntu 24.04+ box (x86_64 or arm64), DNS name
   picked (e.g. `claude.example.com`), Cloudflare zone for it.
2. `sudo ./setup.sh --hostname claude.example.com`
   - engine auto-selection: official apt build where `/dev/kvm`
     exists; this repo's build with the bwrap Cowork backend where it
     doesn't. Force with `--engine`. The decision is recorded in
     `/etc/coworkstation/engine.conf`.
   - add `--dry-run` first if you want to review the full plan.
3. Finish the tunnel (interactive, one time):
   ```bash
   cloudflared tunnel login
   cloudflared tunnel create coworkstation
   # set "tunnel:" + "credentials-file:" in /etc/cloudflared/config.yml
   cloudflared tunnel route dns coworkstation claude.example.com
   cloudflared service install && systemctl start cloudflared
   ```
4. In Cloudflare Zero Trust, create an **Access application** for the
   hostname with your IdP (SSO/MFA) policy. No port forwarding, no
   public binds — the doctor fails loudly if it ever finds one.
5. Log into the session once (browser → the hostname), sign into
   Claude, let the keyring initialize. Run
   `./setup.sh doctor` and get to zero FAILs.

Test environments for validating all of this (VPS → mini PC → Pi 5)
are specified in
[phases.md](phases.md#test-environments).

## Member lifecycle (advanced — read the posture first)

Add `--allow member@example.com` to scope the member's Access policy
to just their identity — forced per-member auth, the multi-tenant
default posture. Audit who actually signed in with `cws audit`.


Multi-user is an advanced configuration, not the default pitch. Each
member MUST sign in with their own Claude account — shared sign-ins
violate Anthropic's terms and trip account-security defenses from a
datacenter IP. A team-shaped deployment carries account-standing risk
the operator accepts; see the Positioning & risk section of
[design.md](design.md#positioning--risk).

```bash
sudo ./member.sh add alice --quota-mem 6G --quota-cpu 200%
sudo ./member.sh remove bob --keep-home
sudo ./member.sh remove bob --yes        # non-interactive full removal
./member.sh list
```

`add` creates the account, systemd slice quota, kasmVNC session on
its own display/port, ingress hostname (`alice.claude.example.com`),
and autostart. In **zero-touch (api) mode** the member's DNS record
and Access application are created automatically too, leaving one
manual follow-up; in manual mode there are two:

1. **Access policy** for the new hostname (manual mode only). Until it
   exists the hostname is served by the tunnel and is **PUBLIC** —
   `member.sh` warns loudly, and in api mode `./setup.sh doctor` FAILs
   on any ingress hostname with no Access app.
2. **First login** by the member: sign into their own Claude account;
   the keyring unlocks via PAM at session login from then on.

Sizing guidance: ~1–2 GB per active Cowork member on bwrap, ~4 GB on
KVM, plus the Electron sessions. Watch `systemd-cgtop` — quotas are
slices, so a noisy member throttles before starving the box.

## Cloud storage (keep project data off the appliance disk)

```bash
sudo ./storage.sh add --user alice --provider gdrive --name drive
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
sudo ./testbench/setup.sh --user alice
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
./gen-sshconfigs.sh --host claude.example.com --per-member \
	--start-dir '~/projects' --allowlist
# or merge into an existing managed settings file:
./gen-sshconfigs.sh --host claude.example.com --per-member \
	--merge /path/to/managed-settings.json
```

Members' desktop apps then show the appliance in the environment
dropdown; sessions run on the appliance with connectors, plugins, and
MCP intact. Tailscale SSH or ordinary keys both work — the entry is
plain `user@host`.

## Extra sessions (one member, several devices)

```bash
sudo cws session add alice --allow alice@corp.com
# -> https://alice-s50.<hostname>  (own Access policy, own sign-in)
sudo cws session list
sudo cws session remove alice 50   # config home is kept
```

Each extra session runs its own Claude Desktop under its own config
home (`~/.config/cws-sessions/N`) — sign in once per session; the
singleton lock never fights across devices.

## Idle reclaim (optional)

Stop desktops nobody is using — both signals must be cold: no
established client connections and no bridge activity inside the
window. Homes persist; `cws sessions start USER` brings one back.

```bash
sudo tee /etc/coworkstation/reclaim.conf << 'EOF'
idle_hours=8            # global window (0 = off)
idle_hours.alice=2      # per-member override
dormant_days=30         # long-idle stopped sessions show DORMANT
EOF
sudo cws reclaim --dry-run          # preview
```

Setup installs an hourly `cws-reclaim.timer` that runs this for you —
it's a no-op until the config above opts in.

## Break-glass access

If the tunnel or IdP is down: `sudo tailscale up --ssh` (overlay
profile installs tailscale; `setup.sh --profile overlay` if it was
never installed). xrdp/kasmVNC stay loopback-bound; reach them
through the tailnet. Remove the node from the tailnet when the edge
is healthy again if clientless-only is your policy.

## Backup and restore

Encrypted, incremental, one command (restic under the hood; the key
never leaves the box unless you copy it — DO copy it somewhere safe):

```bash
sudo cws backup setup /backup/cws     # or sftp:..., rclone:gdrive:cws
sudo cws backup run                   # all session homes; cron-able
sudo cws backup list
sudo cws backup restic restore latest --target /tmp/restore
```

Also back up (small, config-only):

- `/etc/coworkstation/` (engine.conf, appliance.conf, members.tsv)
- `/etc/cloudflared/` (tunnel config + credentials)
- your Cloudflare Access policies (export or IaC)

Do **not** back up: `~/.config/Claude/vm_bundles/` (re-downloaded;
wiping it is the documented recovery for daemon startup failures),
`~/.config/Claude/claude-code-vm/` (CLI cache), vm-bench guest
overlays (disposable by design).

Restore drill: fresh box → `setup.sh` → restore `/etc/coworkstation`
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

Keyring problem. Check `./setup.sh doctor` (non-empty
keyring check) and that `libpam-gnome-keyring` lines survived any
PAM changes. First-login-creates-keyring is normal (WARN, not FAIL).

### Cowork daemon dies mid-session

See [learnings/cowork-vm-daemon.md](https://github.com/aaddrick/claude-desktop-debian/blob/main/docs/learnings/cowork-vm-daemon.md) —
the respawn cooldown, log locations, and the vm_bundles wipe
recovery all apply unchanged inside appliance sessions.
