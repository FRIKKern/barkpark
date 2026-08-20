# cch-w71 · console-mint-detail — re-derivation recipe

Verifier assignment [console-mint-detail], wave 71. All facts derived from origin/main bytes.

## Extract + syntax-check the shipped SPA

    git show origin/main:cloud/priv/static/app.js > $SCRATCH/app.js
    node --check $SCRATCH/app.js          # -> CHECK_OK, 24346 lines

## Drive the pure helpers in a node:vm probe

Faithful copy of the canonical harness sandbox (cloud/priv/static/__app.test.mjs)
is REQUIRED — `document.readyState:"loading"` keeps init() unbound so the eval is
side-effect-free and `__bpTestHook` fires at the IIFE tail. A bare sandbox throws
`Cannot read properties of undefined (reading 'setAttribute')` before the hook and
yields NO_HOOKS. Probe script: $SCRATCH/probe.mjs (mirrors harness stubs, then:)

    const { siteCreateFailureCopy, friendly } = hooks;
    const r = { status:502, data:{ error:"read_token_mint_failed",
                detail:"acme-box said: permissions not allowed" } };
    siteCreateFailureCopy(r)                 // A
    friendly(r.data, "create failed (502)")  // B
    siteCreateFailureCopy({status:502,data:{error:"zzz_unknown",detail:...}}) // C

Output (quoted verbatim):

    A => "Something broke on our side minting this site's read token — not your input. Try again in a moment."
    B => "create failed (502)"
    C => "create failed (502)"

## Router census — POST /v1/sites top-level `detail` emitters

    git show origin/main:cloud/lib/barkpark_cloud/web/router.ex | sed -n '6900,6960p'

Create-arm slugs carrying a top-level `detail`:
- read_token_mint_failed (502) — line 6939 — console WITHHOLDs (curated arm, D846/cch-w66-bl)
- content_binding_required (422) — 6926 — console AUTHORs its own (drops CLI-voiced detail)
- node_ports_exhausted (503) — 6934 — console RELAYs `detail` verbatim
- content_binding_empty (422) — 6950 — console RELAYs verdict + composes menu
- barkpark_required (422) — 6917 — reaches friendly() D855 allowlist; unreachable from modal (siteCreateBody always sends barkpark_id)
- name_required / barkpark_not_found — NO detail; invalid — `details` map, no top-level detail

## Verdict

The create modal always renders `siteCreateFailureCopy(r)` (app.js create-submit
handler, `errBox.textContent = siteCreateFailureCopy(r)`). The ONLY create-arm
detail the console drops is the mint 502 — and the drop is DELIBERATE (WITHHOLD
stance, cch-w66-bl/D846), matching friendly()'s D855 rung which fences the mint
slug OUT of its detail-relay allowlist per the 5xx honesty law. The assignment's
expected fallback "create failed (502)" is what raw friendly() returns (B), NOT
what the create modal renders (A). There is no accidental status-line leak to fix.
