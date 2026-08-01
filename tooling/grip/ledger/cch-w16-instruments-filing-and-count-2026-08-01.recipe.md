# cch-w16 — instruments filing law + the no-net-growth denominator (re-derivation recipe)

Written by the wave-16 verifier `v-instruments-filing-and-count`. Not committed by this phase.

## 1. The seal predicate's OWN denominator for `cloud-console-hardening-epic`

`cloud/priv/static/__preview__/seal-predicate.mjs:231` is the roster read:
`fetchRoster = (parentId) => q([['filter[parent_id]', parentId], ['limit','500']]).result.documents`
against `GET /v1/data/query/production/task` (published perspective). Reproduce it verbatim:

```
curl -sG "https://guerrilla.barkpark.cloud/v1/data/query/production/task" \
  --data-urlencode "filter[parent_id]=cloud-console-hardening-epic" \
  --data-urlencode "limit=500" -H "Authorization: Bearer $BP_TOKEN" \
| python3 -c "import json,sys,collections;d=json.load(sys.stdin);x=d['result']['documents'];print(len(x),collections.Counter(c.get('lifecycle_status') for c in x))"
```

Measured 2026-08-01T04:5x UTC: **196 published children — done 112, open 65, cancelled 18, considering 1.**
LIVE (`LIVE_STATUSES = ['open','in_progress']`, :113) = **65**. `PENDING_STATUSES = ['considering']` (:114) = **1**.
Zero `drafts.*` in the roster, as D105 predicts.

`bp task get cloud-console-hardening-epic` reports `child_count 200` and 200 children — it INCLUDES four
`drafts.*` twins (`drafts.cch-bl-floor-is-blind-and-uncalled`, `drafts.cch-bl-required-checks-floor-blind-uncalled`
[both cancelled], `drafts.cch-w15-s5-site-open-phone-overflow`, `drafts.cch-w15-s5-site-link-phone-width`
[both open]). **Quoting 200, or an open count of 67, overstates by exactly the drafts.** Law 0's number is 65.

## 2. Filing WITH `parent_id` at CREATE time under `cch-instruments-epic` — LEGAL, PROVEN

```
bp task create "<title>" --set parent_id=cch-instruments-epic --set _id=<id> --publish --yes -o json
```

The `--publish` in the same call FAILS the label spine (422 `label_spine`) — the row is created as a draft
anyway. The working sequence is create → `bp doc patch` a description + 1-12 **registered** weighted tags
each carrying a `rationale` → `bp doc publish`. Tags must already exist as `type:tag` docs; the 422
(`publish references unregistered tag(s): …`) ships an EMPTY `details` object, so the suggestion list the
hint promises is not delivered. Enumerate real ones with
`curl -sG .../v1/data/query/production/tag --data-urlencode limit=40`; `cloud-console-hardening` and
`named-successor` are registered and were used here.

Read-back after publish: `_id=cch-w16-verify-throwaway-parent-probe parent=cch-instruments-epic
lifecycle=open`, and the successor roster went 72 → 73 with the probe present. **Nothing was re-parented.**

Cancelling: there is NO `bp task cancel` verb, and `bp doc patch --set lifecycle_status=cancelled` is
refused (`validation_failed`) — a following `bp doc publish` then 404s "document not found", which reads as
a lost write but is actually the refused patch leaving no draft. The sanctioned kill is
`bp task claim <id> <worker>` then `bp task close <id> <worker> <epoch> cancelled "<reason>"`.
The probe is `cancelled`. NOTE: `child_count` stays 73 — cancelled rows still count, so `child_count` is
never the live denominator.

## 3. `cch-w12-bl-filing-law-parent-charter-half` — adjudicated on CRITERIA, and it SURVIVES

```
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | sed -n '24,36p'
git show origin/main:.claude/workflows/bp-cloud-console-hardening-charter.md | grep -c 'cch-instruments-epic' # Law 0 body: 0
git cat-file -e origin/main:.claude/workflows/bp-cloud-console-instruments-charter.md  # exits 128
```

Its TITLE ("the filing law is … NOT into the parent charter") IS refuted — Standing Law 0 is on origin/main
at `:24-35` in full. Its THREE CRITERIA are all still unmet:

- (1) Law 0 must route residue to the TASK ID `cch-instruments-epic`. On main it routes to the FILE PATH
  `bp-cloud-console-instruments-charter.md`, which `git cat-file -e` fatals on (128). UNMET.
- (2) Law 0 must carry the residue MEASUREMENT PROTOCOL (count at first claim and at debrief; a net-positive
  wave states the number and names what it repays). Absent from `:24-35`; the only hits for those terms on
  main are D172/D160 prose in the decisions table, not the law. UNMET.
- (3) The two charters' filing-law sections compared. Blocked by construction on unmerged PR #8500. UNMET.

Adjudication: **NOT a free close.** It is a two-line charter EDIT (criteria 1+2 are producible from
origin/main today, independent of #8500) plus a criterion-3 amendment that stays blocked.

## 4. Does any script resolve `.claude/workflows/bp-cloud-console-instruments-charter.md`?

```
grep -rn 'instruments-charter' tooling .github               # 1 hit, PROSE only
grep -rn 'instruments-charter' --include='*.sh' --include='*.mjs' --include='*.js' \
  --include='*.cjs' --include='*.yml' --include='*.yaml' --include='*.py' --include='*.go' \
  --include='*.ex' --include='*.exs' . | grep -v node_modules | wc -l   # 0
```

**Zero executable references.** The only `tooling/` hit is prose:
`tooling/grip/ledger/cch-w14-gate-baseline-2026-07-31.md:80`. The only other tracked hit is the parent
charter itself. `.github/` has none. The dangling pointer breaks a COLD AGENT, not a gate — no build,
sweep, or required-checks path resolves it, so merging #8500 is a doc-currency fix with zero CI coupling.
