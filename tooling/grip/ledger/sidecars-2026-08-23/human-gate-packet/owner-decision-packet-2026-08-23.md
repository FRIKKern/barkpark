# Owner decision packet — 2026-08-23

Derived from all 2,308 open task rows (paged in full, 5×500 offset queries), 211 human-gate candidates read row by row, every blocker re-derived live today. **768 rows carry lead-close / merge-gate wording — those are the lead's stamps, not your decisions, and are excluded.** What remains collapses to **10 decisions** plus a command appendix.

**Do these three first (time-sensitive):**
1. **WORKER_TOKEN rotation** — PR #13251 merged **today 16:18Z**; the shared fleet secret sits on customer boxes until you rerun the box script and rotate (Appendix B, item 3). The hole is open right now.
2. **Gyldendal credential transmission** — the platform is still handing one team's admin token to another team's server (Decision 5). One psql transaction ends it.
3. **`bp login`** — verified expired again today (`bp cloud status` → "session expired"). One command; it is a precondition inside live-proof criteria across at least six epics (Appendix B, item 1).

---

## Decision 1 — External-account go-live matrix (~22 rows)

**Question: for each line, "discharge now" or "park with recorded status" — one word per line.** Every line has a written recipe in its row; none needs you to compose anything.

| # | Gate | Cost | Rows freed | Recommend |
|---|------|------|-----------|-----------|
| a | Okta/Entra free dev tenant (SSO market-IdP leg) | ~20 min, free | era-hg-okta-live-idp, enterprise-ready-auth (2) | **Now** — the whole enterprise-auth epic waits solely on this |
| b | Hetzner Object Storage bucket + Azure SP (console session) | ~30 min | azh-go-live-human-gate, azure-hetzner-hosting-epic, wbqs-go-dead-exports-… (3) | **Now** — ends an epic that is otherwise complete |
| c | Telegram BotFather bot + Slack app request-URL verify | ~15 min | connectors-p4-live-telegram (final leg), connectors-slack-handshake-live-verify (2) | **Now** — five channels proven offline, zero live; this is the last ingredient |
| d | GitHub App registration (gh-1) + VERCEL_PLATFORM_TOKEN | ~30 min | gh-1, dwb-vercel-token-gate, task-4e4a53b101a97051, dwb-9, dwb-12, dwb-2, jpf-bl-app-auth-clone-provider (7) | **Park, recorded** — Deploy-with-Barkpark is a parked product; minting credentials without a launch intent buys nothing |
| e | Live Stripe keys + pricing/ToS/refund decisions | hours (business decisions) | cloud-console-billing-live-gate, task-2ac1f95237c4a8e5 (W4), bp-login-ux-w2-live-e2e + -verify (provisioned-fleet criteria) (4) | **Park, recorded** — unless you intend to charge this quarter. Note: the two login-UX criteria only need *a* provisioned fleet; a manually comped fleet would discharge them without Stripe |
| f | Cloudflare free account + NS-delegated test domain | ~30 min | cf-live-cutover-human-gate, cf-origin-ca-wire-and-provision (2) | **Park, recorded** |
| g | APNs/FCM push credentials | ~30 min | mob-hg-push-creds (1) | **Park** — already severed to v1.1 by charter ruling D36 |
| h | staging.barkpark.cloud box (Hetzner + DNS + SSH) | ~1 h | staging-w1-box-provision (1) | **Now if cheap for you** — it is the only staging story the repo has |

**If you defer the whole table:** ~22 rows keep presenting as open work and get re-surveyed every wave; recording "parked" on d–g alone stops that churn even with zero credentials minted.

## Decision 2 — One fleet-ops window: host keys, muscle-1, self-update arming, three one-time box acts (~10 rows)

**Question: do you approve one ops window executing the six pre-written recipes below — and for the self-update arm, A (set `BARKPARK_SELF_UPDATE_APPLY=1` on the frozen boxes) or B (freshen each over SSH)?**

Contents, each with its recipe on its row: (1) adjudicate the changed SSH host keys on dooodo 116.203.91.216 and gyl 46.225.61.223 — both were re-provisioned/rebuilt, almost certainly re-images, but only you can confirm no box action you didn't take; reconcile known_hosts only after; (2) muscle-1: dark 19h+ and frozen since 07-26 — decommission it (recommended) or repair its agent; (3) retro-arm the pre-2026-08-14 boxes (the #11662 arming fix is provision-time only); (4) depublish the dead primary + muscle-1 task/paper corpora (arpss-shrink-host-set — the 2026-08-22 anon ruling left exactly this leg open, pending your explicit YES after a dead-host probe); (5) mask the crash-looping legacy `barkpark.service` on guerrilla; (6) one-time cloud compose network recreation on the CP so the pinned 172.18.0.0/16 subnet can attach (brief serving blip, one time).

**Recommendation: yes, arm A** — freshening over SSH (B) has to be repeated every tag; arming ends the class. Blast radii are stated per-box in dr-bl-w7. Decommission muscle-1: it is excluded from every fleet claim already.

**Rows:** dr-bl-w9-ssh-host-keys-changed-on-dooodo-and-gyl, dr-bl-w5-two-boxes-are-unreachable-or-unreporting, dr-bl-w9-muscle-1-is-dark-and-nothing-says-so, dr-bl-w7-bless-v0-2-26-ordering-hazard, task-d1394f9b0eedeaf0, arpss-shrink-host-set, ve-bl-guerrilla-legacy-unit, cch-hg-compose-network-recreation, scaffy-backlog-gyl-instance-update, dr-w5-s4 (live-proof leg).

**If deferred:** no release tag can be cut safely — blessing v0.2.26 before the arming decision would permanently pause 5 of 6 boxes (dr-bl-w7's measured hazard), and every fleet-wide claim stays capped at 4 of 6 boxes.

## Decision 3 — Micro-rulings batch: 8 one-line policy calls (~8 rows)

**Question: accept the recommended default on each line? Strike any you want argued in person.**

| Row | Ruling asked | Recommended default |
|---|---|---|
| felix-w28-bl-checkout-tighten-adjudication | may a write-only token force-release another editor's media checkout? | **No — tighten to admin** (the fold is copy-paste, not design; siblings are pure admin) |
| gfr-bl-repeatable-false-enforcement-ruling | repeated non-repeatable `bp` flag | **Blanket refusal, exit 2** (proven safe in-repo; `repeatable:false` appears exactly once) |
| arpss-stored-share-registry-ruling | StoredShare index/create/delete cross-tenant-reachable by any workspace admin | **Scope to actor workspace** (index leaks every tenant's exposure config today) |
| arpss-classa-lowsev-hygiene-rulings | 3 raw-echo sites: unauth health DB reason / pre-auth SAML detail / admin-gated Postgres msg | **Redact (1) and (2); accept (3) with a site comment** — (3) is admin-gated |
| dwb-cancel-blocking-semantics | cancelled deployment: frees its slot or abandons dependents | **Cancel-frees** (cancel-abandons wedges dependents forever — the found defect) |
| task-ea8cae3258ea4bd3 | revoke-by-email crosses workspaces; PR #12947 narrowed pending your ruling | **Workspace-scope the revoke** (constraint in the query layer so every caller inherits it) |
| ecd-bl-charter-corpus-hygiene | prod IPs + customer emails in 92 public tracked charters | **Scrub-forward** (new charters gated; no history rewrite) |
| pdf-bl-gui-workstation-spike | GUI workstation Layer 4 thesis | **Declare dead** (Anthropic: Computer Use unavailable on Linux — the premise is gone) |

**If deferred:** each row keeps blocking one shipped-but-narrowed capability or one security tightening; none is self-resolving.

## Decision 4 — Required-context governance: approve the flip packet (~7 rows)

**Question: do you sign off the spec-gate becoming the fifth required context (the operator PUT), and Compose smoke being registered once its two settled-head renders exist?**

Branch protection is live today (verified: 4 contexts — Elixir gate, PR references an active task, Cloud gate, Console gate — enforce_admins true). The flip packet exists (cch-w37) with a costed sequence; one packet defect must land first: its sweep command still omits `--require-new-context` (cch-w39-fu, agent work). Your part is one recorded sign-off sentence before the PUT — the rows explicitly refuse to let an agent run `required-checks-apply.sh --confirm`. Same sitting: record the retroactive sign-off sentence hg-bl-branch-protection still owes (protection was enabled with the shim proven; only the recorded-consent criterion is open), and rule on doc-gates promotion (recommend: **defer until the tripwires are wired** — the sequencing prerequisite its own row names).

**Rows:** cch-w37-bl-register-spec-gate-human-gate, cch-w39-fu-flip-packet-passes-require-new-context, cgsi-bl-doc-gates-requirable, shb-bl-register-compose-smoke, shb-w1-s6-compose-smoke (final legs), hg-bl-branch-protection-required-checks, cgsi-s8-wire-tripwires (lead dispatches after).

**If deferred:** the spec gate stays advisory — ledger-integrity claims in PR bodies remain unenforced — and the two registration rows keep resurfacing as ready work every wave.

## Decision 5 — Gyldendal remediation session: one YES covers three acts (~6 rows) — **p0, do first**

**Question: do you approve one operator session on the gyldendal tenancy that (a) runs the one-transaction stop of the live cross-tenant credential transmission, (b) executes the ruled private-flip of task+paper on that host, (c) redeploys the box with PHX_HOST/PHX_SCHEME + BARKPARK_CLOUD_URL backfill?**

(a) is measured, live, p0: row b1259514 (team `yo`) holds `gyldendal.barkpark.cloud` in `url`, DNS points at team Gyldendal's box, and the platform transmits `yo`'s admin token to it. The corrected packet's ordering is settled: **NULL `admin_token_encrypted` FIRST, url second, one BEGIN/COMMIT** (the incumbent w25 row's order is wrong — its own header says so). (b) was already ruled by you on 2026-08-22 (flip private, scoped to gyldendal); the child migration just needs the explicit YES the packet requires for customer-host actions, with a fresh census first (needs `bp login`). (c) is Past-Mistake-11 hygiene: the box leaks `http://localhost:4000` as its base_url.

**Recommendation: yes to all three, in that order, one session.** They are the same box, same credential set, and (a) is the only live security leak in the whole packet.

**Rows:** dr-w25-hg-gyldendal-operator-stops-the-transmission, dr-w24-bl-gyldendal-live-cross-tenant-escalation, dr-w28-bl-gyldendal-corrected-criterion-still-unsatisfiable, arpss-flip-private-migration (gyldendal arm), onb-backlog-cloud-url-fleet-backfill (human-gate leg), task-ce64a2c17fc0efab.

**If deferred:** a customer team's admin credential keeps being transmitted to another team's server on every sweep cycle, and both teams' eventual disclosure gets worse with each day of unrecoverable gap.

## Decision 6 — Human-reachable operator principal: set PLATFORM_ADMIN_EMAILS? (~6 rows)

**Question: yes/no — set `PLATFORM_ADMIN_EMAILS=<your registered Cloud email>` on the prod control plane, and rule that human-facing fleet signals (rollout brake, autoupdate halt/resume, operator deploy census) get a human-reachable read path?**

Today the operator census 403s every human account, the fleet kill-switch is readable/drivable only by the machine WORKER_TOKEN, and no automation credential can compute a site owner's deploy number. One env line + container recreate flips the census; the principal ruling (one sentence: "human-facing signals must be reachable by a human credential") unblocks the other four rows' builders.

**Recommendation: yes.** The counter-argument (keeping the platform surface dark) is not availing anything — the routes exist; they are just unreachable by you.

**Rows:** dr-w16-bl-platform-admin-emails-human-gate, dr-w8-s4-census-reaches-a-human (OPS leg), dr-w30-bl-operator-census-403-blocks-the-fleet-ranking, isu-backlog-operator-principal, dr-w19-rollout-brake-is-machine-only, dr-w14-bl-pat-cannot-read-the-owners-number.

**If deferred:** the deploy-reliability epic's crown stays readable only via SSH+psql, and every fleet-wide number stays labeled "SQL-derived, not an instrument reading."

## Decision 7 — One hands-on session with your hardware and eyes (~6 rows)

**Question: will you schedule one ~2-hour sitting covering the five written packets that need a physical human?**

Contents: mob-hg-device-boot (Xcode + iPhone free-provisioning; "no iPhone exists" is an accepted recorded outcome), mob-hg-member-seat (invite a second real account, `bp login` as plain member, run the 13-leg smoke — turnkey, the machine half merged), pdd-t12-a11y-eyeball (VoiceOver + keyboard pass on the canvas), studio-ui-premium criterion 4 (your re-verdict on Studio quality — the evidence pack sup-w4 feeds it), ecd-bl-second-env-launch-proof (launch one epic wave from a second machine per the runbook).

**Recommendation: yes — these are the only rows in the repo that structurally cannot be delegated**, and three of them close whole epics' last criteria (mobile epic bucket C, studio-ui-premium, epic-cycle-portability).

**If deferred:** the mobile epic root and studio-ui-premium stay permanently 1-criterion-open, which the false-done audits then re-litigate every cycle.

## Decision 8 — Crown reader principal: A or B (5 rows)

**Question: for reading /v1/deliveries (the deploy crown): (A) CROWN_API_TOKEN — a read-PAT minted by you, wired as an Actions secret — is canonical forever, or (B) widen the route to the worker principal (requires a cross-epic cession from cloud-console-hardening)?**

**Recommendation: A.** It keeps WORKER_TOKEN as the only thing between the internet and the write path (the standing security argument), needs no router change inside another epic's fence, and the reconciler already supports it. Mint the PAT, add secret `CROWN_API_TOKEN`, and the lead closes the B-shaped rows citing this ruling.

**Rows:** dr-w30-bl-deliveries-route-widening-is-inside-cch-fence, dr-w29-bl-crown-http-read-path-unreachable-to-the-worker-principal, task-3e0e34153a7ba0a4, task-e2acb66e9ed0da09 (closed-by-ruling if A), dr-w28-rv-crown-reconcile-ci-read-path.

**If deferred:** the crown reconciler keeps silently falling back to SSH+psql, which its own rows name as the failure mode that hides route breakage.

## Decision 9 — Approve four replacement criteria (4 rows, unsatisfiable as written)

**Question: approve these four rewords verbatim? Each replaces a criterion that is impossible or dishonest to satisfy as written.**

1. **dr-w14-s6-followup-site-deployments-envelope-unread** (asks a test to prove `publish_clock` populates; the key was deleted from the wire by #11083, −802 lines; the named struct + cursor walker already shipped in #13056):
   > "The site-deployments decode uses a NAMED struct carrying next_cursor alongside Deployments (#13056), and deliberately declares NO publish_clock field — the key was subtracted by #11083's deletion law and the census register row (key publish_clock, disposition :deleted) is the record. Evidence: the struct and the register row."
   After the reword this row is fully paid — lead closes it.
2. **task-509410df73d3e8ca** (asks to register the path-filtered sheet-grid-js.yml as gated — a required context that only fires on some paths deadlocks every non-matching PR):
   > "The sheet-grid harness rides an ALWAYS-REPORTING required context: api/assets/sheet-grid/** is added to ELIXIR_TEST_ONLY_PATHS so the already-required Elixir gate runs it, and sheet-grid-js.yml itself stays advisory (or gains a path-filter skip-shim before any registration). A bare registration of the path-filtered workflow is refused — it deadlocks main."
3. **important-paper-quality-wave-2-2026-07-31** (asks 30 terminal outcomes recorded through the typed-assignment system, which only counts self-assigned work — recording direct repairs through it fabricates receipts):
   > "Each of the 30 frozen revisions carries exactly one terminal outcome (shipped/excluded/stalled) in the wave Paper's reconciliation table, derived from a corpus read-back — not from typed-assignment receipts — summing to 30 with zero unaccounted; the debrief states that direct repairs were performed outside the typed-fleet system, so no per-unit assignment receipts exist and none are fabricated."
4. **tgw9-s3-criteria-adjudicated** (stamping the epic root requires claiming it, which removes it from the ready pool and violates the seal's own clause (b') — payable only inside a lead close window):
   > "IN THE LEAD'S CLOSE WINDOW ONLY: the root's four criteria are stamped with polarity-declared evidence adjudicated by seal.mjs, with clause (b') evaluated and recorded BEFORE the claim is taken; the claim-then-stamp-then-close sequence is exempt from the ready-pool clause because clause (c) already requires the root to close last, which is this same window."

**If deferred:** four rows sit permanently open-and-unpayable, feeding every future false-done audit with noise.

## Decision 10 — Guerrilla capacity ruling: accept "remediated, working as designed"? (3 rows)

**Question: do you (a) read the two published ruling Papers (lever packet + seal ruling), return a disposition — "working as designed, no demand cut" is a legitimate answer and closes the row — and (b) approve the one-variable AUTODEPLOY_DEBOUNCE_S experiment for a pinned window?**

The strongest argument for a cut is already gone: the ≥2-concurrent-build regime was closed by a shipped fix (#9827: search p50 8,314ms → 781ms, deploy success 56% → 98.6%). The remaining question is a model with no measurement — the debounce experiment settles it for one env var and one pinned window.

**Recommendation: accept "remediated / working as designed", approve the experiment.**

**Rows:** dr-w21-hg-demand-cut-packet-regime-remediated, dr-w20-bl-debounce-window-live-experiment, dr-w23-s7-lever-and-seal-rulings (owner-close criterion).

**If deferred:** nothing burns — but the epic's seal criteria stay owner-unread, and the wind-down cannot state its disposition.

---

## Appendix A — Already unblocked: no longer needs you

Re-derived live today; the gate each row cites has cleared. These need a **lead** sweep, not an owner.

| Row | Cited blocker | Reality today |
|---|---|---|
| cchi-w26-bl-8500-decision-packet | "decision: merge #8500 or name a reason" | **#8500 MERGED 2026-08-02** — 21 days ago. Only the post-merge orphan re-count bookkeeping remains (agent work) |
| dr-w15-s5-capability-reaches-bp-cloud-status | "BLOCKED — dep PR #10401 is CONFLICTING/DIRTY, wave 17 does not dispatch this" | **#10401 MERGED 2026-08-07** — 16 days ago. Dispatchable now |
| dr-w14-s6-followup-… | criterion 1 unpayable (see Decision 9) | criteria 2+3 already paid by #13056; reword → close |
| hg-bl-branch-protection-required-checks | "owner sign-off before protection is enabled" | **Protection is live** (4 contexts, enforce_admins, verified today); shim proven, non-matching PR merged. Only the recorded sign-off sentence is owed (fold into Decision 4) |
| arpss-anon-projection-gate | "Owner has ruled outcome B" | **Outcome A was ruled for guerrilla on 2026-08-22** — this trigger can never fire; lead cancels citing the ruling (row body itself says a B-revisit trigger can be re-filed if customer content ever lands) |
| dr-w27-instance-serving-since-durable | argues from a source | premise refuted on the record (D465's actual source is the marker-file mtime); superseded per dr-w28-bl — lead rewrites-or-closes |
| pdf-bl-anon-read-exposure | (was the biggest pending ruling) | **Already closed 2026-08-22 with the per-host ruling** — several agent surveys still cite it as pending; it is not |

## Appendix B — Credential actions, ranked by rows freed

Literal commands; each is minutes.

1. **`bp login`** — session verified expired today (`bp cloud status` → auth error). Frees the live-verification legs across the fleet epics (site-spawner live proofs, member-seat smoke, gyl checks, fresh anon census for Decision 5b, fleet status reads…); ~15 rows name it directly, dozens more carry a live-proof criterion that starts with it.
   ```
   bp login
   bp cloud status   # confirm: no auth error
   ```
2. **ANTHROPIC_API_KEY** — verified absent today (`bp secret ls`: only jarl-admin-token, ingest_token). Frees ~12 rows: ctx-b5-provision-count-tokens-key, ctx-s5-count-tokens, pe-w7-hg-anthropic-key, pe-bl-cold-agent-run → pe-w7-epic-seal → Paper Excellence root, tob-w2-llm-judge (cache-read proof), connectors-hg-live-isolated-cloud-turn, connectors-hg-live-cloud-multiturn, connectors-live-credential-embed-reconfirm, connectors-egress-live-enforcement-reconfirm, task-fe78ccb664308739.
   ```
   bp secret set anthropic_api_key <sk-ant-...> --yes
   bp secret get anthropic_api_key   # read-back
   ```
3. **WORKER_TOKEN rotation — TIME-SENSITIVE.** #13251 merged today: `/v1/builder/*` moved off the shared fleet secret; CP auto-deployed on merge; **the hole stays open until the box script reruns and the token rotates** — field boxes still run the old install. Frees jpf-bl-box-credential-hygiene, jpf-w1-siteplane-chain's sequencing, and defuses dr-w24-bl-internal-write-route-is-publicly-reachable.
   ```
   # on the jarl box (91.98.139.58) and any box that ran the old installer:
   bash deploy/site-runtime-install.sh          # rerun, now worker-preference-free
   # on the CP: rotate WORKER_TOKEN in cloud/.env, recreate the container,
   # then confirm holder inventory: off-box provisioner + CP ops only, no customer box
   ```
4. **Publish @barkpark/react@1.0.0-preview.2** — npm verified today: only preview.0/preview.1 exist. Frees stw1-react-preview-publish, rpu-backlog-publish-react-canonical, task-2abbac8d7975050c (disposition leg), and lets jdf-w1 drop its vendored copy. Sequencing: pds-w49-npm-publish-preflight (whoami preflight + publish-set assertion) should merge first; NPM_TOKEN validity is UNPROVEN (108 days old) — the preflight is what tells you honestly.
   ```
   gh workflow run release.yml -f dist_tag=preview -f dry_run=false
   npm view @barkpark/react versions   # read-back: preview.2 present
   ```
5. **BARKPARK_SEED_TOKEN** — mint a write ApiToken on guerrilla (kind api, permissions ["write"], with expiry, label scaffy-seed-ci), install as repo secret. Frees scaffy-backlog-seed-token-mint and task-b3c622daa4087f52 (the drift gate that has never once been green — 6 consecutive reds).
6. **BARKPARK_TASK_TOKEN** — repo secret for pr-task-gate's authenticated ledger fetch (arpss-pr-task-gate-token-plumbing's one human criterion; the sole future unblocker for any guerrilla visibility flip).
7. **Subscribe to FRIKKern/barkpark** — verified today: viewerSubscription = UNSUBSCRIBED. Until clicked, every filed CI alarm reaches no inbox. Frees dr-w33-hg-owner-subscribes-to-the-repository.
   ```
   gh api -X PUT repos/FRIKKern/barkpark/subscription -f subscribed=true
   ```
8. **GitHub App: accept the pull_request event + Pull requests: Read** on the Barkpark bridge App installation (github.com → Settings → Installations). The merge-gate autostamp bridge has never fired in 29 days because the App is subscribed to `issues` only. Frees task-616789a3afe59364.
9. **BREAKGLASS_TOKEN swap** — mint a fine-grained PAT (FRIKKern/barkpark, Administration:read only, expiry recorded in docs/ops/break-glass-log.md), replace the broad gh OAuth token in the repo secret. Frees hgw5-bl-breakglass-fine-grained-pat.
10. **BARKPARK_CLOUD_READ_TOKEN** — a CP read credential as an Actions secret so the webhook-fanout watch runs scheduled instead of by hand. Frees dr-w19-hg-cloud-control-plane-read-token.
11. **PLATFORM_ADMIN_EMAILS** — the command half of Decision 6: add the line to /opt/barkpark/cloud/.env on the CP, recreate the container, then `bp cloud deployments` should print a number instead of a refusal.
