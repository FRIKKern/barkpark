# Design-decision log — Barkpark Cloud remake (P3)

Why, in one page — to prevent re-litigating and cargo-culting.

- **Evergreen mint primary** (#3fcf8e dark / #15804e light): the non-blue answer to "every console is blue"; green = healthy/primary only, never decoration. Light value is a separate ramp because the mint does not survive light mode unchanged.
- **fg4 = meta-only, ≥3:1 enforced**: quiet text is a duty cap, not an excuse. Light fg4 darkened to #76818f after the machine check failed it (round 9).
- **Status told once**: one pill (glyph+colour+word) per row; axes (health × billing × update) live in the mono metadata line; provider colour is hollow-mark identity, never status.
- **Sidebar context-morph**: two-layer nav — entering a site/instance collapses layer 1 to a "←" exit and shows the thing's own sections. Chosen over horizontal tabs so advanced settings rows have room to grow. Deep links: #instance/<id>, #site/<id>.
- **Honesty grammar**: failure beats false green (failed stages snap, never ease); "unmetered"/"not measured yet — we don't guess"; unreachable ≠ refused, copy must say which; born-failed deploys keep the real advice sentence.
- **Coalescing grammar**: "thing × N · cadence · worst verdict" + expand — repetition summarised, never hidden.
- **Cost honesty as flagship**: real provider prices, bill previewed not estimated, "no usage line items, ever" — the identity contrast vs usage-billing anxiety.
- **One primary action per screen**; danger ends in "…" and gates on type-the-name.
- **CLI-as-GUI** for operator-grade lifecycle verbs (archive/resurrect/adopt/audit): copyable commands instead of half-owned buttons.

# The unprompted memo — what we'd do next that you didn't ask for

1. **The content loop is the marketing site.** Draft-content previews and content-rev-pinned deploys are the only features here Vercel structurally cannot copy. The public front door (P2-1) should lead with them, not with parity screens.
2. **Kill the Overview/Fleet split.** With ≤3 instances they're 80% the same page; the triage headline + attention queue makes Fleet the natural home. Revisit when a real 10-instance customer exists.
3. **The Operator console wants to be a status page.** The rollout brake + canary wave is one RSS feed away from a public "platform status" page customers would trust — cheap, on-brand honesty.
4. **Budget alarm before analytics.** A "warn me at €X/month" field on Usage & cost is a smaller build than the analytics panel and lands the identity harder.
5. **Subset the fonts.** Inter + Plex Mono at 4 weights is ~600KB; a latin subset at 3 weights is ~140KB. Do it when self-hosting lands, not after someone notices the console loads slower than the sites it deploys.

# Handover inventory

- `Barkpark Cloud v4.dc.html` — interactive prototype (scenario tweaks: theme, accent ×5, billing, role, gitAppLinked, instanceState).
- `Styleguide.dc.html` — canonical spec: tokens, components with states, machine contrast table, responsive + motion contracts (P1-2/5/6).
- `design/tokens.json` — token proposal incl. 5 accent ramps; map into the canonical schema on your side.
- `design/renders/` — matrix + screen + accent proofs, indexed in README.md.
- Licensing note: IBM Plex Mono is OFL — self-hosted woff2 distribution is legally clean; confirm the charter sign-off recorded before build.

Remaining from the work order: **P1-4 email fleet** (not yet designed), P2-1 front door, P2-2 concept trio (gated on the Forms owner call), P2-4 a11y pass, P2-5 icon-set spec.
