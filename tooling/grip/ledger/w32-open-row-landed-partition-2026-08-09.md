<!-- doc-tier: cold | canonical-for: w32-open-row-landed-partition | budget: 9000tok -->
# w32 — the deploy-reliability GOAL's open rows are 38% already shipped

> HISTORICAL RECORD (2026-08-09) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

`task-fb4fb869490b4213` · origin/main `e913de82c881` · 2026-08-09T18:20:13Z

**child_count 280 · open 199 · done 73 · cancelled 8.** The wind-down cannot cite
"199 open children" as remaining work: only 116 of them are.

## Partition

| bucket | rows | what it means |
|---|---|---|
| LANDED_BUT_OPEN | 76 | a merged PR claims it on a `Task:` line and its mergeCommit IS an ancestor of main — shipped, ledger never closed |
| DUPLICATE / SHADOW | 6 | unpublished `drafts.*` row shadowing another row — never work, ledger litter |
| ZOMBIE (re-filed) | 1 | the slice was re-filed under a new slug in a later wave and THAT row landed |
| **GENUINELY OPEN** | **116** | no merged ancestor commit claims it |
| TOTAL | 199 | |

Of the 116 genuinely open, **89 sit at 0/N** (never started) and 18 at exactly N−1.
Of the 76 landed-but-open, **52 sit at exactly N−1** — the disclosure disease: the work
shipped, one criterion stayed unstamped, and the row reads open forever.

## Method — and the three ways the naive recipe lied

| correction | naive answer | corrected |
|---|---|---|
| `gh pr list --search <slug>` returns fuzzy token matches | 103 landed | filter to bodies literally containing the slug |
| a body MENTIONING a slug usually says it is NOT done (`FOLLOW-UP FILED:`, `pulled out`, `NOT DONE HERE`) | 103 landed | require a standalone `Task: <slug>` line → 76 |
| `gh pr list --search` MISSES PRs — it never returned #11075, which landed `dr-w25-s4` | 76 | + scan main's own commit messages → 76 |

Every landed row is confirmed with `git merge-base --is-ancestor <mergeCommit.oid> origin/main`.
The branch-head test is never used: this repo squash-merges (`git rev-list --parents -n1 origin/main` shows one parent).

## LANDED_BUT_OPEN — reclaim these as tasks (D520: lead prose has a 0%% execution rate)

| doc_id | evidence | ref | criteria |
|---|---|---|---|
| `dr-w1-s1-graph-visibility-bound-readmit` | pr-body | #9613 | 6/8 |
| `dr-w1-s5-swallow-records-upstream-status` | pr-body | #9617 | 7/10 |
| `dr-w13-s5-cli-reads-columns-and-names-its-window` | pr-body | #10350 | 12/15 |
| `dr-w13-s6-publish-clock-first-caller` | pr-body | #10351 | 13/15 |
| `dr-w18-s1-census-reader-reaches-the-team-door` | pr-body | #10518 | 8/9 |
| `dr-w18-s3-push-rail-can-lose` | pr-body | #10520 | 6/8 |
| `dr-w19-s3-site-deploy-route-stops-lying` | pr-body | #10563 | 7/8 |
| `dr-w19-s4-webhook-fanout-live-row-guard` | pr-body | #10564 | 8/9 |
| `dr-w19-s5-digest-audience-and-brake-ruling` | pr-body | #10610 | 9/10 |
| `dr-w19-s6-ledger-pays-its-debt` | pr-body | #10565 | 8/10 |
| `dr-w19-s7-status-reads-the-deploy-verdict` | pr-body | #10609 | 10/12 |
| `dr-w2-s1-recorder-build-id-keyed-log` | pr-body | #9727 | 8/10 |
| `dr-w2-s7-scoped-search-permission-clamp` | pr-body | #9734 | 7/10 |
| `dr-w20-refusal-backoff-depth-derived` | pr-body | #10611 | 6/9 |
| `dr-w20-s1-control-plane-states-its-own-sha` | pr-body | #10605 | 12/13 |
| `dr-w20-s2-cp-smoke-can-fail-on-a-dead-box` | pr-body | #10606 | 7/10 |
| `dr-w20-s3-site-route-marker-stops-colliding` | pr-body | #10607 | 9/11 |
| `dr-w20-s4-raw-capture-strips-ansi-before-scrub` | pr-body | #10608 | 9/10 |
| `dr-w21-s2-plane-grades-freshness-by-commit-distance` | pr-body | #10756 | 9/10 |
| `dr-w21-s5-deploy-selftests-stop-skipping-silently` | pr-body | #10757 | 8/9 |
| `dr-w21-s6-delivery-gauge-stops-being-dark` | pr-body | #10758 | 7/9 |
| `dr-w22-s1-scrub-entry-boundaries-stop-leaking` | pr-body | #10710 | 8/9 |
| `dr-w22-s2-the-box-remembers` | pr-body | #10711 | 9/10 |
| `dr-w22-s3-dirty-tree-can-say-clean` | pr-body | #10712 | 7/8 |
| `dr-w22-s4-null-sort-fails-closed` | pr-body | #10713 | 8/9 |
| `dr-w23-s2-platform-deliveries-table` | pr-body | #10808 | 8/9 |
| `dr-w23-s5-health-names-its-clock` | pr-body | #10815 | 7/8 |
| `dr-w24-s1-crown-schema-stops-losing-rows` | pr-body | #10942 | 7/9 |
| `dr-w24-s2-commit-distance-reaches-the-cli` | pr-body | #10943 | 7/8 |
| `dr-w24-s5-the-rulings-become-readable` | pr-body | #10946 | 8/9 |
| `dr-w24-s6-roster-buys-back-seal-headroom` | pr-body | #10949 | 6/8 |
| `dr-w25-s1-gate-red-carries-the-cure` | pr-body | #11006 | 8/9 |
| `dr-w25-s4-deploy-gates-stop-being-disarmable` | main-commit | f7a87c0a5946 | 9/10 |
| `dr-w25-s5-ghost-carveout-keeps-a-live-name` | pr-body | #11010 | 9/10 |
| `dr-w25-s6-digest-stops-calling-a-stale-box-current` | pr-body | #11011 | 9/10 |
| `dr-w26-s1-land-11009-with-the-roster-fix` | pr-body | #11075 | 7/8 |
| `dr-w26-s2-land-11008-union-and-the-key-set-lie` | pr-body | #11078 | 6/7 |
| `dr-w26-s3-deliveries-reader-stops-lying-about-carried` | pr-body | #11080 | 9/10 |
| `dr-w26-s4-census-scores-a-caller-less-producer` | pr-body | #11082 | 10/11 |
| `dr-w26-s5-crown-gets-its-writer` | pr-body | #11167 | 14/16 |
| `dr-w26-s6-reader-less-instrument-guard-and-the-first-deletion` | pr-body | #11083 | 11/12 |
| `dr-w26-s7-delete-the-two-api-side-dark-instruments` | pr-body | #11170 | 10/11 |
| `dr-w26-s8-name-claim-legs-cannot-shrink-silently` | pr-body | #11084 | 10/11 |
| `dr-w27-s2-crown-wire-census-derived-not-typed` | pr-body | #11168 | 12/13 |
| `dr-w27-s5-terminal-writes-cannot-lose-silently` | pr-body | #11171 | 11/12 |
| `dr-w27-s6-conflicted-pr-stops-asserting` | pr-body | #11172 | 9/10 |
| `dr-w27-s7-deploy-gates-can-see-a-broken-workflow` | pr-body | #11173 | 6/8 |
| `dr-w28-s1-crown-records-what-the-box-served` | pr-body | #11203 | 9/10 |
| `dr-w28-s2-crown-reconciler-can-say-behind-or-wrong` | pr-body | #11205 | 8/9 |
| `dr-w28-s3-watch-stops-dying-on-its-own-payload` | pr-body | #11206 | 9/10 |
| `dr-w28-s4-the-deferral-wait-becomes-a-number` | pr-body | #11207 | 8/10 |
| `dr-w28-s5-digest-deploy-health-is-per-team` | pr-body | #11208 | 9/10 |
| `dr-w28-s6-abandonment-stamps-its-own-columns` | pr-body | #11209 | 8/9 |
| `dr-w28-s7-no-seal-reading-from-a-stale-checkout` | pr-body | #11210 | 8/9 |
| `dr-w29-s1-crown-reconciler-stops-manufacturing-a-wrong` | pr-body | #11252 | 7/8 |
| `dr-w29-s2-deferral-wait-reaches-a-human-on-the-census` | pr-body | #11253 | 9/10 |
| `dr-w29-s3-digest-carries-the-wait-and-the-law-gets-a-guard` | pr-body | #11254 | 7/8 |
| `dr-w29-s4-daily-digest-stops-skipping-days` | pr-body | #11255 | 6/7 |
| `dr-w29-s5-blind-watch-run-stops-reporting-green` | pr-body | #11256 | 9/10 |
| `dr-w29-s6-seal-runner-stops-refusing-a-perfect-tree` | pr-body | #11257 | 8/9 |
| `dr-w29-s7-abandonment-reaches-the-machine-surface` | pr-body | #11259 | 7/8 |
| `dr-w29-s8-mains-honesty-gate-goes-green` | pr-body | #11270 | 6/7 |
| `dr-w3-s5-door-refuses-box-at-capacity` | pr-body | #9827 | 11/12 |
| `dr-w30-s1-followup-carry-the-reask-list` | absorbed | #11365 | 0/2 |
| `dr-w30-s1-graced-sha-gets-a-re-read` | pr-body | #11318 | 8/9 |
| `dr-w30-s2-transport-silence-gets-its-own-code` | pr-body | #11319 | 8/9 |
| `dr-w30-s4-orphan-harnesses-reach-ci` | pr-body | #11320 | 7/9 |
| `dr-w30-s5-refusal-names-the-window` | pr-body | #11321 | 8/9 |
| `dr-w30-s6-push-dedupe-claim-gets-its-pin` | pr-body | #11322 | 7/8 |
| `dr-w31-s1-500-names-its-fault-family` | pr-body | #11364 | 6/7 |
| `dr-w31-s2-crown-reader-state-and-silence` | pr-body | #11365 | 8/9 |
| `dr-w31-s3-land-the-doc-id-split` | pr-body | #11368 | 7/8 |
| `dr-w5-s2-beat-carries-load15-and-5xx` | pr-body | #9888 | 8/10 |
| `dr-w5-s3-cp-lands-space-and-fixes-the-window` | pr-body | #9889 | 9/11 |
| `dr-w5-s4-agent-binary-reaches-the-fleet` | pr-body | #9890 | 4/8 |
| `dr-w8-s4-census-reaches-a-human` | pr-body | #10017 | 8/10 |

## DUPLICATE / SHADOW — cancel, do not work

| doc_id | why | criteria |
|---|---|---|
| `drafts.dr-w24-s3-custom-host-cannot-steal-a-url` | shadows published row `dr-w24-s3-custom-host-cannot-steal-a-url` (open) | 6/7 |
| `drafts.dr-w24-s5-the-rulings-become-readable` | shadows published row `dr-w24-s5-the-rulings-become-readable` (open) | 7/9 |
| `drafts.dr-w27-s6-conflicted-pr-stops-asserting` | shadows published row `dr-w27-s6-conflicted-pr-stops-asserting` (open) | 7/10 |
| `drafts.task-93206ca8fd299ae7` | title-identical twin `drafts.task-c075a65ad4a4e98d` (open) | — |
| `drafts.task-baa72f67d96766ce` | title-identical twin `drafts.task-93206ca8fd299ae7` (open) | — |
| `drafts.task-c075a65ad4a4e98d` | title-identical twin `drafts.task-93206ca8fd299ae7` (open) | — |

## ZOMBIE — cancel, the work landed under the new slug

| doc_id | why | criteria |
|---|---|---|
| `dr-w30-s7-crown-reader-and-silence` | #11365 names `dr-w30-s7` as landed work: "Four duties, one file set — `dr-w30-s7` absorbs `dr-w30-s1-followup-carry-the-reask-list` because both edit `crown-reconcile.yml` (charter D" | 0/9 |

## GENUINELY OPEN — the epic's real remaining surface

| doc_id | criteria | title |
|---|---|---|
| `dr-w10-s1-verdict-reads-the-deploy-rate` | 12/13 | The verdict reads the deploy rate, and can come out deploys_failing or unmetered |
| `dr-w25-s2-deliveries-reaches-a-human` | 11/12 | `bp cloud deliveries <sha>` renders the delivery timeline a human can read |
| `dr-w27-s3-census-arms-survive-their-own-success` | 11/12 | This epic's census stops breaking when it succeeds, and stops committing prose that stat |
| `dr-w21-s1-both-targets-assert-the-served-commit` | 10/11 | Neither deploy target can exit 0 over a box that did not move: both smokes assert the se |
| `dr-w27-s8-the-digest-that-arrives-names-deploy-health` | 10/11 | The one push channel that provably reaches humans stops saying nothing about deploy heal |
| `dr-w15-s2-graph-code-split-and-agency` | 9/10 | The content API's own status stops being thrown away, and the naming gauge learns to loo |
| `dr-w25-s3-crown-records-a-rollback` | 9/10 | The delivery record can tell a rollback from a no-op before it holds its first honest ro |
| `dr-w8-s1-ledger-names-cause-and-denominator` | 8/10 | The deploy ledger names the cause it already holds, and prints the denominator its rate  |
| `dr-w21-s3-cloud-status-carries-the-commit` | 8/9 | `bp cloud status` stops dropping the serving commit the control plane already stores, an |
| `dr-w23-s7-lever-and-seal-rulings` | 8/9 | The two written rulings the owner is owed: the cap-experiment decision packet, and this  |
| `dr-w23-s8-ledger-closes-the-closable` | 8/9 | The ledger closes what is provably closable, and stops carrying three unsatisfiable merg |
| `dr-w24-s4-census-grows-a-schema-arm` | 8/9 | The census grows an arm that can see a column no wire ever carries |
| `dr-w19-s1-unblock-10518-census-rebase` | 7/8 | PR #10518 stops being blocked: the deploy-census reader reaches the team door on a rebas |
| `dr-w23-s4-census-table-stops-hiding` | 7/8 | The deploy census table stops hiding a measured number behind a frozen sentence, and sto |
| `dr-w23-s1-delivery-reaches-origin` | 6/7 | Delivery: the three stranded wave-21 branches reach origin with PRs, and the two blocked |
| `dr-w24-s3-custom-host-cannot-steal-a-url` | 6/7 | A custom host can no longer steal a hostname another row already serves |
| `dr-w30-s3-11209-stops-inventing-a-code-word` | 6/8 | #11209 stops inventing a code word its box never emits, and lands |
| `dr-w28-s4-followup-payload-key-census-deferral-wait` | 3/3 | Reconcile the payload-key census with census/3's new deferral_wait key |
| `dr-terminal-record-prune-tie-order` | 1/2 | prune_terminal_records evicts by arbitrary directory order when mtimes tie |
| `dr-bl-w6-site-deploy-apply-unset-costs-16pct-of-failures` | 1/2 | DISPROVEN: BARKPARK_SITE_DEPLOY_APPLY is SET everywhere — the 503 class is a classifier  |
| `dr-w19-bl-merge-gated-paperwork-is-unsatisfiable` | 1/4 | Criteria that demand a merged PR's body say something are unsatisfiable after merge — a  |
| `dr-w24-s7-crown-gets-its-writer` | 0/9 | The crown gets its writer, and its first honest row |
| `dr-w24-s8-timeline-reaches-a-human` | 0/9 | A human asks what happened to their merge and the platform answers |
| `dr-backlog-never-started` | 0/3 | Deploy-reliability backlog: the never-started residue |
| `task-31a2280a801449d1` | 0/3 | Backfill the remaining ProseMirror-bodied papers with blocks, and fix the producer that  |
| `dr-w24-followup-diverged-is-not-ranked` | 0/2 | A diverged box is rendered but not ranked |
| `dr-w24-bl-emit-commit-distance-on-the-fleet-row` | 0/3 | Emit the three commit_* columns on barkpark_json/4 and delete their Side-C allowlist row |
| `dr-w25-s7-census-scores-a-caller-less-producer` | 0/12 | The payload census reds when a worker-seam write route ships with no caller |
| `dr-w25-s8-crown-gets-its-writer` | 0/13 | Every merge records what it actually delivered to each production host |
| `dr-w25-hg-gyldendal-operator-stops-the-transmission` | 0/4 | HUMAN GATE: stop the live cross-tenant credential transmission on b1259514 |
| `dr-w25-followup-yaml-job-scope-helper` | 0/3 | The two deploy.yml gates share a hand-rolled YAML job/step scanner that a 2-space heredo |
| `dr-w25-s2-followup-queue-split-render` | 0/3 | bp cloud deliveries renders the three-way queue split once #10942 lands |
| `dr-w25-followup-reader-blind-to-transition` | — | bp cloud deliveries renders previous_sha and transition (the reader is blind to the roll |
| `drafts.dr-w26-hg-gyldendal-operator-packet-corrected` | 0/5 | HUMAN GATE: stop the live cross-tenant credential transmission — token FIRST, url SECOND |
| `dr-w26-bl-conflicted-pr-keeps-asserting` | 0/4 | A conflicted PR re-dispatches ZERO checks and keeps asserting four green required contex |
| `dr-w26-bl-10129-and-10086-red-mains-census-on-merge` | 0/3 | #10129 and #10086 are unowned, DIRTY, frozen-green against a tree with NO census, and wi |
| `dr-w26-bl-claim-leg-refusal-reaches-no-human` | 0/3 | claim_leg/2 writes a careful operator sentence that dies in a server log — the API drops |
| `dr-w26-bl-cp-deploy-eats-a-scheduled-sampler-tick` | 0/3 | Every control-plane deploy silently drops a scheduled usage_samples tick, and nothing re |
| `dr-w26-bl-postfix-recreate-destroys-delivery-proof` | 0/3 | A control-plane deploy recreates cloud-postfix-1 and destroys the maillog — status='sent |
| `dr-w26-bl-platform-delivery-tojson-has-no-emitted-key-census` | 0/3 | PlatformDelivery.to_json/1 — the crown's own serializer — has NO Elixir-side emitted-key |
| `dr-w26-bl-seal-clause-a-depth-and-ladder-label` | 0/5 | Seal clause (a) is one level deep and drivable to SEAL by pure filing; --ladder-only acc |
| `dr-w26-bl-fleet-digest-audience-still-empty-escalated` | 0/4 | ESCALATION of dr-w19-fleet-digest-audience-still-empty: the hole filed in wave 19 ate a  |
| `dr-w26-bl-d375-frozen-numerator-corrected` | 0/3 | D375's frozen numerator is REFUTED — correct every downstream sentence that says the fai |
| `dr-w26-bl-ledger-stale-open-is-not-proof-unstamped` | 0/5 | The epic ledger's 71 open rows are three different diseases, and 15 of them name a branc |
| `dr-w26-bl-go-tag-arm-is-36-percent-blind` | 0/4 | The go-tag census can only lose when the LAST site of a name dies — 36% of names are sil |
| `dr-w26-bl-cp-reflog-provenance-expires-in-september` | 0/3 | The control plane's deploy provenance is a 90-day reflog that evaporates around 2026-09- |
| `dr-w26-s8-followup-census-the-leg-input-select` | 0/2 | Census the SELECT that feeds the name-claim legs (a leg can be weakened at its source) |
| `dr-w26-s3-bl-fixture-synthetic-field-is-unasserted` | 0/2 | The platform-deliveries fixture declares a `synthetic` provenance field that no test req |
| `dr-w26-followup-reader-corpus-dispatch` | 0/3 | The reader-less census reads four trees CI does not dispatch on — a reader added only in |
| `dr-w26-followup-queued-seconds-disposition` | 0/3 | queued_seconds is a FOURTH reader-less delivery leg and it is not in the register — deci |
| `dr-w26-s4-followup-widen-escape-harness` | 0/3 | cloud-path-escape-check harness pins exact-entry semantics on paths dr-w26-s4 needs as d |
| `dr-w26-bl-deliveries-reader-two-keys-behind-11008` | 0/5 | The deliveries reader is two keys behind its own serializer the moment #11008 lands |
| `dr-w27-bl-seal-clause-a-is-one-hop-and-bc-score-a-foreign-register` | 0/3 | The seal predicate cannot answer at all: clause (a) is one hop deep and clauses (b)/(c)  |
| `dr-w27-bl-roster-read-drops-an-open-human-gate` | 0/3 | The seal roster read cannot see an OPEN human gate, and bp task get double-counts two dr |
| `dr-w27-bl-d375-freeze-date-is-false-on-main` | 0/3 | The charter's flagship retirement decision states a freeze date and count that are check |
| `dr-w27-bl-d457-rederivation-reads-a-column-that-does-not-exist` | 0/3 | D457's own re-derivation command reads a column that does not exist, on this epic's prio |
| `dr-w27-bl-gyldendal-packet-409s-on-the-dedup-wall` | 0/3 | The corrected gyldendal operator packet cannot be published as written - the dedup wall  |
| `dr-w27-bl-digest-loss-log-has-no-durable-sink` | 0/3 | The digest's counted-loss log is written to a sink every deploy destroys, and documented |
| `dr-w27-bl-fleet-rollout-state-has-no-human-reader` | 0/3 | The fleet brake's position is unreadable by any person: a worker-tier route with no huma |
| `dr-w27-bl-decoded-but-never-rendered-sha` | 0/3 | bp cloud deliveries never proves the rows it printed are the sha you asked for - d.SHA i |
| `dr-w27-bl-reclaim-26-shipped-but-open-rows` | 0/3 | 26 open rows are named in merged main commits and are already paid for - reclaim before  |
| `dr-w27-bl-deferral-cause-is-null-on-59-percent` | 0/3 | 59.7% of deferrals cannot name a cause, and the vocabulary changed twice inside one week |
| `dr-w27-s7-restore-a-wedge-control-that-does-not-need-runner-queue-len` | 0/4 | Restore a wedged-Runner control that does not depend on runner_queue_len |
| `dr-w27-s8-f1-seven-day-door-refuses-until-boundary-ages-out` | — | The digest's 7d deploy door renders UNMEASURED until the deferred-status boundary ages o |
| `dr-w27-arm-b-serving-build-durable-repair` | 0/3 | A build the box IS serving must not be terminally reported failed by the stale reaper (t |
| `dr-w27-s6-followup-drain-the-stale-verdict-backlog` | 0/2 | Drain the 20-PR stale-verdict backlog the new watch reds on from day one |
| `dr-w27-bl-register-floor-lags-the-register` | 0/2 | The reader-less register floor lags its own register: deleting the row wave 27 just adde |
| `dr-w27-bl-two-ledger-slugs-predate-the-id-law` | 0/2 | Two ledger slugs predate the id law the census now enforces, so the census cannot cite t |
| `dr-w27-instance-serving-since-durable` | 0/3 | serving_since for the instance leg: the crown records NULL because no durable source exi |
| `dr-w28-bl-argv-ceiling-has-no-repo-wide-tripwire` | 0/4 | The MAX_ARG_STRLEN argv ceiling has cured two files and no repo-wide tripwire, so it wil |
| `dr-w28-bl-seal-predicate-parser-blind-spots-console-side` | 0/4 | Four mutation-proved seal-predicate leg-B blind spots — latent today, and behind the D40 |
| `dr-w28-bl-gyldendal-corrected-criterion-still-unsatisfiable` | 0/5 | The corrected gyldendal packet's criterion is still probably unsatisfiable — :not_live i |
| `dr-w28-bl-reclaim-20-column-a-closes-and-three-draft-twins` | 0/5 | Reclaim: 20 column-A closes, 14 column-B rows that need a live proof, and three draft tw |
| `dr-w28-bl-fixture-teaches-columns-no-producer-can-write` | 0/4 | The crown fixture asserts pickup=3 and stall=5 on five scenarios — values no producer in |
| `dr-w28-bl-unattributed-content-auto-deferrals` | 0/4 | Four content-auto deferral rows have no Oban job that could have minted them |
| `dr-w28-bl-instance-serving-since-task-premise-refuted` | 0/4 | dr-w27-instance-serving-since-durable argues against a source D465 already rejected and  |
| `dr-w28-bl-deferral-cause-title-retitle-and-59-percent` | 0/4 | Retitle the 59.7% row: it names a CLOSED population in the present tense and the number  |
| `dr-w28-bl-seal-run-is-available-but-not-enforced` | 0/2 | scripts/seal-run.sh exists but nothing enforces it — a hand-typed predicate call is stil |
| `dr-w28-followup-merged-at-committer-tripwire` | 0/2 | merged_at's NULL arm keys on one hard-coded committer email, and nothing notices if it m |
| `task-3e0e34153a7ba0a4` | 0/2 | Crown reconciler CI read path: the worker principal cannot read GET /v1/deliveries — pro |
| `dr-w28-rv-abandonment-predicate-replaces-the-prose-regex` | 0/3 | The abandoned classifier reads deferral_cause instead of a prose LIKE scan |
| `dr-w28-rv-crown-reconcile-ci-read-path-has-never-executed` | 0/3 | The crown reconciler's CI read path has never executed anywhere |
| `task-e2acb66e9ed0da09` | — | GET /v1/deliveries answers 401 to the WORKER principal — the crown's only public read pa |
| `dr-w29-bl-serving-since-has-no-basis-column` | 0/3 | No column records WHICH BASIS produced a serving_since, so any cross-target lag comparis |
| `dr-w29-bl-build-seconds-is-per-run-not-per-sha` | 0/3 | build_seconds is per-run-per-target, not per-sha — state what the column means or split  |
| `dr-w29-bl-watch-red-carries-no-trend-and-cancelled-is-unread` | 0/4 | The stale-verdict watch's red carries no trend, and a cancelled run must count as UNREAD |
| `dr-w29-bl-watch-poll-budget-inadequate-under-a-merge-burst` | 0/3 | The stale-verdict watch's poll budget cannot outlast a merge burst — ~28s of waiting lef |
| `dr-w29-bl-no-sent-email-body-is-recoverable-anywhere` | 0/3 | No email body the platform has ever sent is recoverable — the digest rail cannot prove w |
| `dr-w29-bl-remediated-tenant-is-provable-only-as-an-absence` | 0/4 | usage.ex flattens :not_live and :no_admin_token to :unmetered, so a remediated tenant is |
| `dr-w29-bl-crown-http-read-path-unreachable-to-the-worker-principal` | 0/3 | The crown's HTTP read path answers 401 to the WORKER principal — the postgres fallback i |
| `dr-w29-bl-post-door-label-vs-its-denominator` | 0/3 | '% failed post-door' divides by a denominator that includes deferrals |
| `dr-push-delivery-worker-rolling-unique-window` | 0/3 | PushDeliveryWorker carries the same bare Oban unique window that ate 3 of 7 daily digest |
| `dr-transport-silence-still-exits-zero` | 0/5 | stale-verdict-watch: a total transport failure still concludes success |
| `dr-seal-run-harness-runs-in-no-ci` | — | Nothing runs scripts/seal-run.test.sh — the seal runner's 73 mutation proofs can rot sil |
| `dr-w29-s1-followup-run-id-alibi-is-self-reported` | 0/2 | The WRONG alibi now trusts a field the recorder writes about itself |
| `dr-merge-gates-roster-prose-is-gated-by-nothing` | 0/3 | The merge-gates roster's prose count is gated by nothing — §21 clause 2 only asserts >=  |
| `dr-w30-bl-deliveries-route-widening-is-inside-cch-fence` | 0/3 | Widening /v1/deliveries to the worker principal is fenced — file the decision, do not bu |
| `dr-w30-bl-operator-census-403-blocks-the-fleet-ranking` | 0/3 | The only D3-legal fleet-wide ranking surface refuses the credential every epic reader ho |
| `dr-w30-bl-box-busy-deferred-is-a-dead-arm` | 0/3 | BOX_BUSY_DEFERRED has not fired since the writer landed — find out why before curing it |
| `dr-w30-bl-cancelled-deploy-runs-are-invisible-to-the-crown` | 0/3 | Cancelled deploy runs write zero rows and confound every rate computed per delivering_ru |
| `dr-w30-bl-seal-clause-a-orphans-doubled-to-161` | 0/3 | Seal clause (a) is the only blocker and its orphan count has more than doubled to 161 |
| `dr-w30-bl-lead-acts-from-waves-28-and-29-still-unexecuted` | 0/8 | Every unexecuted lead act from waves 28 and 29, filed as tasks because prose has a 0% ex |
| `dr-w30-bl-installed-bp-lacks-wave-29s-readers` | 0/3 | The readers wave 29 built to reach a human do not exist on the human's binary |
| `dr-w30-bl-w28-s7-criterion-wording-is-unsatisfiable` | 0/3 | w28-s7's 'full-history worktree' is unsatisfiable on this machine and must be reworded |
| `dr-w30-bl-paper-ingest-limits-500-with-no-detail` | 0/4 | The paper ingest 500s on a 17th heading and a ~63KB render, with no detail either time |
| `dr-w30-followup-headline-refusal-names-the-window` | 0/2 | The HEADLINE failure rate refusal names no window either |
| `task-6d1bb2843f0c91fb` | — | 19 conflicted PRs assert stale greens, and four of them strand charter decisions other c |
| `dr-w31-bl-reclaim-the-open-ledger-in-one-act` | 0/5 | Reclaim the ledger in ONE act: 6 landed w30 slices, 2 falsely-open rows, 3 draft twins,  |
| `dr-w31-bl-every-rate-prints-both-bases` | 0/4 | Every deploy rate this epic publishes prints BOTH bases — a wait is not an outcome |
| `dr-w31-bl-spawned-box-never-gets-site-deploy-apply` | 0/3 | A SPAWNED box structurally never receives BARKPARK_SITE_DEPLOY_APPLY and will 503 on its |
| `dr-w31-bl-search-starter-retry-budget-is-unreachable` | 0/3 | 129 DOC_ID_EMPTY rows are a content-API blip the SSR gave up on in ~5s — and the retry b |
| `dr-w31-bl-served-catalog-drift-is-red-and-unowned` | 0/3 | The served-catalog drift audit is RED on main, UNOWNED, and still red on the very commit |
| `dr-bl-traverse-errors-functionclause-500` | 0/3 | The 33 non-DB 500s are one code defect: FunctionClauseError in Ecto.Changeset.traverse_e |
| `dr-w31-fu-agency-reaches-the-cli` | 0/1 | The census class row now carries agency; internal/cloudclient does not decode it, so the |
| `dr-w31-s2-followup-split-rc2-so-a-benign-grace-does-not-page` | 0/3 | Split rc=2 so an in-flight grace does not page a human every six hours |
| `task-a02741ad13bbf010` | — | the collapse is REAL and relabelling-immune — but zero of 3,315 deferred rows has ever r |

## Known floor/ceiling — 76 is a LOWER bound, 116 an UPPER bound

Charter D536 names two more rows as already cured on main that this scan puts in
GENUINELY OPEN, because their PRs used `Refs:` / prose instead of a `Task:` line:

| doc_id | cured by | mergeCommit ancestor of main | why the scan missed it |
|---|---|---|---|
| `dr-seal-run-harness-runs-in-no-ci` | #11320 | `2f583ea1e223` YES | body says `Refs:`, and the cure is a COMMENT in `.github/workflows/shell-harnesses.yml` naming the row |
| `dr-transport-silence-still-exits-zero` | #11319 | `917521fbe878` YES | rc=2 split into rc=6/rc=7, no `Task:` line for this row |

So landed-but-open is **>= 78**, genuinely open **<= 114**. The `Task:` convention is
the only machine-readable link between a row and its landing; where a builder wrote prose,
the row is invisible to every automated reclaim. That is the same disclosure disease the
deploy ledger has, in the epic's own bookkeeping.

## Warning for anyone re-deriving this from a checkout

The primary checkout was **800 commits behind origin/main** while this ran
(`git rev-list --count HEAD..origin/main` = 800). Every test above is against
`origin/main`, never the worktree. A verifier who greps local files here reads a
stale tree: `grep -c seal-run .github/workflows/shell-harnesses.yml` returns 0 locally
and the wiring is plainly present in `git show origin/main:` of the same path.

## rerun

```
bash /tmp/v10_partition.sh
```

---

# EXECUTION RECORD — dr-w32-s7, 2026-08-09

The partition above is the plan. This is what was actually done to the ledger, and
where the plan was wrong. Every close names a mergeCommit that
`git merge-base --is-ancestor <oid> origin/main` accepted against `origin/main e913de82c881`;
all 74 PR mergeCommits plus `f7a87c0a5946` passed that test, zero failures.

## The plan said "close 76". 52 were closed. Here is the honest split.

| bucket | rows | act |
|---|---|---|
| CLOSED done, mergeCommit quoted in the close reason | 52 | `bp task close … done` |
| LEFT OPEN — a genuine WORK criterion is unproven | 21 | untouched, listed below |
| LEFT OPEN — the criterion's OWN check FAILS on main today | 3 | untouched, listed below |
| CANCELLED — zombie / absorbed | 2 | `bp task close … cancelled` |
| DISCARDED — shadow `drafts.*` | 6 | `bp doc discard-draft` |

**Why not 76.** The brief said the ~24 rows that are not at N−1 "need EYES". They got
them: every one of the 76 rows was re-read from the server and each unmet criterion was
classified as MERGE-GATED (lead-owned, satisfied by the merge itself), LEAD-PLUS (a
post-merge live re-read, migration, or human review the merge does NOT prove), HUMAN
(an independent security review), or WORK (the builder's own unfinished proof).

* A row whose unmet criteria are all lead-owned was CLOSED. Its merge-gate criterion was
  stamped `--merge-gated` with the mergeCommit as evidence; any LEAD-PLUS or HUMAN
  criterion was NOT flipped — it was closed over with `--set criteria_override=…` naming
  the index and saying in words that the verification was never performed. The row reads
  done; the unproven criterion still reads unproven. That is the point.
* A row with a WORK criterion was LEFT OPEN. A landed PR is not proof that the builder
  ran the live probe the criterion demands, and flipping it would manufacture exactly the
  false-done this repo has been burned by.

## LEFT OPEN — a genuine WORK criterion is unproven (21)

Column 3 is the 0-based index of each unmet WORK criterion.

| doc_id | criteria | unproven WORK criteria |
|---|---|---|
| `dr-w1-s5-swallow-records-upstream-status` | 7/10 | 4, 7 |
| `dr-w13-s5-cli-reads-columns-and-names-its-window` | 12/15 | 10, 11 |
| `dr-w13-s6-publish-clock-first-caller` | 13/15 | 1 |
| `dr-w18-s3-push-rail-can-lose` | 6/8 | 4 |
| `dr-w19-s6-ledger-pays-its-debt` | 8/10 | 4 |
| `dr-w19-s7-status-reads-the-deploy-verdict` | 10/12 | 9 |
| `dr-w2-s1-recorder-build-id-keyed-log` | 8/10 | 6 |
| `dr-w2-s7-scoped-search-permission-clamp` | 7/10 | 1 |
| `dr-w20-refusal-backoff-depth-derived` | 6/9 | 0, 7 |
| `dr-w20-s2-cp-smoke-can-fail-on-a-dead-box` | 7/10 | 2, 7 |
| `dr-w20-s3-site-route-marker-stops-colliding` | 9/11 | 5 |
| `dr-w21-s6-delivery-gauge-stops-being-dark` | 7/9 | 4 |
| `dr-w24-s1-crown-schema-stops-losing-rows` | 7/9 | 3 |
| `dr-w24-s6-roster-buys-back-seal-headroom` | 6/8 | 1 |
| `dr-w27-s7-deploy-gates-can-see-a-broken-workflow` | 6/8 | 6 |
| `dr-w28-s4-the-deferral-wait-becomes-a-number` | 8/10 | 8 |
| `dr-w5-s2-beat-carries-load15-and-5xx` | 8/10 | 6 |
| `dr-w5-s3-cp-lands-space-and-fixes-the-window` | 9/11 | 6 |
| `dr-w5-s4-agent-binary-reaches-the-fleet` | 4/8 | 4, 5, 6 |
| `dr-w8-s4-census-reaches-a-human` | 8/10 | 8 |
| `dr-w30-s1-followup-carry-the-reask-list` | 0/2 | 0, 1 → CANCELLED as absorbed, see below |

`dr-w8-s4`'s criterion 8 is the one worth reading: it demands `PLATFORM_ADMIN_EMAILS`
be set on the serving control-plane container. It is not. The row is correctly open.

## LEFT OPEN — the criterion's own check FAILS on main today (3)

These three are the reclaim's own findings. Each PR is merged and an ancestor of main,
and each row's merge criterion carries a command that was RUN here and did not pass.

| doc_id | the check, run against origin/main e913de82c881 | result |
|---|---|---|
| `dr-w26-s3-deliveries-reader-stops-lying-about-carried` | `git show origin/main:internal/cloudclient/deliveries.go \| grep -c 'Carried \*bool'` | **0**, criterion demands 1 |
| `dr-w26-s6-reader-less-instrument-guard-and-the-first-deletion` | `git grep -c publish_clock origin/main` | non-empty (charter 17, `reader_less_instrument_census_test.exs` 5, `deploy_ledger_reachability_test.exs` 1); criterion demands nothing |
| `dr-w26-s7-delete-the-two-api-side-dark-instruments` | `git grep -c 'runner_queue_len\|build_slots' origin/main -- api/ cloud/ internal/ web/ js/` | hits in `instance_site_deploy_controller.ex` (4), `router.ex` (3), `deploy_runner_door_census_test.exs` (2); criterion demands nothing |

A reclaim that closed these on ancestry alone would have papered over three live
contradictions. They stay open on purpose.

## CANCELLED (2)

| doc_id | why |
|---|---|
| `dr-w30-s7-crown-reader-and-silence` | ZOMBIE. Shipped as #11365 `6f8a70167410b16ab8bd7046cf76443d2e203c09` (ancestor of main), re-filed and landed as `dr-w31-s2-crown-reader-state-and-silence`. Reads 0/9 — cancelled, not closed done, because no criterion on IT was ever proven. |
| `dr-w30-s1-followup-carry-the-reask-list` | ABSORBED into the same #11365; `dr-w31-s2`'s own merge criterion names it "closed by it as absorbed" (GH #11314). Reads 0/2 — cancelled for the same reason. |

## DISCARDED — shadow `drafts.*` (6, per D491)

`bp doc discard-draft task <id>`, which keeps any published version:

* `task-93206ca8fd299ae7`, `task-c075a65ad4a4e98d`, `task-baa72f67d96766ce` — the
  byte-identical crown-reconcile triplet; twin `task-e04e0566ffc68738` is DONE. These had
  no published version, so the discard removed the row entirely (verified: `bp task get
  task-93206ca8fd299ae7` now answers `not_found`).
* `dr-w24-s3-custom-host-cannot-steal-a-url`, `dr-w24-s5-the-rulings-become-readable`,
  `dr-w27-s6-conflicted-pr-stops-asserting` — drafts shadowing published rows at LOWER
  progress; the published rows survive (verified: `dr-w24-s3` still reads
  `status=published lifecycle=open 6/7` after the discard).

`drafts.dr-w26-hg-gyldendal-operator-packet-corrected` was LEFT ALONE — it is a genuine
unpublished human gate, not litter.

## Method notes for the next reclaim

1. `bp task stamp` REFUSES a criterion whose text carries the MERGE-GATED marker unless
   you pass `--merge-gated`. That guard is correct and it is why a builder cannot fake a
   merge. A lead-authorised reclaim passes it explicitly.
2. `bp task close` refuses while any criterion is unmet AS STORED and tells you to either
   stamp it or `--set criteria_override="<why it is done anyway>"`. Criteria flipped in
   the close command itself do not count — "that would be the closer grading its own
   homework". Both halves of this act used that split deliberately.
3. The claim response carries the epoch at `doc.claim.epoch`, NOT `doc.content.claim`.
4. `bp` refuses any verb invoked with a piped stdin (`piped stdin is unused`); a script
   driving it must pass `stdin=DEVNULL`.
5. Guerrilla was returning `internal_error` 500s throughout this run and individual
   `bp task get` calls took minutes. Roughly 15% of writes failed on the first attempt and
   succeeded on retry. Any bulk ledger act needs per-row retry, and the failure is a
   server 500, not a rejection.
