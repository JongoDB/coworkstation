# KVM hosting for full parity — live price check, 2026-07-05

Direct price/constraint checks against provider pages (search passes
couldn't verify prices; see pass-3 coverage gaps). Goal: best
always-on $/member for 2–10 members needing `/dev/kvm` (the Cowork
microVM). Prices move — treat the check commands in the
[runbook](../runbook.md#choosing-a-host-kvm-for-cowork) as the truth.

## Verified live (fetched 2026-07-05)

| Option | Price | Spec | Fit |
|---|---|---|---|
| OVH So you Start **SYS-1** | **$33.20/mo** | Xeon E-2136 6c/12t, 32–128 GB RAM, 2×512 GB + 2×4 TB, unmetered | The value pick: real hardware, ~4–6 members with Cowork VMs → **$6–8/member/mo** |
| OVH SYS-2 | $42.10/mo | Xeon-D 2141I 8c/16t, 32–128 GB | More cores, slower clocks |
| OVH SYS-3 | $46.50/mo | Xeon E-2288G 8c/16t, 32–128 GB | The 8–10-member box |
| Kimsufi (KS) | from $11.10/mo | catalog is JS-loaded; specs unverified | Entry tier; likely 1–2 members, check live |
| GCP nested virt | hourly (calculator) | **NOT on E2**, not AMD/Arm — Intel N1/N2-class only; expect ≥10% perf hit in nested VMs | Burst **testing** only, not always-on economics |

## Not fetchable statically (check live)

- **Hetzner Server Auction** (`hetzner.com/sb`) — the listing is a JS
  app; comparable Xeon/32 GB boxes historically land in the €25–40/mo
  band. Hetzner **Cloud** VPS remain a no (no nested virt — see the
  runbook table).
- **Mini-PC at home** (N100/N305/Ryzen) — street price roughly
  $130–250 one-time (unverified estimate) + power. Cheapest
  long-run $/member by far after ~6 months vs any rental, and the only
  option where the hardware is literally yours; behind the Cloudflare
  tunnel it needs no port forwarding, so residential hosting works.

## Recommendation

- **2–6 members, always-on:** OVH SYS-1 (or a Hetzner auction box if
  the live listing beats it) — verified $33.20/mo, KVM guaranteed
  (bare metal).
- **Personal / 1–2 members:** a used mini-PC at home wins on cost and
  ownership; a KS/auction box wins on not-being-in-your-house.
- **Bursts and CI:** GCP with the nested-virt flag on an Intel
  N-series VM; never leave it running.

Sources: eco.ovhcloud.com (SYS prices), kimsufi.com (starting price),
docs.cloud.google.com/compute/docs/instances/nested-virtualization/overview
(machine-series restrictions, performance caveat), hetzner.com/sb
(dynamic app — no static listing).
