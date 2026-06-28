# Onboarding / Time-to-Value — ASSESSMENT

<!-- dimension: Onboarding / Time-to-Value | scope: onboarding surface only | avg: 32/100 (at audit) -->

> **⚠️ MOSTLY RESOLVED (2026-06-28).** This is the original audit snapshot, kept as the
> record of what was found. Most gaps below have since been fixed — onboarding now
> scores **93/100** (currency, lead-with-value, waterfall, path-completeness all
> 100; only time-to-first-value 75, which is structural for a managed-Cloud flow).
> The closed backlog (BLOCKER-1, DOC-1…4) is in [`KNOWN-ISSUES.md`](KNOWN-ISSUES.md);
> re-run `node tooling/doc-onboarding/onboarding.mjs` for the live score. For what
> was closed vs. what remains open, see KNOWN-ISSUES.md — the DOC-6 items
> (js/README.md consumer path, sdk/README.md demo placement, personal-local.md
> jargon opener) and the INDEX.md entries for CLOUD-QUICKSTART.md and
> ops/barkpark-cloud-go-live.md were deferred as "Remaining to verify+fix" and
> are still open.

## 1. Headline grade: 32 / 100 — Weak, bordering Failing

**Band: Weak (40–59) overall, but dragged toward Failing by a single segment.** The OSS self-host path, viewed in isolation, is *Strong* — `TASK-SYSTEM.md` (62) walks the AI-agent claim→work→close loop cleanly from one-liner to full contract, and QUICKSTART's local route has its destructive-step warnings in the right order. If the repo only sold self-hosting, this would score in the 70s.

It does not. The **single biggest problem** is that **the fastest, most valuable, and most-shipped path — Barkpark Cloud — does not exist as an onboarding surface at all.** ~30 merged `feat(cloud)` PRs (#251–#283: `bp signup`, `bp login`, `bp subscribe`, `bp launch`, `bp go-live`, `bp barkparks`, `bp doctor`, `bp sites`, `bp deploy`, Stripe tiers, an SSE live dashboard, co-located site hosting) have **zero** coverage in README, QUICKSTART, the `bp` cheatsheet, or any user-facing doc. `PHILOSOPHY.md` sells the value proposition in its own words —

> "You run Barkpark locally → you build something → you want to go live → `bp go-live` (or 'Go Live') → pay once → a real production server in seconds."

— but no doc delivers the steps behind that sentence. The buyer reads the promise, types `bp signup`, and hits a wall. **Time-to-first-value for the highest-value persona is effectively infinite.** Per the cross-critic gate, this is the kind of defect that caps the dimension well below Strong regardless of how good the OSS path is.

The secondary insult is the **inverted lead**: the very first substantive block of `README.md` is not a value proposition or an install command — it is a 13-critic, 26-data-cell self-grade table (lines 8–20). A cold reader must scroll past the repo grading *itself* before reaching the install command at line 28. The most typical user, who wants to set something up fast and win within seconds, is handed an internal quality scorecard instead.

---

## 2. Feature-currency gap — Cloud as Exhibit A

Every row below shipped in code and is callable today; none appears on the onboarding surface. Materiality column marks whether the gap *blocks first value* or is a *nice-to-have*.

| Shipped capability | Shipped in | On onboarding surface? | Materiality |
|---|---|---|---|
| `bp signup` (account creation) | #268 | No — absent from README/QUICKSTART/`bp.md`/HANDBOOK | **Blocks** — step zero of the entire Cloud path |
| `bp login` (control-plane auth) | #263 | No | **Blocks** — `requireCloud()` hard-gates launch/go-live/subscribe behind a stored token |
| `bp subscribe` (Stripe checkout, gating go-live) | #270 + #280 | No — pricing only in an ops runbook, and **wrong there** | **Blocks** — commercial gate before any server launches |
| `bp launch` / `bp go-live` | #263, #264, #267, #278 | Named once in PHILOSOPHY narrative; no syntax/flags anywhere | **Blocks** — the headline "live server in seconds" |
| `bp barkparks` (fleet view) | #263 | No | High — first question after launch is "where are my instances?" |
| `bp doctor` (health check) | #264 | Name-dropped in PHILOSOPHY, no syntax | Medium — useful for SETUP's own verify step too |
| Live SSE dashboard (fleet/billing/lifecycle) | #272, #276, branch `f92009c2` | No URL, no description, no screenshot | High — the single-pane view Cloud sells |
| Co-located site hosting (`bp sites` / `bp deploy`) | #274, #275 | No | Medium — a distinct paid capability, fully invisible |
| Subscription pricing (Supporter $69 / Support++ $499 **USD**) | #280 | No user-facing doc; ops runbook still quotes **wrong** euro tiers | **Blocks** — buyer can't find the price |
| Typed JS SDK (`typedClient<TMap>`) | #247, #248 | `js-sdk.md` describes pre-TMap `createClient` only | Medium — JS newcomer loses the headline DX win |

**Exhibit A — `cloud/README.md` (scored 6/100).** It is frozen at the cloud-7 scaffold, **27 PRs stale**, and `git log -- cloud/README.md` showed exactly one commit at audit time (929134f6, the cloud-7 scaffold); this document and the rewrite landed together in PR #307, making it two commits. It still reads:

> "This skeleton brings up just the Ecto Repo and a `BarkparkCloud.Health.health/0` liveness probe; identity (cloud-8) and the instance registry (cloud-9) land in later tasks."

Both of those "later tasks" shipped ~27 PRs ago, alongside auth, Stripe billing, a provisioner worker, and an SSE dashboard. A developer reading this README concludes the control plane is vaporware. Its only action — `mix deps.get && mix ecto.setup && mix run` — brings up the control-plane *process*, which is irrelevant to every end user.

**Exhibit B — stale stamps poison trust on the live path.** `QUICKSTART.md` line 4 still reads:

> "Written 2026-06-10 against the premium-setup branch; commands marked (wizard) ship with that release."

The branch merged weeks ago; **no command in the doc actually carries a `(wizard)` label.** This vestigial provisional stamp makes every shipped command read as unreleased — the first non-heading content a reader meets.

**Exhibit C — the one doc that names Cloud pricing is wrong.** `docs/ops/barkpark-cloud-go-live.md` Gate 4 lists "Free €0 / Starter €69 / Pro €149 / Business €399 / Dedicated €999+" — wrong currency, wrong tier names, wrong count. The shipped model is Supporter $69 / Support++ $499 **USD**. (Note: the *CLI* validator `billingPlans` is itself stale at `starter|pro|business|dedicated`, so any fix must reconcile CLI vs control-plane names before printing a `--plan` example.)

---

## 3. Per-doc scorecard

Sorted worst-first. Scores are the agent overall; the five sub-axes are time-to-value (TTV), currency (CUR), lead-with-value (LEAD), pedagogical-waterfall (PED), path-completeness (PATH).

| Doc | Overall | TTV | CUR | LEAD | PED | PATH | One-line verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| `cloud/README.md` | **6** | 6 | 4 | 4 | 10 | 5 | Frozen scaffold, 27 PRs stale; only action is an irrelevant dev command |
| `docs/INDEX.md` | **11** | 13 | 10 | 8 | 12 | 9 | Flat path list, no "start here"; omits the go-live runbook entirely |
| `js/README.md` | **14** | 8 | 28 | 6 | 15 | 8 | Only command is `pnpm install`; no consumer happy path, no Cloud config |
| `http-api.md` | **23** | 10 | 12 | 30 | 52 | 20 | `$TOKEN` stub with no acquisition path (scoped to data API — fix is lower-sev) |
| `PHILOSOPHY.md` | **24** | 12 | 20 | 42 | 40 | 12 | Sells `bp go-live`; zero executable commands, zero CTA, dead-ends |
| `bp.md` (cheatsheet) | **27** | 20 | 12 | 42 | 50 | 15 | 9 shipped Cloud commands → zero rows; `bp login` gate invisible |
| `tasks.md` | **27** | 10 | 52 | 12 | 35 | 28 | Agent-tier ref; no prereq/auth path (routing failure, not a doc gap) |
| `api/README.md` | **27** | 32 | 12 | 28 | 42 | 18 | Slowest raw-`mix` path, no prereqs, no Cloud link |
| `papers.md` | **28** | 18 | 33 | 30 | 40 | 20 | Every author path dead-ends at `BARKPARK_INGEST_TOKEN`, no mint link |
| `README.md` | **31** | 40 | 13 | 33 | 46 | 20 | Grade table blocks the CTA; live demo is a passive link; no Cloud |
| `web/README.md` | **33** | 18 | 40 | 30 | 50 | 35 | Live-demo URL passive; README/`.env.example` API-default contradiction |
| `QUICKSTART.md` | **34** | 35 | 8 | 48 | 55 | 28 | Provisional stamp; 4 unranked targets; no Cloud path |
| `SETUP.md` | **39** | 44 | 10 | 53 | 60 | 35 | Clean contributor path; routes to QUICKSTART but Cloud dead-ends downstream |
| `sdk/README.md` | **45** | 35 | 33 | 65 | 60 | 42 | Zero-install `npm run example` buried as test tooling; 12/17 blocks undoc'd |
| `tui.md` | **48** | 28 | 60 | 63 | 63 | 38 | Line 4 names wrong binary (`barkpark`) + invalid `bp setup connect` |
| `WINDOWS.md` | **48** | 55 | 18 | 62 | 72 | 38 | Crisp lead; no Cloud (the path that skips all Erlang pain); no duration hint |
| `personal-local.md` | **53** | 50 | 55 | 50 | 63 | 44 | Opens with "Wave 5 of the convergence project" jargon; no verify/forward link |
| `TASK-SYSTEM.md` | **62** | 63 | 54 | 74 | 63 | 52 | Best doc; clean agent waterfall. DB-reset warning lands after the command |

**Average: 32 / 100.** The spread is the story: the agent-runner persona's primary doc scores 62; the Cloud buyer's primary doc scores 6.

---

## 4. The SMART WATERFALL redesign

The current README top-of-funnel order is **internal-metric → feature bullets → install → "four ways in"**. The fastest path (0 commands, open the live Studio) is a passive inline link; the most valuable path (Cloud) is absent; the user meets the repo's self-grade before any value. Friction is unranked and unled.

**Proposed top-of-funnel order, README and a new `docs/setup/CLOUD-QUICKSTART.md`:**

```
1. One-line value proposition          ← what Barkpark is, in a sentence
2. ## Try it now — no install needed   ← CTA, not a link. The 0-step path, framed.
       "Open the live Studio in your browser — no account required."
       → https://api.barkpark.cloud/studio
3. ## Which path is yours?             ← friction-ranked decision tree (see below)
4. ## Cloud — fastest to production    ← the headline persona, FIRST among installs
       bp signup → bp subscribe --plan <tier> → bp go-live --name <name>
5. ## Self-host (local / connect / deploy / provision)  ← ranked, not co-equal
6. ## Point your AI at it              ← the agent-runner win (already strong)
7. ## Codebase quality                 ← the grade table, demoted to the bottom
```

**The decision tree (step 3) replaces the flat "four ways in" / "four targets" menus:**

```
Want a managed server, no local deps?      → Cloud — fastest path (§4)
Already have a server running?             → Connect  (bp setup --target connect)
Provisioning a fresh VPS yourself?         → Deploy / Provision (hcloud/az)
Just want it on this machine for dev?      → Local (needs Elixir + Postgres + libvips)
Driving an AI agent over HTTP?             → Point your AI at it (§6)
```

**Rationale, sub-axis by sub-axis:**

- **time-to-first-value (0.28):** Step 2 surfaces the genuinely fastest route — the zero-install demo — *as a path*, before any install friction is introduced. Step 4 puts the lowest-friction *install* path (Cloud: no Elixir/Postgres/libvips) ahead of Local, instead of burying it third in an unranked table.
- **lead-with-value (0.18):** Steps 1–2 are value + CTA. The grade table moves from line 8 to dead last (step 7) or a collapsed `<details>` / single badge. The user meets what they want before what we measure.
- **pedagogical-waterfall (0.18):** Targets become friction-ranked (step 3), not "four co-equal choices." Each install section places its destructive warning (`--dry-run before --yes`, the `ecto.reset` caution) *inline, before* the command — and the demo-data section moves *before* setup so the user makes an informed choice, not after Verify.
- **currency (0.24):** Step 4 simply *existing* closes the single largest currency gap — ~30 shipped Cloud PRs go from 0% to walkable.
- **path-completeness (0.12):** Every entry in the step-3 tree resolves to a real section; the Cloud buyer no longer dead-ends after reading the PHILOSOPHY promise.

---

## 5. Highest-leverage fixes, ranked

Ranked by (materiality to first value) × (personas unblocked) ÷ (effort). Command syntax below is corrected against source — note the verified-against-code caveats, since several auto-generated fixes in the data carried wrong flags.

1. **Write the Cloud happy path once, link it everywhere.** New `docs/setup/CLOUD-QUICKSTART.md` walking `bp signup --email you@you.com` → `bp subscribe --plan <tier>` → `bp go-live --name <name>`. This is the dead-end fix for the highest-value persona. **Caveat (load-bearing):** `bp launch <provider> --name` and `bp go-live --name` take `--name` *flags*, not bare positionals; `bp doctor` is a one-shot check, not a loop; `bp signup` already stores the session token, so a following `bp login` is redundant for new users; and the CLI `--plan` validator (`billingPlans`, `cloud12_cmd.go:477`) still accepts `starter|pro|business|dedicated` — reconcile with the Supporter/Support++ control-plane names before printing an example.

2. **Add a Cloud section to `docs/cheatsheets/bp.md`.** Nine shipped subcommands, zero rows today. Place it right after `bp setup`, since Cloud is the fastest path: `bp signup`, `bp login`, `bp subscribe`, `bp barkparks`, `bp launch`, `bp go-live`, `bp sites`, `bp deploy`, `bp doctor`. `bp login` is the gate to the entire value proposition — its absence is the maximum-materiality cheatsheet defect.

3. **Demote the README grade table below the fold.** Move the 26-data-cell self-grade to a bottom "Codebase quality" section or a single badge line. The first block after the tagline must be the demo CTA or the install command, not an internal scorecard. Unblocks every persona's lead.

4. **Frame the live demo as a CTA, not a link.** Add `## Try it now — no install needed` immediately after the README tagline with imperative copy. Converts the theoretically-fastest 0-command path from an invisible inline URL into the first presented path.

5. **Rewrite `cloud/README.md` from scaffold to shipped system** (or split internals to `cloud/INTERNALS.md`). Describe auth, registry, Stripe tiers (Supporter $69 / Support++ $499 USD), SSE dashboard, provisioner worker, and the `bp` user flow. Strip all "skeleton / lands in later tasks" language. Fixes the worst single doc (6/100) and the wrong-door for any Cloud investigator.

6. **Strip the provisional stamp from `QUICKSTART.md` line 4.** Remove "against the premium-setup branch" and the phantom `(wizard)` markers. Replace with a "Verified 2026-06-28 against main" datestamp. One-line edit that restores trust in every command in the doc.

7. **Add a friction-ranked decision tree to `QUICKSTART.md` and `docs/INDEX.md`.** Replace the four co-equal targets with the §4 tree; add to INDEX a two-line "Fastest → Cloud · Self-host → QUICKSTART · Contributor → SETUP" router. INDEX also still omits `ops/barkpark-cloud-go-live.md` from its Runbooks line — add it.

8. **Fix the wrong pricing in `docs/ops/barkpark-cloud-go-live.md` Gate 4.** Replace "Free €0 / Starter €69 / Pro €149 / Business €399 / Dedicated €999+" with the shipped USD tiers. This is the *only* doc that quotes Cloud pricing and it is wrong in currency, names, and count.

9. **Fix `tui.md` line 4's two hard errors.** It names the wrong binary ("Launch `barkpark`" — the installer delivers `bp`) and an invalid command (`bp setup connect` — the parser rejects non-`--` args; the correct form is `bp setup --target connect --server URL --token $TOKEN`). A cold user following line 4 literally gets "command not found" or invokes the unrelated `bin/barkpark` server script.

10. **Surface the consumer happy path in `js/README.md`.** Its only command is contributor `pnpm install`. Add `pnpm create barkpark-app my-site` + the 4-command waterfall + the `--hosted-demo` (skip-Docker) flag — all of which already live one level down in the sub-package README — plus a one-line Cloud `apiUrl` config note.

11. **Promote `sdk/README.md`'s zero-install demo.** `npm run example` runs against a mock fetch (two commands, no server) but is buried in "Build and test" as "proves 2 requests total." Move it to a "Try it — no server needed" block right after Install.

12. **Add a verify step + forward link to `personal-local.md`** and replace its opening line ("Wave 5 of the convergence project") with a persona statement. The doc currently starts mid-air (no prereqs stated — though `bin/barkpark` *does* error helpfully, so this is lower-severity than the data's "high" rating) and ends with no `curl localhost:4000/api/schemas` probe and no "what now?" pointer.
