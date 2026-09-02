# Order-chains (each chain = ONE shared reason; members listed with FULL ids)

## seal-predicate-fencing — 9 members
dr-w23-bl-seal-predicate-needs-epic-keyed-registers
dr-w23-bl-roster-500-headroom-is-94-rows
dr-bl-seal-predicate-epic-keyed-register
dr-w24-bl-seal-predicate-needs-an-epic-fence-and-a-paged-roster
dr-w25-bl-seal-registers-are-epic-unfenced
dr-w25-bl-seal-clause-a-is-one-level-deep
dr-w26-bl-seal-clause-a-depth-and-ladder-label
dr-w27-bl-seal-clause-a-is-one-hop-and-bc-score-a-foreign-register
dr-w30-bl-seal-clause-a-orphans-doubled-to-161
SHARED REASON: one defect re-derived across waves 23-30 — cloud/priv/static/__preview__/seal-predicate.mjs's
KNOWN_DEFECTS (:281) and PERMANENT_HUMAN_GATES (:257) are flat module constants with no epic fence (--epic
parameterizes clause (a) ONLY), fetchRoster is one non-recursive filter[parent_id] hop with ROSTER_PAGE_LIMIT=500
and a ROSTER-TRUNCATED throw. Every generation restates the same mutation-proved facts; the file is FENCED to
cloud-console-hardening by charter D402, so no dr-* builder may ship the fix. The LATEST generation
(dr-w27-bl-seal-clause-a-is-one-hop-and-bc-score-a-foreign-register + the w30 orphan measurement) is the live
statement; the earlier seven are its ancestors.
VERIFIED ON origin/main 2026-08-23: the ROSTER leg is ALREADY-DONE — commit a1d27149e7 (#11438) added
ROSTER_MAX_PAGES pagination (ROSTER_PAGE_LIMIT now :457), so ROSTER-TRUNCATED-at-500 claims in
dr-w23-bl-roster-500-headroom-is-94-rows and the w24/w27 generations are STALE. The REGISTER leg is still true
in structure: PERMANENT_HUMAN_GATES (:257) and KNOWN_DEFECTS (:281) remain flat module constants with no epic
key and no UNREGISTERED-EPIC refusal (grep for epicKey/UNREGISTERED-EPIC: 0 hits) — though their CONTENT was
re-pointed at gr-* rows, so the six-CCH-D* specifics every generation quotes are also stale.
Measurement: `git grep -n "PERMANENT_HUMAN_GATES\|KNOWN_DEFECTS\|ROSTER_PAGE_LIMIT" origin/main -- cloud/priv/static/__preview__/seal-predicate.mjs` -> :257/:281/:457; `git log -S "ROSTER_MAX_PAGES" --oneline` -> a1d27149e7.

## give-it-a-reader — 9 members (collapse row EXISTS and is a member)
dr-w25-bl-reader-tasks-disposed   <- the collapse row: D442/D445 dispositions RULED but NOT YET APPLIED
dr-w23-s3-timeline-reaches-a-human   (D445: SPLIT-AND-SUPERSEDED, crits 1-3 = dr-w25-s8's deploy.yml writer)
dr-w24-s8-timeline-reaches-a-human   (criterion 7 STRUCK by D445)
dr-w14-s6-followup-site-deployments-envelope-unread   (D442: LAW WINS)
dr-w11-followup-publish-instant-has-no-reader   (D442: TASK WINS)
dr-w12-bl-build-clock-has-no-reader   (D442: TASK WINS on console timestamps)
dr-w12-s6-followup-serialize-deferral-columns   (D442: co-scoped with #10811)
dr-w22-bl-publish-clock-has-no-go-or-console-reader
dr-w12-bl-publish-clock-operator-surface   (also rooted in the census-403 human gate)
SHARED REASON: each row records a producer-side instrument that landed with NO reader (content_publishes,
build clock, deferral columns, publish_clock, site-deployments envelope, merge timeline). Charter D442/D445
already RULED the split dispositions in dr-w25-bl-reader-tasks-disposed — executing that one row's rulings
disposes the whole chain. Measurement: dr-w25-bl-reader-tasks-disposed.description names the members and states
"RULED but NOT YET APPLIED".

## spa-ladder — 8 members (collapse row EXISTS: dr-w19-bl-collapse-the-four-spa-ladder-rows)
dr-w5-followup-spa-ladder-two-tier
dr-bl-w5-console-ladder-stays-nine-rungs
dr-bl-w6-console-ladder-handover-collapse-three-rows   <- itself an earlier collapse attempt
dr-w10-bl-spa-ladder-handover-to-cch
dr-w15-bl-console-ladder-is-nine-rungs
dr-w18-bl-console-and-harness-ladder-drift
dr-bl-attention-ladder-double-pin
dr-w19-bl-collapse-the-four-spa-ladder-rows   <- the surviving collapse row
SHARED REASON: one fact re-filed since wave 5 — cloud/priv/static/app.js ATTENTION_RANK is NINE rungs (no
strained, no filling) while Go/fixture ladder is ELEVEN, and __app.test.mjs pins the nine-rung enum without ever
reading __fixtures__/attention_order.json. Every generation also states WHY it could not be fixed here:
cloud/priv/static/** is fenced/ceded to cloud-console-hardening (charters D31/D68/D94/D254). The collapse row
dr-w19-bl-collapse-the-four-spa-ladder-rows already prescribes: ONE survivor carrying the corrected integers,
others cancelled naming the survivor. Measurement: `git grep -n "strained" origin/main -- cloud/priv/static/app.js`
(the render arm's absence is the shared defect).

## census-403 — 5 members; ROOT IS A HUMAN GATE
dr-bl-w5-census-is-dark-to-every-human
dr-bl-w8-census-403-cannot-say-the-list-is-empty
dr-w13-bl-census-omits-delivery-so-403-fix-buys-nothing
dr-w16-bl-platform-admin-emails-human-gate   <- ROOT (human packet)
dr-w30-bl-operator-census-403-blocks-the-fleet-ranking
SHARED REASON: GET /v1/operator/deploy-ledger/census 403s for EVERY credential because PLATFORM_ADMIN_EMAILS is
UNSET in prod's cloud-control .env — measured on GREEN (D165), re-measured on BLUE (D262), unchanged through
wave 30. Four rows are downstream restatements/legs; the ROOT is the operator setting the env var on the box —
BLOCKED-HUMAN. No repo commit can close any of them.

## stale-installed-binary — 3 members; ROOT IS A HUMAN GATE
dr-bl-w6-cut-and-bless-v0-2-26   <- ROOT (cut and bless release v0.2.26)
dr-w10-bl-cli-release-channel-is-stale
dr-w30-bl-installed-bp-lacks-wave-29s-readers
SHARED REASON: no release has been cut since the readers/columns landed on main, so every installed bp
(f59aaf717 / 0789ab90a builds) lacks them; SelfUpdate.Checker only moves on a new semver tag. One human act —
cut+bless the release — retires all three. Measurement: installed `bp cloud deployments` exits 2 "unknown cloud
command" while internal/cli/hetzner_cmd.go:123 registers it on origin/main.

## gyldendal — 6 members (4 + HG + the CCH-fence leg); ROOT IS A LIVE PROD INCIDENT + HUMAN GATE
dr-w24-bl-gyldendal-live-cross-tenant-escalation
dr-w25-hg-gyldendal-operator-stops-the-transmission   <- HG; carries a written 🔴 STOP (superseded packet trap)
dr-w25-bl-gyldendal-taker-is-also-a-ghost
dr-w27-bl-gyldendal-packet-409s-on-the-dedup-wall
dr-w28-bl-gyldendal-corrected-criterion-still-unsatisfiable
dr-w29-bl-remediated-tenant-is-provable-only-as-an-absence
SHARED REASON: one live incident — prod hands team `yo`'s admin token to team Gyldendal's server (rows
b1259514/f5e1392e) — whose remediation is an OPERATOR action on the live control plane. The paperwork itself is
wedged: the corrected packet 409s on the E4 dedup wall, the incumbent HG criterion is unsatisfiable
(:not_live is not an @unavailable_reason), and the proof-of-remediation can only be an absence. Root disposition:
BLOCKED-HUMAN (operator on prod) + one paperwork act to re-cut the packet past the wall.

## paper-rail-422 — 5 members
dr-w23-bl-paper-view-422-on-tiptap-body
dr-w24-bl-paper-writer-accepts-unreadable-bodies
dr-w24-bl-paper-blocks-corpus-backfill
dr-w30-bl-paper-ingest-limits-500-with-no-detail
dr-w35-bl-wave-papers-422-semantic-empty
SHARED REASON: one contract hole in the Bulldocs paper rail — the write path accepts TipTap bodies no public
reader can render, so reads 422 (semantic_empty) while writes pass silently; the ingest adds two undocumented
hard caps that 500 without detail. Wave 23 found it, wave 24 named producer fix + backfill, wave 30 and 35
re-measured it (41-paper backfill population; wave 32/33/34 Papers 422 on all three reader edges). One
producer-side validating contract + one backfill closes the family.

## zero-criteria — 5 members
dr-w10-bl-fifteen-children-have-zero-criteria
dr-w11-bl-zero-criteria-census-has-no-caller
dr-w12-bl-zero-criteria-ratchet-tokenfree
dr-w19-bl-zero-criteria-rows-need-a-refusal
dr-w33-bl-task-create-refuses-criteria-less-rows
SHARED REASON: the same defect measured five times (15 rows w10 -> 7 rows w19 -> regressed again by w33):
criteria-less children score vacuously complete, and every landed countermeasure was an instrument with no
caller (census script nothing runs; ratchet that shells bp off-PATH and reds forever). The terminal generation
— a REFUSAL in bp task create on criteria-less rows — is the only cure all five name; the earlier four are its
ancestors.

## deferral-cause-null — 3 members
dr-w15-bl-deferral-cause-null-audit
dr-w27-bl-deferral-cause-is-null-on-59-percent
dr-w28-bl-deferral-cause-title-retitle-and-59-percent
SHARED REASON: the SAME closed population — 1,818 deferred rows with deferral_cause NULL (max inserted_at
2026-08-07 10:01:54, before the vocabulary landed) — measured three times. w28 already rules the number can
only get more wrong because the population is CLOSED (pre-vocabulary residue). One disposition (declare the
1,818 pre-vocabulary residue, retitle/absorb) settles all three.

## digest-audience — 5 members (incl. one HG); SHARES THE census-403 ROOT
dr-w19-fleet-digest-audience-still-empty
dr-w26-bl-fleet-digest-audience-still-empty-escalated   (a five-site 4h55m outage mailed only the tenant)
dr-w33-bl-digest-audience-keyed-on-instances-not-sites
dr-w35-bl-digest-blind-to-never-covered-sites
dr-w33-hg-owner-subscribes-to-the-repository   <- HG (gh subscription; no code can do it)
SHARED REASON: the fleet digest/alarm pipeline has NO reachable audience: recipients resolve through
platform_admin_emails/0 (empty — the same PLATFORM_ADMIN_EMAILS human gate as census-403), the audience is
keyed on instance ownership so site-owning teams are mailed by nobody, and the repo owner is UNSUBSCRIBED from
FRIKKern/barkpark so filed alarms page no inbox. Root disposition: the two human acts (set the env var;
subscribe) plus one audience-derivation fix.
VERIFIED 2026-08-23: notifications.ex:444 still derives audience via Enum.group_by(barkparks, & &1.team_id)
(instance-keyed — w33 row still true). Commit c0b556aa3b (#11480) later taught the digest
never_covered_by_environment COUNTS, but digest_email.ex has 0 hits for never_covered_sites — the NAMED site
list deploy_ledger.ex:1674 emits is still dropped, so the w35 member's exact ask remains open.

## crown-read-path — 3 members
dr-w28-rv-crown-reconcile-ci-read-path-has-never-executed
dr-w29-bl-crown-http-read-path-unreachable-to-the-worker-principal
dr-w33-bl-crown-schedule-has-never-run-the-reconcile
SHARED REASON: three generations of one fact — the crown reconciler's non-human read path has never worked:
never executed (w28), answers 401 to the WORKER principal forcing the postgres-container fallback (w29), and
the scheduled trigger has run exactly twice, both failed (w33). The w33 statement subsumes the earlier two;
verification needs live gh runs + CP_HOST ssh (BLOCKED-HUMAN to verify, code fix real).

## serving-since — 5 members (contains an intra-chain refutation)
dr-w20-bl-instance-target-has-no-serving-sha
dr-w21-bl-merge-to-serving-lag-has-no-recorder
dr-w27-instance-serving-since-durable   <- REFUTED BY dr-w28 member below (argues for a source D465 rejected)
dr-w28-bl-instance-serving-since-task-premise-refuted
dr-w29-bl-serving-since-has-no-basis-column
SHARED REASON: one evolving question — where does a durable, provenance-honest serving_since come from for both
legs. w28 positively refutes w27's premise (its proposed source was already rejected by D465 and sits on a
fenced file); w29's basis-column row is the live, satisfiable statement. Ancestors are superseded by
dr-w29-bl-serving-since-has-no-basis-column.

## abandonment-predicate — 5 members
dr-bl-w9-abandoned-rate-pending-a-real-chain-key   (recorded REFUSAL: no honest chain key existed)
dr-w13-bl-abandonment-splits-off-the-flood
dr-w28-rv-abandonment-predicate-replaces-the-prose-regex
dr-w32-s5-prod-abandonment-predicate-reading   (needs the PROD backfill reading — live probe)
dr-w34-bl-abandonment-predicate-is-gte-not-equals
SHARED REASON: one lineage — "the fleet gave up on this publish" went from unmeasurable (w9 refusal) to prose
regex (w13) to structured deferral_depth/bound/cause columns (w28-s6 landed them) to the corrected predicate
(w34: >= not =, and NOT deferral_cause IS NOT NULL which reads 1,665). The w34 row states the current truth and
supersedes the lineage; w32-s5's remaining ask is a prod reading (BLOCKED-HUMAN leg).

## path-escape-floor — 5 members
dr-w8-rev-escape-harness-learns-the-refusal-sentence   (console-side twin)
dr-w16-bl-escape-census-is-existence-filtered
dr-w16-bl-widen-escape-fixture-then-raise-floor
dr-w17-bl-escape-floor-cannot-lose-in-either-direction
dr-w26-s4-followup-widen-escape-harness
SHARED REASON: one instrument family — scripts/cloud-path-escape-check.sh (+ console twin) — whose floor and
fixture cannot lose honestly: existence-filtered census loses renamed producers silently, CLOUD_ESCAPE_MIN sits
AT population with zero headroom and a misdiagnosing error string, the fixture tree caps covered reads, and
case pins (exact-entry semantics, one aggregator sentence) red on the first legitimate change. One harness
rework covers all five.

## payload-census-floor — 4 members
dr-w18-bl-route-added-keys-escape-the-census
dr-w32-bl-census-helper-emit-escapes-both-gates
dr-w23-s4-followup-census-floor-coupling
dr-w27-bl-register-floor-lags-the-register
SHARED REASON: the payload key-set census + reader-less-instrument register gates only see keys emitted on the
canonical serializer path and their floors lag their registers: route-level Map.put keys and private-helper
emits are invisible to BOTH censuses (mutation-proved, D550), @go_tag_floor/@register_floor carry slack so a
deletion reds nothing. One gate rework (walk emission chokepoints, auto-derive floors) covers all four.

## Chains previously collapsed elsewhere (EXCLUDED per lead): the five-generation ledger-sweep chain and the
## 13-row pr-10129 chain — not re-derived here.
