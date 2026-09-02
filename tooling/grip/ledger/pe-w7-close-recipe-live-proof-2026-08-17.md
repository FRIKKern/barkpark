<!-- doc-tier: cold | canonical-for: pe-w7-close-recipe-live-proof | budget: 1200tok -->
# pe-w7 close-recipe live proof — re-derivation recipe

> HISTORICAL RECORD (2026-08-17) — the commands below were run on that date. Re-run them to re-derive; never quote the recorded output as current.

Proven live against guerrilla.barkpark.cloud on 2026-08-17 with bp commit a653550420
(build 2026-08-17T08:42:54Z). Throwaway probe task-a9b0555e510ad4f5 (published, closed done 2/2).

## The proven close choreography (survey recipe was BROKEN)

The survey's `bp task close ... --set 'criteria:=[{"index":1,"met":true,"evidence":"probe"}]'`
does NOT work. TWO independent guards reject it:

1. `--set criteria` with `met:true` requires the verbatim `criterion` text too, same as stamp:
   `bp: every criteria entry with met=true must carry its "criterion" — the exact stored wording`
2. Even WITH the text, the close refuses to count a criterion flipped in the same close command:
   `bp: acceptance criteria N are not met on the task AS STORED, and criteria flipped in this
   very close command do not count — that would be the closer grading its own homework.`
   (exit 2). Escape hatch on the record: `--set criteria_override="<why done anyway>"`.

CORRECT sequence — stamp every criterion FIRST, then a bare close:

```
bp task create "<title>" --publish --description "<20+ chars>" \
  --set 'acceptance_criteria:=[{"criterion":"<c0>","met":false},{"criterion":"<c1>","met":false}]' \
  --set 'tags:=[{"tag":"<REGISTERED-tag>","strength":80,"rationale":"<20+ chars>"}, ...]' \
  --set priority:=4              # priority MUST be int 0..4 (0=highest); 5 rejected
# publish wall (label spine) requires: non-trivial description + 1-12 weighted tags,
# each {tag, strength 1-100 ALL DISTINCT, rationale >=20 chars}, and every tag REGISTERED
# (a type:tag doc must exist — unregistered => 422 unknown_tag). Find tags: bp doc ls tag --all

bp task claim <id> <worker>            # prints "epoch=N"; epoch read from claim.epoch
bp task stamp <id> <worker> <epoch> --criterion 0 --met \
  --criterion-text "<acceptance_criteria[0].criterion, VERBATIM>" --evidence "<non-empty>"
bp task stamp <id> <worker> <epoch> --criterion 1 --met \
  --criterion-text "<acceptance_criteria[1].criterion, VERBATIM>" --evidence "<non-empty>"
bp task close <id> <worker> <epoch> done "<summary>"    # bare; all met AS STORED
```

## Facts proven

- `--met` REQUIRES `--criterion-text`: omitting it => error, no write (message: "--met requires
  --criterion-text"). Wrong text => "the criterion text you passed is NOT the wording stored".
- STAMP does NOT bump claim.epoch. Before stamp epoch=2; after two stamps epoch STILL 2; only
  `rev` changes. So the SAME epoch from the original claim is used for both stamps AND the close.
- criteria live at `doc.content.acceptance_criteria[N].criterion` (NOT top-level
  `acceptance_criteria`, which reads null via `bp task get -o json`). claim at `doc.claim.epoch`.
  progress mirror at `doc.criteria_progress = {met, total}`.
- Exit codes ARE reliable UNPIPED: a failing stamp exits 5, a failing close exits 2. Piping to
  `head` masks it to 0 (the pipe's rc is head's). Never `bp task ... | head` in a gating chain.

## Rerun

```
bp capabilities -o json | python3 -c "import sys,json;[print(c[0],c[1],'::',c[2]) for c in json.load(sys.stdin)['commands'] if c[0]=='task' and c[1] in ('stamp','close')]"
# then reproduce the create→claim→stamp→stamp→close sequence above on a fresh throwaway.
```
