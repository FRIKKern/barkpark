<!-- doc-tier: human | canonical-for: pe cold-agent run rubric pre-registration | budget: 5000tok -->

# The Cold-Agent Authoring Run — Pre-Registered Rubric

**Epic:** `task-4792223ca9eb5a7d` (Paper Excellence), criterion 2 — "Agent
authoring guidance ships so a cold agent produces a premium Paper."
**Status:** FROZEN. This file is the pre-registration for the cold-agent
authoring run (charter D46/D48/D49/D50). It must be committed and merged to
`origin/main` BEFORE the run; the run slice records this file's blob sha
(`git rev-parse origin/main:tooling/paper-excellence/RUBRIC.md`) in its ledger
evidence at run start. Any change to this file after that sha is recorded
VOIDS the run.

**Why pre-registration.** A warm agent acting cold is a vacuous green — the
exact defect this epic hunts. The bar, the instruments, the coldness
protocol, and the retry policy are all fixed here, in advance, so neither
the author, the harness operator, nor the judges can move the goalposts
after seeing the artifact.

**What is graded.** One Paper, authored by a genuinely cold agent through the
public door only (the slice-built `bp` binary + the SERVER-published guide at
`/papers/paper-authoring-excellence`), published to live guerrilla. Grading
has two tiers: a mechanical floor (commands, binary verdicts) and a judged
tier (two judges, agent choices only). Premium = the floor fully green AND
zero FAIL across the judged axes.

---

## Tier 1 — Mechanical floor (M1–M5)

Every check below is a command with a binary verdict, proven runnable on this
host 2026-08-17 (`tooling/grip/ledger/pe-w7-rig-binding-proof-2026-08-17.md`,
`tooling/grip/ledger/pe-w7-slice-binary-scaffold-proof-2026-08-17.md`).
macOS has no `timeout` binary — rig commands run unwrapped, never inside
`timeout`.

### M1 — Publish-wall pass (both refusal surfaces)

The cold agent's `bp paper push` against live guerrilla must succeed — the
create/publish arm returns success, never a 422. The wall the paper faces has
TWO refusal surfaces, and the floor names both:

1. **AuthoringWall** — LabelSpine (E1/E2: 2–4 weighted tags, distinct
   strengths, ≥20-char rationales), TagRegistry (E3: every tag registered),
   Dedup (E4 — ADVISORY in grading, proven under-firing; a dedup warning is
   never a FAIL). EpicQuality is INERT without the `epic-cycle-wave-paper`
   tag, which the cold agent must NOT use — a run that tags its paper as a
   wave paper is an agent defect (fail outright, see retry policy).
2. **Hollow** — the separate plugin halt on hollow/empty papers. Passing
   AuthoringWall alone is not a wall pass.

**unknown_tag pin (correction baked in).** At the validate DRY-RUN
(`POST /v1/plugins/bulldocs/papers/validate`, body `{"bpml":"<string>"}`, and
`bp paper push --check`), an unregistered tag is **HTTP 200 `valid:false`**
with a violations body — there is NO dry-run 422. Captured body (verbatim,
from the slice-binary-scaffold-proof ledger row):

```
HTTP 200 {"valid":false,"violations":[{"code":"unknown_tag",
  "message":"publish references unregistered tag(s): zzz-not-a-real-tag-9999",
  "hint":"Every tags[].tag must be a registered tag ...",
  "details":{"unknown":[...],"suggestions":{"zzz-...":["research-note"]}}}]}
```

The 422 exists only on the real publish/create arm. A grader expecting a
dry-run 422 is misreading the instrument, not catching a defect.

### M2 — Heavy-rule hygiene on the LIVE slug (census.mjs URL mode)

census.mjs measures ONLY heavy-rule hygiene (it does not measure CPL or
breakout width — that seam is settled, see M4/M5). It binds to the live
published slug directly:

```
node tooling/paper-excellence/rig/census.mjs \
  'https://guerrilla.barkpark.cloud/papers/<slug>' \
  --root 'main.bp-paper-article' \
  --structural '.bp-paper-surface > #paper-body > h2, .bp-paper-surface > #paper-body > div:not([class]) > h2' \
  --json
```

**PASS iff `strayHeavy == 0`** — every heavy (2px) rule attributes to an h2
section head. The `--structural` selector is pinned verbatim above (identical
to shoot.mjs:146 `STRUCTURAL_RULE_SELECTOR`); the root is
`main.bp-paper-article`. Reference: the live exemplar guide reports
total 35 / heavy 8 / structuralHeavy 8 / strayHeavy 0.

### M3 — Round-trip read-back

- `bp paper pull <slug>` succeeds against the published paper (the working
  copy round-trips).
- `bp paper view <slug>` renders the full block tree with ZERO `Unsupported`
  placeholders in its output.

### M4/M5 — CPL band, breakout honesty, doc overflow (fixture-from-live chain)

CPL and evidence-breakout width live in shoot.mjs behind gate.sh's hermetic
committed fixture — NOT in census.mjs. To bind them to the live paper,
materialise a scratch fixture from the live payload (the fetch-fixtures
transform, into a NON-committed dir) and gate that:

```
FIX=<scratch>/live-fixtures ; mkdir -p "$FIX"
bp doc get paper <slug> -o json | FIXTURE_DIR="$FIX" python3 -c '
import sys, json, os
d = json.load(sys.stdin)
if not d.get("blocks"): sys.exit("no blocks")
out = {"_id": d["_id"], "title": d["title"], "style": d.get("style"),
       "source_rev": d["_rev"], "blocks": d["blocks"]}
open(os.path.join(os.environ["FIXTURE_DIR"], d["_id"]+".json"),"w").write(
    json.dumps(out, indent=2, ensure_ascii=False, sort_keys=True)+"\n")'
SHOT_WIDTHS="1920,1280,768" bash tooling/paper-excellence/rig/gate.sh "$FIX/<slug>.json"
```

**PASS iff gate.sh exits 0 at SHOT_WIDTHS="1920,1280,768"**, which asserts:
prose CPL inside the band **[55,75]** (HOST-SCOPED — CPL numbers are
host-dependent; the band applies on the run host, never as a cross-host
absolute), evidence-breakout honesty (breakout components actually use the
band; max-width ≠ none), and doc overflow ≤ 4px at every gated width.

**360 is ADVISORY, pinned by measurement.** The default gate runs a 360px arm;
the LIVE exemplar guide itself FAILS it by 31px (scrollWidth 391 vs
clientWidth 360 — an unbreakable-token mobile overflow, filed as a guide
defect). `SHOT_WIDTHS="1920,1280,768"` is therefore the floor; a 360 overflow
is logged, never a run gate. Pinning bare `gate.sh` full-green would fail the
very exemplar the cold agent learns from.

---

## Tier 2 — Judged axes (J1–J5)

Judges grade AGENT CHOICES only. FRICTION §5 SYSTEMIC gaps (display scale,
wide band, prose tokens, numeric table discipline, dedup threshold) are
renderer properties — grading the agent on them is vacuous; they are covered
by the mechanical rig, not by judges. BESPOKE platform absences (clock-strip
tiles, stat-tile dots, code emphasis, cast chrome, framed panels) inform ONLY
J5's honest-degradation arm. Dedup stays advisory.

Scale per axis: **PASS / FAIL / NA** (NA only where the axis's subject
genuinely does not arise, with one line of justification). **Premium = ZERO
FAIL.** Numeric scales are BANNED: jarl-innleggene measured that numeric
consensus at K=2 never flags contested papers and median-of-two rounds up;
`tooling/quality/GRADE-CRITIQUE.md` documents the false-100 averaging defect.
An average cannot appear anywhere in the verdict.

| Axis | Grades | One-line FAIL exemplar |
|---|---|---|
| **J1 — Composition / structure** | The paper has an arc: masthead → thesis → sectioned argument → verdict; headings carve real sections; blocks appear where the argument needs them. | FAIL: a flat run of paragraphs with h2s used as bold text — no ingress, no sectioning logic, the "sections" could be shuffled without loss. |
| **J2 — Width allocation by component nature** | Wide-worthy components (tables, diagrams, casts, code) are authored as breakout evidence; prose stays in the column; nothing wide is crammed into the text measure. | FAIL: a six-column table locked to the prose column and scrolling inside itself while the breakout band sits unused beside it. |
| **J3 — Evidence-device curation** | Claims that carry data get the RIGHT device (table for comparisons, stats for headline numbers, code for source, diagram for flow) — chosen, not defaulted. | FAIL: measured results narrated as a paragraph of numbers where a table or stats block was the obvious device. |
| **J4 — Verdict / tone semantics** | Callout tones and verdict language mean something consistent (danger = loss/refuted, success = kept/proven, neutral = context) across the whole paper. | FAIL: a success-toned callout announcing a failure, or tones assigned decoratively so color stops meaning anything between blocks. |
| **J5 — Deck integrity + honest degradation** | The paper is built from the deck as documented — all TEN FRICTION §2 temptations live here (hand-rolled HTML, `body_html` masthead, pasted SVG, `data:` URIs, bare-string cells, spacer paragraphs, …). Where the deck cannot express a device, the loss is taken honestly (degraded + logged), never faked. | FAIL: any §2 temptation taken — e.g. raw HTML smuggled through `body_html`, or an empty-paragraph spacer authored for rhythm. |

**Aggregation rule.** TWO judges, both DISTINCT from the author (this
strengthens D46's single-different-agent), each grading independently;
verdicts combine by **pessimistic intersect** — any FAIL from either judge is
a FAIL on that axis. Counterweight against cheap FAILs: every FAIL must cite
(a) the axis's written FAIL exemplar above and (b) the specific capture
region (file + width + scheme + approximate crop) where the defect shows.
ONE evidence-remand is allowed — the author (or harness) may send a FAIL back
to the SAME judge with pointed evidence once; the judge's post-remand verdict
stands.

**Judging substrate.** Judges grade from the rig's rendered capture matrix
(shoot.mjs shots: SHOT_WIDTHS 1920/1280/768 × light/dark on the live-payload
fixture) — NEVER from the JSON payload. A judge who has read the block JSON
before the captures is contaminated for J1/J2.

**Block-variety floor.** ≥6 distinct block types, including ≥2 evidence
devices (table / stats / code / diagram / figure / asciicast / expandable)
where the subject carries data. A subject that genuinely carries no data may
NA the second-device clause with justification.

**Premium is not length.** A short paper can take top marks; padding toward
"impressiveness" is itself a J1 liability.

---

## Coldness protocol

The author is a genuinely FRESH OS process — in-session subagents are
structurally warm (host CLAUDE.md + auto-memory carry the authoring contract)
and forever forbidden:

- Spawn: `/Users/pelle/.local/bin/claude --bare --setting-sources ''` (the
  REAL binary by absolute path — the PATH `claude` is a cmux shim that
  injects OAuth) under `env -i`, scratch `HOME`, scratch `XDG_CONFIG_HOME`
  carrying only the minimal 5-field bp config
  (`server/token/workspace/project/dataset`), cwd OUTSIDE the repo.
- Model pinned explicitly: `--model` opus@medium for the author AND both
  judges (bare defaults elsewhere; the pin holds regardless of the run
  slice's model tag).
- `--bare` mandatorily requires `ANTHROPIC_API_KEY` — keychain OAuth is never
  consulted under bare. No valid key exists on this host: provisioning one is
  the HUMAN pre-run gate `pe-w7-hg-anthropic-key`, and a real-key green spawn
  must be verified before the run counts as ready.
- The prompt carries ONLY: the path to the slice-built bp binary, the guide
  slug `paper-authoring-excellence`, and the instruction to publish a paper.
  No wave map, no FRICTION.md, no charter, no epic ids.
- bp builds from the branch as
  `CGO_ENABLED=0 CC=/usr/bin/clang go build -o bp ./cmd/barkpark`
  (repo-root build fails "no Go files"; the `cc` alias shadows the compiler).
- Evidence: the FULL transcript (stream-json JSONL) is committed, the guide
  rev is pinned in the run evidence, and the transcript is audited against
  the allowlist below.

### Sanctioned-read allowlist — derived at run start, never hardcoded

The guide's own text sanctions specific reads (it instructs pulling the
epic's wave-2 Paper as the worked example — a hardcoded "any non-guide read
fails" rule would fail every honest run). The allowlist is therefore DERIVED
from the LIVE guide text at run start:

```
bp paper view paper-authoring-excellence | sed -n '/The worked example/,/render-only study/p'
```

As of 2026-08-17 the closed sanctioned set is:

1. `paper-authoring-excellence` — the door itself;
2. `paper-excellence-wave-2026-08-17` — the worked example the guide
   sanctions verbatim;
3. `eight-minute-erasure` — render-only study named by the guide (pull 422s
   by design);
4. the agent's OWN created slug(s) — read-back is a rubric requirement (M3);
5. non-content commands: `bp capabilities`, `bp doc ls tag [--all]` (tag
   names only — the wall-enforced registry).

**Everything else fails the run** — explicitly including `bp search` (corpus
snippets are the answer key: the admin token can read this rubric's twin
sources, a channel with no tooling fix, closed by this audit) and EVERY
`bp task` verb. The audit is a transcript scan of every bp invocation against
the derived set; one off-allowlist read = the run is not cold.

---

## Retry policy

The full policy, fixed in advance — no retry class may be invented after a
failure is seen:

| Class | Definition | Allowance |
|---|---|---|
| **Door defect** | The door itself is broken — guide instruction wrong, wall refusing a compliant payload, scaffold emitting an invalid starter. | ONE fresh-agent rerun under the UNCHANGED rubric sha. The defect is filed against the door; the rerun is a new cold agent, never the same transcript resumed. |
| **Agent defect** | The cold agent authors badly or violates protocol — off-allowlist read, `epic-cycle-wave-paper` tag, wall refusal on its own payload it cannot fix through the door. | FAIL OUTRIGHT. No rerun. The run is graded as-is and the epic criterion is NOT stamped. |
| **Harness void** | The harness breaks before the agent produces work — spawn failure, key rejection, network loss mid-setup. | Cap of TWO voids for the whole campaign. **Bright line: a void is valid ONLY if the agent produced ZERO authored bp writes.** Any authored write (create/push/publish of its own slug) means the run is GRADED, never voided — voiding a run that wrote is rerun-until-pass by another name. |
| **Instrument break at grade** | census/gate/shoot or the capture matrix fails AFTER a completed authored run. | Grade-side VOID: fix the instrument, then re-grade the SAME artifact. The author is never re-run for a grader's broken instrument. |

A rubric pass = mechanical floor fully green + zero FAIL from the pessimistic
intersect of both judges. Only then is epic criterion 2 stamped
(re-claim → stamp with the verbatim stored criterion text and the full
evidence chain: rubric sha · transcript path · slug · rig output · both
judges' verdicts → bare close, per D51). `--set criteria_override` is
FORBIDDEN — that is the self-graded vacuous green this epic exists to kill.
