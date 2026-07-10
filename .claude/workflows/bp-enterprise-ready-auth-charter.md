# Epic charter — enterprise-ready-auth (prove-and-close wave, 2026-07-10)

> NOTE ON THIS PATH: the epic-cycle charter slot `bp-cloud-epic-charter.md` currently holds the
> LIVE **p-quality-gate** epic memory — do not clobber it. This file is the memory of the
> **enterprise-ready-auth** epic. Future waves of this epic read/write THIS file.

Epic anchor: bp task `enterprise-ready-auth` ("Enterprise-ready auth — one layer, easy for everyone", priority 1).
Design paper: `enterprise-ready-barkpark` (body_html-only; read via `bp tinker doc paper enterprise-ready-barkpark`, NOT `bp paper view`).
Wave papers: `enterprise-ready-auth-wave-2026-07-10` (w8, prove-and-close) · `enterprise-ready-auth-wave-2026-07-10-w9` (w9, LAND w8).

## Vision

One auth layer that is the easy choice for everyone: byte-identical zero-tax for a solo dev who declares
nothing, and provably fail-closed for an enterprise that turns everything on. The epic's 30 children built
the surface (SSO/SAML/OIDC/social, SCIM, MFA/passkeys/magic-link, audit bus + SIEM export, sessions/lockout,
admin portal, trust papers). This wave PROVES it, closes the two runtime-proven fail-opens the proof round
found, and rolls honest evidence up into the epic's 6 blank acceptance criteria. Finished experience: an epic
anchor whose every AC carries named, reproducible evidence or a written human-gate recipe; an enterprise admin
who can set org auth policy (MFA, session lifetime/idle) that binds on EVERY entry path; and an audit log with
no silent auth events.

## Decisions

1. **Prove-and-close, not greenfield** — 30/30 children done and (verified) honestly so; the 6 blank epic ACs
   are a rollup-writing gap plus two real defects, so the wave is evidence + fixes, not new capability sprawl.
2. **Fix the SSO/LiveView org-MFA fail-open at both chokepoints** (SSO mint-time + LiveView on_mount) —
   runtime-proven: a governed factor-less SSO session mounts scoped Studio while the password door blocks the
   same user (probe: "PASSWORD DOOR: blocked?=true" vs "SCOPED STUDIO: ADMITTED (fail-open)").
3. **Do NOT add an org-MFA block to POST /v1/auth/login** — mint-and-flag is deliberate (the session is how a
   governed user enrols; session_issuer.ex stamps `mfa_enrolment_required`), and RequireOrgMfaEnrolment already
   403s that session on the gated surface; the real holes are SSO controllers + LiveAuth cookie reuse.
4. **Owner-bound PATs are IN scope for SCIM deprovision** — runtime-proven leak: verify_token still returns
   {:ok, token} after hard SCIM DELETE; revocation must stamp `revoked_at` BEFORE the hard-delete nilifies
   `owner_user_id` (after nilify there is no key left). Share tokens are scope-keyed, not user-keyed —
   explicitly OUT, named in the AC evidence rather than silently omitted.
5. **AC1 splits into two legs** — self-hosted leg PROVEN today (Keycloak-in-Docker lane ran green at HEAD:
   5 tests, 0 failures, ~375s, zero human gates); market-IdP leg (Okta/Entra) is human-gated on owner creds and
   gets a recipe task, not invented build scope. The lane stays on-demand, not per-PR CI (~6min cold cost).
6. **AC6 (zero-tax) renegotiates from "byte-identical" to two provable legs** — API leg: response-byte-identical
   for ungoverned callers (the existing zero-tax contract test, promoted as evidence); browser leg: behavioral
   no-op (token-paste authenticates via the byte-identical code path; nothing new required with nothing declared).
   No structural/golden-HTML diff — the login page was legitimately rebuilt BY the epic itself (pre-epic baseline
   d7682b8c is a 46-line token-paste card; the redesign was deliverable work).
7. **Org policy copies the require_mfa template exactly** — nullable org column, UUID-guarded Tenancy setter,
   strictest-wins resolution across a user's orgs, admin-portal toggle, deny-path test. This wave: session idle
   timeout (predicates already written+tested in user_session.ex, just unwired) + absolute session lifetime.
   Allowed-auth-methods (SSO-only/disable-password) is pure greenfield → backlog.
8. **Audit silent events, ownership split by file to keep builders parallel** — SSO-callback failures belong to
   the slice that owns the SSO controllers (S1); token/SCIM lifecycle to the scim.ex/auth.ex owner (S2);
   account/session/webhook events to S3; org-policy-change audit to the tenancy-setter owner (S4). New events
   use existing categories (auth/token/membership) — no new category enum.
9. **Ledger honesty resolves by annotation, not reopening** — era-w3-sso-spike (0/3) is documented supersession
   (real SAML/OIDC/JIT shipped instead): backfill its criteria evidence with pointers. era-w2-mfa-policy's 4th
   criterion split to era-w2-org-require-mfa (done 4/4): annotate. era-w6-soc2's pen test is an honestly labeled
   procurement gate: keep. No fabrication found; nothing reopens.
10. **Trust papers are real evidence** — all four (soc2-controls-mapping 7.7KB, VDP 2KB, dpa-template 6.6KB,
    support-tiers 1.8KB) verified substantive with code references that exist at HEAD; they carry their own honest
    self-attestation caveats. AC5 cites them + splits human legs (pen test, DPA legal sign-off, SOC2 Type II
    window) into recipe'd human-gated criteria.
11. **cloud/ is untouched** — the auth-tunnel (#690) is control-plane fleet login; the epic's ACs are
    instance-scoped. Per-team SSO into barkpark.cloud is a different initiative.
12. **Sessions self-management stays inside the MFA-enrolment perimeter** — fail-closed law wins: a governed
    unenrolled user enrols first; the only exemptions remain /me, /logout, and the enrolment endpoints.
13. **Builder models** — fable for the cross-surface security binding (S1) and the epic-rollup honesty work (S7);
    opus for the well-specified rest.

### Wave w9 decisions (2026-07-10 evening — the LANDING wave; no new capability scope)

14. **w9 lands, never rebuilds** — w8 built everything and died exactly at the local→remote boundary (zero
    pushed branches, zero PRs, no crash artifact). The `-r` review-twin SHAs are canonical: S1 d91972ea /
    S6 a06811ba / S7 18ef4ff2 byte-identical to base; S2 5608b89b / S3 d00e8562 / S4 a197d1c7 / S5 cdae5d94
    exactly +1 mix-format-only commit (every diff line read, non-semantic). A slice reopens honestly only if
    its gate reds at land-time HEAD — never merge on stale proof.
15. **Per-slice PRs, strict landing order S1→S2→S3→S4→S5→S6→(build B7)→(rollup S7-close)** — each lander works
    in its slice's existing worktree, fast-forwards the branch to its `-r` twin, fetches + rebases onto CURRENT
    origin/main (main advanced twice during verification; a conflicting PR silently skips ALL CI — rebase-before-
    push is mechanically mandatory), re-runs the slice gate, pushes, opens a PR whose body carries `Task: <id>`,
    and merges its own PR once Elixir Test is green AND the predecessor slice has merged. No branch protection
    exists; Elixir Test green is the law (dont-merge-before-elixir-test). The landing builder is the lead's hand
    for its slice — it closes the merge-gated criterion with the merged PR as evidence; Review re-verifies.
16. **S3 owns the wave's only real conflict** — session_issuer.ex: after S1 merges, S1's four appended helpers
    (org_mfa_enrolment_blocked?/deny_org_mfa_enrolment/org_mfa_enrolment_message/browser?) collide mechanically
    with S3's appended audit_session_mint at the module tail. Resolution is a prescribed function UNION (keep
    BOTH groups; S3's audit_session_mint caller inside issue/3 auto-merges above the conflict). Proven by the
    stacked-merge probe: full 7-branch tree compiles --warnings-as-errors clean, 214 targeted tests 0 failures.
17. **S2↔S5 conflict fear REFUTED** — a REAL stacked merge (S2 then S5 onto origin/main) auto-resolved scim.ex
    and scim_groups_controller.ex with zero conflicts; delete_group/list_org_groups land single-defined and
    correct (read, not just trusted). S5 after S2 is a mechanical rebase, not budgeted reconciliation.
18. **S7's charter lands via THIS Decide commit** — the charter (S7's 140 lines, byte-identical prefix, + this
    w9 section) commits straight to main now; the -31 branch (18ef4ff2, single-file, same content) is RETIRED
    unpushed — avoids an add/add merge conflict and pays S7's only git-side debt. era-w8-epic-rollup closes on
    its already-live ledger work + charter-on-main.
19. **D69 return_to loss ACCEPTED for MFA-blocked users** — require_org_mfa's halt redirects to bare /login (no
    return_to) for an MFA-required admin on a chat deep link. Fail-closed beats deep-link convenience; probe-
    proven no security exposure (halt wins by on_mount ordering AND the populations are disjoint on user_session
    presence). Parity follow-up filed as `era-bl-mfa-returnto-parity` (p3) — never a landing blocker.
20. **Remainders triaged: build one, park one** — `era-w8-audit-login-second-factor-fail` BUILDS this wave
    (standalone at HEAD: silent branch verified at auth_controller.ex:113-120, emit pattern exists at :552-559;
    lands AFTER S3 to avoid auth_controller.ex overlap). `era-scim-conformance-polish` PARKS (was malformed —
    no acceptance_criteria field; repaired with real ACs this wave, explicitly blocked on S5's merge).
21. **Battery path corrected** — studio_user_login_test.exs lives at test/barkpark_web/controllers/; `mix test`
    SILENTLY skips nonexistent paths (w8's MUST-RUN battery ran 69 of 84 tests because of this). Every gate in
    this wave uses the corrected path; never cite a test path you haven't `ls`-proven.
22. **Close mechanics: fresh claim, epoch from the claim response** — the 45-min sweeper reaped all w8 claims
    at 19:47:01Z (epoch 1→2, tasks open, criteria evidence intact). Builders claim fresh (→ epoch 3), stamp
    evidence the moment a criterion is proven, close with THEIR claim response's epoch; on 409
    fenced_off/doc_changed_since_claim → re-claim fresh, never guess epochs.
23. **Push proven passable; w8's stall stays unexplained but non-blocking** — gh auth valid (FRIKKern, repo
    scope), `git push --dry-run` accepted by origin, no protected refs. Builders push FIRST after the gate
    passes — never batch the landing to the end of a run.
24. **public_demo_studio hygiene** — any test that sets it false MUST restore the previous value on_exit; a
    leaked false poisons every subsequent bare-conn Studio LV test (caused a 207-failure scare during w9
    verification; the suite is async:false).

## Roadmap

### Wave w8 (7 slices, integration-ordered) — BUILT, never pushed; landing = wave w9
1. `era-w8-sso-mfa-binding` (large, fable, p0) — bind org-require-MFA fail-closed on every SSO/browser entry path
   (SSO mint-time + LiveView on_mount) + audit failed SSO callbacks; deny-path tests per surface.
2. `era-w8-deprovision-pat-revocation` (medium, opus, p0) — SCIM deprovision revokes owner-bound PATs in the same
   transaction (before hard-delete); audit PAT mint/revoke + SCIM group create/delete.
3. `era-w8-audit-auth-events` (large, opus, p1) — emit the silent account/session events: failed login, lockout
   trip, session mint, logout, recovery-code use, password reset, webhook CRUD.
4. `era-w8-org-session-policy` (medium, opus, p1) — org-level session idle-timeout + absolute lifetime
   (require_mfa template), wired fail-closed into verify; admin-portal controls; policy-change audit.
5. `era-w8-scim-conformance` (medium, opus, p2) — discovery endpoints, ListResponse paging, Groups filter/PUT,
   meta timestamps/version, scimType errors, broader PATCH.
6. `era-w8-zero-tax-harness` (small, opus, p1) — behavioral zero-tax tests (solo token-paste path, ungoverned JSON
   login body golden) + the missing malformed-UUID HTTP deny-path test on DELETE /v1/auth/sessions/:id.
7. `era-w8-epic-rollup` (medium, fable, p1) — rewrite the 6 epic ACs with evidence / split human-gated legs;
   annotate the 3 defensible-unmet children; amend the design paper (W7 addendum + stale "Remaining" table).

### Wave w9 (this wave — 8 slices, LAND w8; strict integration order)
1. `era-w8-sso-mfa-binding` LAND (medium, fable, p0) — push+PR+merge d91972ea; re-verify the router shape at
   land HEAD (every live_session except :scoped_paper_reader carries :require_org_mfa — if main added one, ADD
   the hook, that IS the slice's law).
2. `era-w8-deprovision-pat-revocation` LAND (small, opus, p0) — push+PR+merge 5608b89b, after S1 merges.
3. `era-w8-audit-auth-events` LAND (medium, opus, p1) — rebase over merged S1 resolving the session_issuer.ex
   union (D16); push+PR+merge d00e8562.
4. `era-w8-org-session-policy` LAND (small, opus, p1) — push+PR+merge a197d1c7 (migration rides along), after S1.
5. `era-w8-scim-conformance` LAND (medium, opus, p2) — push+PR+merge cdae5d94, after S2 (D17: mechanical).
6. `era-w8-zero-tax-harness` LAND (small, opus, p1) — push+PR+merge a06811ba, after S1 (its tests assert S1
   behavior) — test-only.
7. `era-w8-audit-login-second-factor-fail` BUILD (small, opus, p2) — fresh worktree from origin/main AFTER S3
   merges; emit auth/mfa_failed (metadata context "login") at login_with_mfa's mfa_required branch + Repo.exists?
   test + deny-path (successful factor emits none).
8. `era-w8-epic-rollup` CLOSE-OUT (small, fable, p1) — after 1-7 merged: flip epic AC2/AC4/AC6 met=true citing
   the merged PR numbers + test names; verify charter on main; clean the wf_527f53f4-206-25..32 worktrees +
   stale branches (cody/scim-layering tip, fix/scim-casterror-redaction worktree — both content-landed); close
   every w8 task's merge criterion with fresh claims.

### Backlog (filed, published, not this wave)
- `era-hg-okta-live-idp` (p2, HUMAN-GATED) — Okta/Entra live-tenant SSO smoke; recipe written; flips AC1 leg two.
- `era-bl-allowed-auth-methods` (p2) — org policy: SSO-only / disable-password; greenfield; deny-path spec included.
- `era-hg-pen-test` (p3, HUMAN-GATED) — third-party pen test procurement; recipe written; AC5 leg.
- `era-hg-dpa-legal-signoff` (p3, HUMAN-GATED) — route dpa-template through counsel; stamp approval.
- `era-hg-soc2-type2-window` (p4, HUMAN-GATED) — SOC2 Type II observation window + audit firm; calendar-bound.
- `era-scim-conformance-polish` (p3, REPAIRED w9) — PATCH path-less replace, /ResourceTypes/:id + /Schemas/:id,
  scim+json content-type, If-None-Match 304; blocked on era-w8-scim-conformance merging.
- `era-bl-mfa-returnto-parity` (p3, NEW w9) — route require_org_mfa's halt through denial_target so the deep link
  survives MFA enrolment (D19 accepted the loss for now).
- `era-bl-scim-discovery-tests` (p3, NEW w9) — dedicated scim_discovery_controller_test.exs (coverage today is
  incidental inside scim_users_controller_test.exs); after S5 merges.
- `bp-paper-view-bodyhtml-fallback` (p2, UNPARENTED — CLI scope, not auth) — `bp paper view` misreports
  body_html-only papers as "no renderable blocks"; misled two scouts this wave.

### Adjacent open work (NOT duplicated here — lives under the Felix audit umbrellas)
- webauthn delete_credential non-UUID 500 (task-b5af6673bfb773ea), HIBP transport fail-open test
  (task-c24cf30a5d9c9a39), Sobelow/mix-audit CI gates (task-a41fc4590b2c2eb1).

### Hard constraints (every slice)
.ex waits for the Elixir Test gate; auth fails closed (undecidable = logged out); tenancy law
(docs/contracts/tenancy.md); Ecto.UUID.cast guard on raw ids; deny-path tests mandatory on every new gate;
zero-tax invariant sovereign (nothing changes for a user who declares nothing); worktrees from origin/main after
git fetch; builders claim first; PR body carries `Task: <id>`. api/ tests: `CC=/usr/bin/clang mix test <files>`
from api/, local Postgres on :5432, never prod compile.

## Wave log

### Wave w8 2026-07-10 — DECIDE complete; 7 slices filed, builders flying
Decisions above ratified against the 6-verifier proof round. Two fail-opens runtime-proven (SSO org-MFA bypass;
PAT survives SCIM deprovision), both commissioned as p0 slices S1/S2. Ledger verified honest (no reopens). AC1
self-hosted leg + AC3 RBAC pinning + trust papers all proven green at HEAD. AC1 market-IdP, AC5 human legs, AC6
wording all resolved per D5/D6/D10. Slice tasks: era-w8-sso-mfa-binding, era-w8-deprovision-pat-revocation,
era-w8-audit-auth-events, era-w8-org-session-policy, era-w8-scim-conformance, era-w8-zero-tax-harness,
era-w8-epic-rollup — all children of enterprise-ready-auth, linked to wave paper. Review phase writes the close.

### Wave w8 2026-07-10 — S7 rollup DONE (ledger + paper honesty written up)

Executed by `era-w8-epic-rollup` (branch `loop-epic/roll-honest-evidence-into-the-6-epic-acs-6`); this commit
also makes THIS charter durable (it existed only uncommitted in the shared checkout — reconcile, don't fork).

- **6 epic ACs rewritten + published** on `enterprise-ready-auth` (all evidence-bearing; gate
  `all 6 ACs carry evidence` green). AC3 flipped **met=true** (tenancy_rbac_test.exs pinning, proven at HEAD).
  AC1 split per D5 (Keycloak lane proven / era-hg-okta-live-idp human leg); AC6 reworded to two behavioral legs
  per D6. AC2/AC4/AC6 stay met=false with pointers at the in-flight w8 slices (era-w8-deprovision-pat-revocation,
  era-w8-audit-auth-events + era-w8-sso-mfa-binding, era-w8-zero-tax-harness) — **the lead flips those on merge**;
  the sibling slices were all in_progress/unmerged when the rollup ran, so no unmerged work was cited as done.
  AC5 split per D10 (self-serve legs proven: 4 substantive papers + era-w6-gdpr/status-sla/backup-dr/dpa; human
  legs → era-hg-pen-test, era-hg-dpa-legal-signoff, era-hg-soc2-type2-window).
- **3 defensible-unmet children annotated per D9** (evidence backfilled, met flags untouched, no reopen):
  era-w3-sso-spike (supersession pointers → era-w3-saml/oidc-rp/jit-domain + Keycloak lane), era-w2-mfa-policy
  criterion 2 (split child era-w2-org-require-mfa done 4/4 + names the SSO-binding residual), era-w6-soc2
  pen-test criterion (→ era-hg-pen-test procurement gate).
- **Design paper `enterprise-ready-barkpark` amended** (body_html 29973B → 32155B, published, re-read clean):
  STALE note under "Remaining — gated on human input" (points at era-hg-* tasks + the wave paper as current
  truth) + a "Wave 7 addendum" table naming the five children the six-wave plan never named
  (era-w7-auth-event-webhooks, era-w7-lockout-breach-check, era-w7-oidc-group-roles, era-w7-saml-idp-init-slo,
  era-w7-session-management — all verified done 4/4).
- **Epic anchor NOT closed** — lead's call. Close recipe: once the six w8 slices merge, flip AC2/AC4/AC6 with the
  merged test names as evidence; AC1/AC5 stay split until their era-hg-* human legs run (or the lead re-scopes).
  Note: era-w8-epic-rollup's own criteria were stamped via doc patch under its claim, so a plain
  `bp task close` may 409 `doc_changed_since_claim` — re-claim fresh and close (expected, documented pattern).

### Wave w9 2026-07-10 — DECIDE complete; landing wave filed (8 slices), builders flying

w8's stall forensics: the wave died at the local→remote boundary with everything built, reviewed, and locally
integrated — zero pushes, zero PRs, no crash artifact. w9 verification (4 deep verifiers, run proofs):
- Both p0 security claims PROVEN on code merged with today's HEAD: org-MFA fail-closed on all 11 gated
  live_sessions (12th :scoped_paper_reader excluded by design; router.ex byte-untouched by main since the fork),
  PAT revocation before SCIM hard-delete (deny-path: verify_token → {:error,:unauthorized}). Corrected battery:
  84 tests 0 failures; full suite at merged HEAD: 9787 tests 0 failures.
- MFA halt × studio-chat D69 return_to: halt WINS (ordering + disjoint populations, probe 2/2) — fail-closed
  holds; UX loss accepted per D19, parity backlogged.
- S2↔S5 "invisible conflict" REFUTED by real stacked merge; the ONLY conflict in the whole 7-branch stack is
  the mechanical S3 session_issuer.ex function-union (D16 prescribes the resolution).
- Push mechanics proven (gh auth valid, dry-run accepted). Ledger clean: the cross-epic clobber incident
  (task-11390a3b900c8a09) was repaired same-day and verified holding; all w8 claims swept to open/epoch 2.
Charter committed to main by THIS wave (D18) — the -31 rollup branch is retired. 8 slices filed/perfected under
enterprise-ready-auth, wave paper enterprise-ready-auth-wave-2026-07-10-w9 linked both ways. Backlog:
era-bl-mfa-returnto-parity + era-bl-scim-discovery-tests filed; era-scim-conformance-polish repaired + parked.
Review closes the Paper as the debrief and re-verifies every merge-gated close.
