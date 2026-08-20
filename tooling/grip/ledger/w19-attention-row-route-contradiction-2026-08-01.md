# w19 verify — the `.attention-row` "mixed-fleet renders ZERO" contradiction is a ROUTE artifact

Both contradicting rows measured real DOM. They measured **different routes of the same scenario**.
`mixed-fleet`'s `deepLink` is `#fleet` (scenarios.mjs); the two `overview-*` scenarios deepLink to
`#overview`. A driver that honours `deepLink` sees zero `.attention-row` on mixed-fleet; a driver that
navigates `#overview` (or bare, which the SPA resolves to `#overview`) sees **three**.

## Re-derivation (origin/main bytes, no worktree involvement)

```bash
D=$(mktemp -d); git archive origin/main cloud/priv/static | tar -x -C "$D"
# then drive the export with CDP; the harness's own server enforces served==disk:
node "$D/cloud/priv/static/__preview__/serve.mjs" --port 47311 &
# navigate ?scen=<scen>&theme=<t><HASH>, viewport <w>x900, --hide-scrollbars, cache disabled,
# and report: document.querySelectorAll('.attention-row').length
#   plus, per .status-pill-detail: scrollWidth / clientWidth / closest wrapper class.
```

Driver used this phase: `scratchpad/attn-drive.mjs` (a 90-line reduction of `overflow-guard.mjs`'s
Cdp class + `nav()` + the GR125a served-bytes==disk-bytes refusal). Pin `HASH` explicitly —
**omitting it is not neutral**; it is `#overview`.

## The numbers that settle it (origin/main = 29cb76e60, Chrome 150.0.7871.187, node v22.22.0)

| route | scen | `.attention-row` | worst `.attention-row` cell @320 |
|---|---|---|---|
| `#overview` | mixed-fleet | **3** | 237/139 = 41.4% "Payment failed — subscription past due" |
| bare (no hash) | mixed-fleet | **3** | identical to `#overview` |
| `#fleet` | mixed-fleet | **0** | n/a — 5 details, all `.fleet-status`, all 0% hidden |
| `#overview` | overview-past-due | 1 | 237/139 = 41.4% (same string) |
| `#overview` | overview-attention | 1 | 165/148 = 10.3%; worst is @769 = 165/117 = 29.1% |

Light and dark are byte-identical in every cell.

`.attention-row` band on mixed-fleet#overview: clipped 320/360/375/390 **and 769**; clean
430/620/800/900. The "170 of 245" the wave-18 amendment called unreproducible is row **[0]** at 320,
read from ONE element at ONE width. The amendment's "same element at two widths" diagnosis is the
`#fleet` route's `.fleet-status` cell (sw 170 @320, sw 245 @769, both `cw == sw`).

## Stale sibling numbers

The amendment's `.instance-card-head` figures (56/165 = 66.1%, 45/237 = 81.0%) do not reproduce on
origin/main: the wrap remedy is merged at `app.css:5411-5420`, so those pills now wrap to 40px and
read `scrollWidth == clientWidth` (0% hidden). No `.attention-row .status-pill` wrap rule exists —
that host is unpaid.
