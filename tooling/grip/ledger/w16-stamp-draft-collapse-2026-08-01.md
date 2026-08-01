# Re-derivation recipes — v-stamp-draft-collapse (cch wave 16 verify, 2026-08-01)

Target of record: `https://guerrilla.barkpark.cloud`, `bp` build `f59aaf717`
(`bp --version`), repo `origin/main` = `c48fb17d5`.

Headline: the draft-collapse that reverts a stamped criterion is **already
fixed and live**. `bp doc publish` on a task whose published row holds a
`met: true`/non-blank-evidence criterion the draft does not is REFUSED 422.
`bp task close` is refused on a second, independent axis (lifecycle) and a
third (claim map). `pds-bl-stamp-writeback-reverts-a-stamped-criterion` and
`cch-w15-bl-stamp-merger-silently-drops-evidence` are STALE-OPEN rows.

## R1 — name the fix on origin/main (never the primary checkout: it is 253 behind)

```bash
cd /Volumes/SATECHI/github/barkpark
git log origin/main --oneline -S'criteria_regression_error' -- api/lib/barkpark/content/lifecycle.ex
# 71a177742 fix(publish-door): a publish can no longer erase a landed stamp (#8283)
git show origin/main:api/lib/barkpark/content/lifecycle.ex | sed -n '355,400p;450,470p'
git rev-list --count HEAD..origin/main    # 253 — the worktree does NOT contain the fix
```

## R2 — name the collapse itself, and the CAS that is absent

```bash
git show origin/main:api/lib/barkpark/content/lifecycle.ex |
  grep -n 'pub_attrs =\|prev_pub_rev\|Repo.update()\|fenced_delete(draft)\|Writer.generate_rev'
# 160 pub_attrs =                     <- built WHOLESALE from the draft's content
# 168   "rev" => Writer.generate_rev()
# 177   existing |> Document.changeset(pub_attrs) |> Repo.update()   <- no rev filter
# 192   fenced_delete(draft)           <- the ONLY rev fence, and it fences the DRAFT
```
`prev_pub_rev` is read at :177 but only forwarded to the broadcast (:207). There
is no CAS on the PUBLISHED row anywhere in `publish_document/4`. The fix is a
semantic pre-gate (`gate_task_publish/2`), not a rev fence.

## R3 — drive the refusal end to end (the CLI hides `details`; curl does not)

```bash
SRV=https://guerrilla.barkpark.cloud
TOK=$(python3 -c 'import json;print(json.load(open("'"$HOME"'/.config/barkpark/config.json"))["token"])')
T=$(bp task create --title 'THROWAWAY draft-collapse verify' -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["id"])')
# publish wall: needs a >=N-char `description` AND `tags` (NOT `labels`), every
# tag already registered as a type:tag doc, all strengths distinct.
bp doc patch task $T \
  --set description='Throwaway verification task for the draft-collapse reproduction.' \
  --set 'tags:=[{"tag":"tasks","strength":90,"rationale":"exercises the stamp and publish write paths"},{"tag":"barkpark","strength":40,"rationale":"throwaway ledger doc"}]' \
  --set 'acceptance_criteria:=[{"criterion":"C1","met":false,"evidence":""},{"criterion":"C2","met":false,"evidence":""}]' --yes
bp doc publish task $T --yes
bp task claim $T verify-w16
bp task stamp $T verify-w16 1 --criterion 0 --met --evidence PRE --criterion-text 'C1'
bp doc patch task $T --set design='mints a draft while the claim is live' --yes   # DRAFT forks here
bp task stamp $T verify-w16 1 --criterion 1 --met --evidence POSTDRAFT --criterion-text 'C2'
curl -s -X POST "$SRV/v1/data/mutate/production" -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' \
  -d "{\"mutations\":[{\"publish\":{\"id\":\"$T\",\"type\":\"task\"}}]}" | python3 -m json.tool
# -> 422 validation_failed, details.acceptance_criteria[0] names index 1 and "C2".
bp doc delete task $T --yes
```

## R4 — read BOTH twins; `bp doc get` cannot see a draft

```bash
bp doc query task --filter "_id in drafts.$T,$T" --perspective raw -o json
```
`bp doc get task drafts.$T` returns `not_found`, and `--filter "_id == 'x'"` is a
400-class no-match (the operator is `=`, not `==`). Reading only `bp doc get`
makes a live stale draft invisible — that is how this class hides.

## R5 — close is refused on a DIFFERENT axis (prove it separately)

```bash
# with a fresh draft minted while in_progress, then:
bp task close $T verify-w16 <epoch> done '…' --set observed_rev=<rev>
curl … publish …   # -> 422 details.lifecycle_status: illegal transition "done" -> "in_progress"
# then set the draft to open and retry:
bp doc patch task $T --set lifecycle_status=open --yes
curl … publish …   # -> 422 details.claim: stale draft, published carries worker/epoch this draft does not
```

## R6 — stamp-vs-stamp does NOT lose a write (the filed hypothesis, refuted)

```bash
bp task stamp $T w <e> --criterion 0 --met --evidence 'MET-idx0' --criterion-text 'C1 one' &
bp task stamp $T w <e> --criterion 1 --miss --note 'MISS-idx1' &
wait; sleep 1; bp task get $T -o json | python3 -c '…print each row…'
# Both land: idx0 carries MET-idx0, idx1 carries the MISS-idx1 attempt.
```

## R7 — the two residual rows the fix names in writing

```bash
git show origin/main:api/lib/barkpark/content/lifecycle.ex | grep -n ':sync'      # 310: exemption BEFORE every gate
git show origin/main:api/lib/barkpark/plugins/github/link.ex | grep -n 'source:'  # :github, NOT :sync -> COVERED
```
`pds-bl-sync-source-bypasses-publish-door` is real and open.
`pds-bl-github-linkput-auto-publish-erasure` is refuted by the fix's own review
commit and by the grep above — a cancel candidate for the stale-open audit.
