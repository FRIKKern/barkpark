# pe-w7 rubric-freeze inputs — re-derivation recipes (2026-08-17)

Verifier: rubric-freeze-inputs (fable), Paper Excellence wave 7. Each fact below
re-derives from scratch with the quoted command; quote nothing above the level
its command supports.

## 1 · RUBRIC.md path ruling — literal charter path wins

- D46's only literal path string: `tooling/paper-excellence/RUBRIC.md`.
  Re-derive: `git show origin/main:.claude/workflows/bp-paper-excellence-charter.md | grep -n 'D46'`
- The run task pins the same path in `files[]` AND glosses "beside twin/FRICTION.md"
  in its description — "beside FRICTION.md" was always a gloss, not a second path.
  Re-derive: `bp task get pe-bl-cold-agent-run -o json | python3 -c "import json,sys; d=json.load(sys.stdin)['doc']['content']; print(d['files'])"`
- FRICTION.md itself lives at `tooling/paper-excellence/twin/FRICTION.md` (wave-1
  twin artifact dir, doc-tier human).
  Re-derive: `git ls-tree -r origin/main --name-only | grep FRICTION`
- The recorded sha binds `origin/main:tooling/paper-excellence/RUBRIC.md`:
  `git rev-parse origin/main:tooling/paper-excellence/RUBRIC.md`

## 2 · Sanctioned-read allowlist for the transcript audit — derived from the LIVE guide

The guide's own text instructs the cold agent to pull the epic's wave-2 Paper as
the worked example. An audit rule "any bp read of a non-guide slug fails" fails
every honest run. The allowlist derives from the live guide and MUST be
re-derived at run start (the guide can drift):

    bp paper view paper-authoring-excellence | sed -n '/The worked example/,/render-only study/p'

As of 2026-08-17 the closed sanctioned set is:
- `paper-authoring-excellence` (the door)
- `paper-excellence-wave-2026-08-17` (worked example, "rev 64c4f57692cd54d61d304189dee094e2
  at the time of writing" — pull sanctioned by the guide verbatim)
- `eight-minute-erasure` (render-only study named by the guide; pull 422s by design)
- the agent's OWN created slug(s) (read-back is a rubric requirement)
- non-content: `bp capabilities`, `bp doc ls tag [--all]` (tag names only — the
  wall-enforced registry of 193; re-derive: `bp doc ls tag --all | wc -l`)

Everything else fails the audit — explicitly including `bp search` (corpus
snippets are the answer key) and every `bp task` verb.

## 3 · Jarl-innleggene grade-scale grounds

- Rubric shape: 7 dimensions, PASS/FAIL/NA, premium = zero FAIL, never an
  average; judged on the RENDERED page in QUAD {2 widths}×{light,dark}; 2
  independent judges, pessimistic K=2 (any FAIL is FAIL); numeric consensus
  BANNED (band=25 never flags contested on 1–5; median-of-two rounds up).
  Re-derive: `bp paper view jarl-innleggene-wave-2026-08-02 | sed -n '/Avgjørelsene/,/Bølgeplanen/p'`
  and the consensus-k2 verify bullet in the same paper.
- False-100 averaging critique exists at `tooling/quality/GRADE-CRITIQUE.md`:
  `git cat-file -e origin/main:tooling/quality/GRADE-CRITIQUE.md && echo yes`

## 4 · Rig capture matrix already carries the QUAD unit

shoot.mjs default `SHOT_WIDTHS = 1920,1280,768,360` × `SCHEMES = [light, dark]`;
census.mjs is file-or-URL.
Re-derive: `git show origin/main:tooling/paper-excellence/rig/shoot.mjs | sed -n '33,45p'`
and `git show origin/main:tooling/paper-excellence/rig/census.mjs | sed -n '1,6p'`

## 5 · FRICTION.md counts the rubric maps against

§2 = exactly TEN temptations (numbered 1–10); §5 = TWELVE ranked gaps, classes
SYSTEMIC (1,2,5,6,10,12) / BESPOKE (3,4,7,8,9,11); gap 12 (dedup wall) is
ADVISORY per D46 and must not be a judged axis.
Re-derive: `git show origin/main:tooling/paper-excellence/twin/FRICTION.md | grep -c '^[0-9]*\. \*\*'`
(temptations) and the §5 table rows.
