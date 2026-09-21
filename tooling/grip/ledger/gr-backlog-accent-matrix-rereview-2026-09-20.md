<!-- evidence packet: gr-backlog-accent-matrix-rereview, shot 2026-09-20 by console-w10 for lead-console-r21l; PNGs are not committed (cloud/.gitignore ignores __shots__), hashes are -->

# gr-backlog-accent-matrix-rereview — findings (console-w10)

Base: origin/main e922f67e6cb0af763c75210e1e12ba19370644d1 (worktree, detached).
Shot 2026-09-20 with CHROME=chromium_headless_shell-1217.
Shots: /Volumes/SATECHI/dev-caches/tmp/claude-code/claude-501/-Volumes-SATECHI-github-barkpark/bae91ce1-642a-4012-bfac-7f62707d17bb/scratchpad/orchestrate/tmp/console-w10/matrix-{aa,ab,ac,ad}/ (2760 PNGs), flat symlinks in /Volumes/SATECHI/dev-caches/tmp/claude-code/claude-501/-Volumes-SATECHI-github-barkpark/bae91ce1-642a-4012-bfac-7f62707d17bb/scratchpad/orchestrate/tmp/console-w10/all/.

## c0 — the full matrix, DERIVED denominator
accents: 5, derived from `grep -o '\[data-bp-theme="[a-z]*"\]' cloud/priv/static/app.css`
  -> charple, ember, evergreen, fjord, iris
themes: 2 (shoot.sh:130 THEMES=(light dark))
widths: 2 (shoot.sh:131 WIDTHS=(1440 768))
scenarios: 138, from Object.keys(SCENARIOS) in scenarios.mjs (118 carry a deepLink)
DENOMINATOR 138 x 2 x 2 x 5 = 2760.
PRODUCED: 2760 (`ls matrix-*/*.png | wc -l`), 4 shards reporting 700+700+700+660,
0 failures. The 14 `!!` lines in the logs are reap-watchdog notices on fd 3,
not failed shots.

NON-VACUITY, three ways:
 (1) named pair, deep-linked scenario billing-trial (deepLink "#billing"), light/1440:
     evergreen 3eff45bd8d48cdfd4f7f052ec3a12ab2235023c5be541ba095a06f38cf2e7745
     ember     89f6e673c7511cf565b87aea26fd2756548c11a0ed3300e30efe4259281b40d0
     (also fjord e7af29ee…, charple eac65e8f…, iris 347f8e08…)
 (2) EXHAUSTIVE: all 552 (scenario x theme x width) cells carry 5 DISTINCT
     sha256s across the 5 accents. Cells with <5 distinct: 0 of 552.
 (3) the conservative restriction, because 35 scenarios have clock-dependent
     content: restricted to the 103 scenarios proved byte-stable across two
     independent serial re-runs, 412 of 412 cells still carry 5 distinct hashes.

## c0 addendum — an instrument finding nobody asked for
35 of 138 scenarios are NOT byte-reproducible (clock/relative-time content).
Measured with a CONTROL: two independent SERIAL runs of the same 138 scenarios
at ember/light/1440 differ on 35. A parallel-vs-serial comparison differs on 37.
So the parallel sharding I used adds only 2 unstable scenarios
(account-modal-2fa-badcode, activate-logged-out); it is NOT the main cause.
account-modal-2fa-badcode is genuinely racy: 4 serial re-shoots at
evergreen/light/1440 gave 028e6553… once then 2b660f36… three times.
CONSEQUENCE: any future gate that diffs matrix PNGs byte-wise must exclude the
35, or it will red on the clock.

## c1 — screen-by-screen review
138 of 138 scenarios reviewed by eye. Per scenario: light/1440 at ALL FIVE
accents + dark/1440 at ember = 828 images opened. 768 was shot but NOT reviewed
(the row scopes 768 to gr-p5-spa-finishers / gr-backlog-tablet-width-audit).
`.btn-link` accent variance excluded per GR57.

### DEFECT-A — the semantic-vs-accent colour collision (the dominant finding)
Success/health state is painted with the ACCENT token, not a success token. At
ember (and to a lesser degree charple/iris) "good" and "bad" become the same
warm hue. Seen independently by 7 of 10 reviewers on 20+ screens:
  mixed-fleet, fleet-usage, overview-attention, overview-attention-long-name,
  overview-trial-runway, overview-never-reported, overview-past-due,
  operator-console, operator-denied, panel-overview, timeline,
  instance-cruel-detail, verify-pass, verify-fail, failed, provisioning,
  theater-failed, theater-failed-member, instance-failed-member,
  site-deploy-rail-live, site-deploy-rail-failed,
  site-deploy-rail-failed-classified, tokens-populated, notif-member
  · ember · light+dark · 1440 · [defect]
This is ONE root cause, not 24 bugs. File as one task.

### DEFECT-B — destructive vs primary button collision at ember
Primary (accent) and destructive (danger red) sit adjacent at nearly the same
hue, so the destructive control loses its warning:
  webhooks-panel, rollback, shell-site (light+dark) · ember · 1440 · [defect]

### DEFECT-C — header row collapses under a long permission sentence (member views)
  panel-overview-member · all 5 accents · light+dark · 1440 · title breaks
    mid-word ("Productio/n"), "Healthy · v0.9.2" wraps to "v0./2", URL truncates
  timeline-events-only · all 5 · light+dark · 1440 · same shape
  instance-behind-member · all 5 · light+dark · 1440 · WORST: title renders one
    letter per line, the update pill becomes a 1-char sliver, URL disappears,
    ~700px dead space above the tab bar
  [defect] — same root cause: the action-row sentence starves the title column.

### DEFECT-D — orphaned red fragment where the instance URL belongs
  instance-remove-failed-member · all 5 · light+dark · 1440 · "— removal failed"
  instance-failed-member · all 5 · light+dark · 1440 · "— provisioning failed"
  instance-remove-failed · all 5 · light+dark · 1440 · the same sentence three
    times within ~130px
  [defect]

### DEFECT-E — eight fleet-support / offload scenarios render a plain instance page
  fleet-support-provisioning, fleet-support-online, fleet-support-failed,
  fleet-support-empty, offload-filing, offload-working, offload-done,
  offload-blocked, and verify-no-credentials
  · all 5 accents · light+dark · both widths · BYTE-IDENTICAL to shell-instance.
VERIFIED MECHANICALLY: one sha256 covers all 10 names in every one of the 20
cells, and REPRODUCED in 4 independent runs (3 serial + the matrix), so this is
NOT a capture race. None of these 9 labels describes a click-gated state — they
promise a support theater, an offload ladder and a verify card that render on
load. Strongest single defect in the sweep.
  [defect]

### DEFECT-F — theater-ready-github-member disabled control collapses
  all 5 · light+dark · 1440 · the disabled "Create GitHub repo" button collapses
  to an empty ~40px outlined square with its label floating outside it. [defect]

### DEFECT-G — account-modal-tall footer below the fold
  all 5 · light+dark · 1440 · Close / Log out are off-screen in the shot.
CAUTION FOR THE FILER: modal-oracle.mjs measures this state as
`card=1043px root=1092/900 hit=true` — the root IS scrollable. So "clipped with
no internal scroll" as the reviewer wrote it is WRONG; the honest finding is
"the footer is below the fold at a 1000px window", a ranking/priority question,
not a broken-scroll bug. [cosmetic, downgraded from the reviewer's defect]

### DEFECT-H — metrics-stale contradicts itself
  all 5 · light+dark · 1440 · "No vitals to judge — this box has not reported
  the numbers" renders directly above four populated tiles (CPU 58%, Mem 57%,
  Disk 74%, Load 1.1). [defect]

### DEFECT-I — fleet-cruel-content unbounded status pill
  all 5 · light+dark · 1440 · the "Failed · <reason>" pill has no length cap and
  balloons to six lines, pushing the instance name below it. [defect]

### DEFECT-J — a fixed blue that ignores the accent (one token, many screens)
  invite-joined (envelope medallion), invite-already-member (info medallion),
  activity ("Show all 3"), timeline-coalesced ("Show all 10"), billing-trial and
  billing-unconfigured (trial pills), deploy-detail-cruel ("Starting…" chip),
  account-modal / -2fa-on / -2fa-badcode / -me-unreadable ("Change password",
  "Sign out everywhere else", "Copy")
  · all 5 accents · light+dark · 1440 · [cosmetic] — one root cause.

### DEFECT-K — a destructive or primary action rendered as plain body text
  providers-connected ("Disconnect…"), notif-configured ("Send test email"),
  billing-cancelling ("See all plans"), empty ("Connect Hetzner Cloud")
  · all 5 · light+dark · 1440 · no accent, no underline, no button chrome.
  [cosmetic]

### Smaller cosmetics worth one ticket between them
  - shell-instance / promote-in-flight / shell-site: "No content binding" and
    "Deploy pair" wrap and overhang the DETAILS value column · all 5 · 1440
  - site-member: member view renders Deploy/Delete/Redeploy/Roll back at full
    affordance with no permission notice, unlike panel-overview-member [defect]
  - activity: the Who filter chips wrap under the Target label and read as
    Target options · all 5
  - promote-failure: two deployments badged "Live" at once · all 5
  - webhooks-autodisabled: "Enable" and "Re-enable" both offered for one action
  - activity-identity-change: "▲ 0 needs attention" in amber warning styling on
    an all-healthy board; and no identity-change event in Recent activity
  - billing-support-plus: the "Support++" badge clips the workspace stepper icon
  - instance-behind: "Update to v0.9.2" and "Open Studio" are two identically
    accent-filled primaries, so the update carries no precedence
  - activate-rate-limited: disabled "Try again in 10s" is white on a pale fill
  - site-states (dark/ember): the "Cancelled" badge nearly disappears
  - providers-empty, notif-deliveries-error (dark/ember): the selected segment in
    the transport picker loses its fill, so selection reads only from weight
  - members-*: 6 member/role scenarios reviewed CLEAN at all five accents

### Reviewer claims I CHECKED AND CORRECTED (do not file these)
  - "billing-me-recovers is pixel-identical to billing-me-unreadable" — FALSE.
    cmp says they differ (198038 vs 197869 B at light/ember). Both are also in
    the 35 clock-unstable set, so a byte claim about them means nothing.
  - "operator-denied never renders the operator page" — NOT A DEFECT. Its own
    label reads "a non-operator deep-links #operator and is bounced to
    Overview", so rendering shell-root IS the specified behaviour.
  - "identity-iris is identical to shell-root" — TRUE, and it is the ACCENT AXIS
    that causes it: identity-iris sets seedLocal {bp_theme:"iris"}, and
    mock.js:71 overwrites that key with ?accent= on every accent-suffixed shot.
    So this scenario's entire point (GR12, iris as the ACTIVE state) is
    destroyed by the matrix that is supposed to prove it. HARNESS finding.
  - the activate-entry / loggedout-signup / loggedout-reset / 2fa-badcode
    "missing focus ring at evergreen" reports: activate-entry and
    loggedout-signup are byte-stable across 4 re-shoots, so those two stand.
    account-modal-2fa-badcode is RACY (hash flipped 1 of 4 runs) — do not file
    its focus-ring row without a re-shoot.
  - "tokens-revoke / tokens-reveal / providers-unverified / operator-me-recovers
    / loggedout-twofactor never render their named state" — TRUE but these are
    BLIND SPOTS, not product defects: every one of those five labels describes a
    state reached by a CLICK or a FORM SUBMIT ("driven by real clicks",
    "verify-before-save", "the retry re-reads", "submit ANY credentials"). They
    belong in c2, and they are there.
  - a "37 unconsumed scenario data keys" audit I ran is WITHDRAWN in full: it
    grepped mock.js/app.js for key names, but the data is consumed by
    `route()` inside scenarios.mjs via shorthand object literals, so the key
    name never appears as `.key`. It flagged `me` and `providers`. Worthless.

## c2 — blind spots
See c2-blind-spots.md beside this file. Headline: the matrix reaches 1 of the 28
`openModal(` call sites in app.js, because `?modal=account` is the only modal
seam mock.js has and shoot.sh derives it from a NAME CONVENTION
(`case "$scen" in account-modal*`), not a scenarios.mjs field. Add to that list
the five click-gated scenarios above, whose named states are equally unreachable
without a driver.


# c2 — blind spots

# c2 — screens the accent x theme x width matrix CANNOT reach

Derived on origin/main e922f67e6cb0af763c75210e1e12ba19370644d1.

## Derivation (not a guess)
- `grep -n 'openModal(' cloud/priv/static/app.js` -> 31 hits; 3 are the definition
  (l.917) and two prose comments (l.7, l.845). **28 real call sites.**
- The ONLY seam in `__preview__/mock.js` that opens a modal is `?modal=account`
  (mock.js:244 -> `appHooks.openAccountModal()` at mock.js:259).
- `shoot.sh:336` derives that query from a NAME CONVENTION, not a scenario field:
  `case "$scen" in account-modal*) modal_q="&modal=account" ;;`
- `scenarios.mjs` entries carry only: label, authed, deepLink, data, pathname,
  search, seedLocal. **There is no modal field at all.**
- => the matrix reaches **1 of 28** modal call sites. 27 are structurally invisible
  to every PNG this task produced, at every accent, theme and width.

## Reached (1/28)
| app.js | function | how it is reached |
|---|---|---|
| 1886 | openAccountModal | mock.js `?modal=account`, 7 `account-modal*` scenarios |

The 7: account-modal, -tall, -revoke, -cruel-identity, -2fa-badcode, -2fa-on,
-me-unreadable. Note mock.js:214-221 records that the modal opens in its DEFAULT
phase, so `account-modal-2fa-badcode` only shows its named state because mock.js
additionally calls `drive2faBadCode()` (mock.js:262) — a per-scenario driver, the
only one that exists.

## NOT reached (27/28) — every one is a blind spot at all 5 accents
| app.js | function | what is never photographed |
|---|---|---|
| 1144 | openConfirmModal | the GENERIC typed-confirmation modal (shared helper; every destructive flow that routes through it) |
| 3094 | openResurrectModal | resurrect a suspended instance |
| 3410 | openProviderCredential | provider credential sheet (launch wizard's Connect) |
| 6061 | openTokenModal | New API token form |
| 6208 | revealToken | token reveal (the secret-once screen) |
| 6268 | confirmRevokeToken | Revoke token? |
| 10598 | confirmUpdateInstance | Update instance? |
| 10660 | openUpdateConflictModal | update-conflict / force copy |
| 10732 | openAttachDomainModal | Attach a domain |
| 11334 | openAddSupportModal | Add a support server |
| 12100 | openPinModal | Pin to a version |
| 13426 | openCreateSiteModal | New site on <instance> |
| 14428 | showWebhookSecretModal | webhook signing secret (see-once) |
| 14453 | openCreateWebhookModal | New webhook form |
| 14516 | openEditWebhookModal | Edit webhook form |
| 14587 | confirmDeleteWebhook | Delete this webhook? |
| 16671 | openSiteEnvModal | site env editor |
| 18572 | confirmDeploy | Deploy <domain>? |
| 18600 | openSiteGithub | GitHub repository picker (incl. its loading state) |
| 20111 | openLaunchModal | the launch wizard IN A MODAL (the in-page /new flow IS shot; the modal host is not) |
| 20666 | openCancelPlanModal | Cancel your plan? (password confirm) |
| 27553 | openInviteModal | Invite a team member |
| 27599 | revealInvite | Invitation sent + one-time link |
| 27699 | openRoleModal | Change role |
| 27795 | confirmRevokeInvite | Revoke invitation? |
| 28581 | openCommandPalette | the cmd-k palette (note: app.css carries `.modal-root:has(.cmdk)` rules that NO PNG exercises) |
| 29584 | openOffloadModal | Offload a task to a support server |

## Second-order blind spot, same cause
`app.css` has modal-scoped selectors `.modal-root:has(.cmdk)` (x2) and
`.modal-root:has(.am-modal)` (counted by modal-oracle.mjs: exact=1 substr=9).
Only the `.am-modal` arm is ever rendered into a PNG. The `.cmdk` arm is
covered by NO image at ANY accent.

## What DOES cover some of them, and what it does not measure
`__preview__/modal-oracle.mjs` drives 14 states via CDP (account-modal x6 states
x2 themes, tokens-reveal x2 themes x2 viewports) and so reaches `revealToken`
(6208) that the matrix cannot. But it asserts CSSOM/geometry only and takes NO
accent axis — it runs evergreen. It is therefore not accent evidence, and the
other 26 call sites are outside it too.

## The cheapest fix, stated so it can be filed
Promote the modal seam from a NAME CONVENTION to a `scenarios.mjs` FIELD
(e.g. `modal: "account" | "invite" | "cmdk" | ...`) and give mock.js a switch
over it, the way `drive2faBadCode` already works for one case. shoot.sh:334
already flags this as the intended follow-up ("Promote it to a scenarios.mjs
field once the tail zone is quiet.").
