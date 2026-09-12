<!-- doc-tier: cold | canonical-for: pe-w2-blockless-wave-papers re-measurement 2026-09-10 | budget: 4000tok -->

# pe-w2 · the 41 blockless wave Papers — re-measured 2026-09-10

Row `pe-w2-bl-blockless-wave-papers`. Filed 2026-08-17 off
`tooling/grip/ledger/pe-w2-guerrilla-live-writes-2026-08-17.md` §C.1, which measured
**41 published papers with no `blocks`, no `body_html`, only a legacy `body` doc →
41/41 HTTP 422** via `Papers.reader_source/3 → {:error, :semantic_empty}`.

**Verdict today: the population is ZERO. No repair write was needed or made in this
pass.** Both halves of the row were already discharged by work that landed between
2026-08-08 and 2026-09-03. This file is the durable venue the criterion asks for.

## 1 · Re-measurement (guerrilla, 2026-09-10)

`BASE=https://guerrilla.barkpark.cloud` (from `bp capabilities -o json .server.base_url`).

### Whole-corpus sweep — the strongest form of the claim

    bp doc query paper --fields _id --limit 1000 [--offset 1000] -o json   # 1048 published papers
    while read -r p; do echo "$(curl -s -o /dev/null -w '%{http_code}' $BASE/papers/$p) $p"; done < allids.txt

    $ awk '{print $1}' sweep-all.txt | sort | uniq -c
       1048 200

**1048 of 1048 published papers answer 200. Zero 422 anywhere in the corpus.**

### The named population — deploy-reliability-wave-5..34 + cch/cloud-console-hardening-wave-34..56

The row names two slug ranges. Enumerated against the live id list they yield **53
slugs** (a superset of the 41 — the original 41 was the subset that was then dark).
All 53 were fetched (`bp doc get paper`) and read (`GET /papers/<slug>`):

    $ awk '{print $1}' named-reader.txt | sort | uniq -c
         53 200

Reader-edge spot checks, 5 slugs across both epics: `GET /papers/<slug>/source` → **200 ×5**.
`bp paper view deploy-reliability-wave-27-2026-08-09` prints prose ("The crown is hollow — deploy-reliability wave 27 …").

`200` alone is not `readable`, so prose was measured too: strip tags inside `<article>`,
collapse whitespace, count characters. **Minimum across all 53 slugs: 65,003 chars
(`cloud-console-hardening-wave-41-2026-08-07`); maximum 96,038
(`deploy-reliability-wave-27-2026-08-09`). None below 500. None with both
`blocks == nil` and `body_html == nil`.** Three slugs (deploy-reliability-wave-27,
-28, -29) carry no `blocks` but a populated `body_html` and serve their prose off that
path — legitimately readable, deliberately left alone.

| slug | HTTP | blocks | body_html bytes | rendered prose chars |
|---|---|---|---|---|
| `cch-wave-34-2026-08-06` | 200 | 101 | 80596 | 80458 |
| `cch-wave-35-2026-08-06` | 200 | 80 | 67718 | 70140 |
| `cch-wave-36-2026-08-06` | 200 | 110 | 81892 | 84107 |
| `cch-wave-37-2026-08-06` | 200 | 139 | 77423 | 80779 |
| `cch-wave-38-2026-08-07` | 200 | 103 | 87860 | 82339 |
| `cch-wave-39-2026-08-07` | 200 | 109 | 81109 | 80840 |
| `cch-wave-40-2026-08-07` | 200 | 88 | 79482 | 81796 |
| `cch-wave-50-2026-08-07` | 200 | 87 | 77527 | 78217 |
| `cloud-console-hardening-wave-41-2026-08-07` | 200 | 72 | 57857 | 65003 |
| `cloud-console-hardening-wave-42-2026-08-07` | 200 | 85 | 64587 | 72197 |
| `cloud-console-hardening-wave-43-2026-08-07` | 200 | 110 | 78230 | 72015 |
| `cloud-console-hardening-wave-44-2026-08-07` | 200 | 113 | 70297 | 76409 |
| `cloud-console-hardening-wave-45-2026-08-07` | 200 | 91 | 67392 | 72920 |
| `cloud-console-hardening-wave-46-2026-08-07` | 200 | 94 | 76109 | 77345 |
| `cloud-console-hardening-wave-47-2026-08-07` | 200 | 112 | 93068 | 87616 |
| `cloud-console-hardening-wave-48-2026-08-07` | 200 | 99 | 93148 | 89466 |
| `cloud-console-hardening-wave-49-2026-08-07` | 200 | 101 | 83147 | 88422 |
| `cloud-console-hardening-wave-51-2026-08-08` | 200 | 95 | 81540 | 81448 |
| `cloud-console-hardening-wave-52-2026-08-08` | 200 | 96 | 71647 | 75065 |
| `cloud-console-hardening-wave-53-2026-08-08` | 200 | 97 | 84105 | 88465 |
| `cloud-console-hardening-wave-54-2026-08-08` | 200 | 99 | 79954 | 84377 |
| `cloud-console-hardening-wave-55-2026-08-08` | 200 | 79 | 71153 | 72617 |
| `cloud-console-hardening-wave-56-2026-08-08` | 200 | 99 | 78497 | 80216 |
| `deploy-reliability-wave-5-2026-08-06` | 200 | 97 | 82542 | 78264 |
| `deploy-reliability-wave-6-2026-08-06` | 200 | 81 | 70616 | 77067 |
| `deploy-reliability-wave-7-2026-08-07` | 200 | 111 | 77781 | 80119 |
| `deploy-reliability-wave-8-2026-08-07` | 200 | 123 | 82067 | 80449 |
| `deploy-reliability-wave-9-2026-08-07` | 200 | 92 | 78901 | 79756 |
| `deploy-reliability-wave-10-2026-08-07` | 200 | 119 | 86156 | 85519 |
| `deploy-reliability-wave-11-2026-08-07` | 200 | 82 | 71765 | 75950 |
| `deploy-reliability-wave-12-2026-08-07` | 200 | 95 | 80209 | 83847 |
| `deploy-reliability-wave-13-2026-08-07` | 200 | 117 | 87593 | 87334 |
| `deploy-reliability-wave-14-2026-08-07` | 200 | 99 | 72570 | 78620 |
| `deploy-reliability-wave-15-2026-08-07` | 200 | 146 | 86803 | 86612 |
| `deploy-reliability-wave-16-2026-08-07` | 200 | 88 | 76246 | 80702 |
| `deploy-reliability-wave-17-2026-08-07` | 200 | 97 | 82501 | 81113 |
| `deploy-reliability-wave-18-2026-08-07` | 200 | 77 | 79484 | 84164 |
| `deploy-reliability-wave-19-2026-08-07` | 200 | 113 | 88173 | 92672 |
| `deploy-reliability-wave-20-2026-08-08` | 200 | 103 | 90437 | 94381 |
| `deploy-reliability-wave-21-2026-08-08` | 200 | 70 | 61785 | 69356 |
| `deploy-reliability-wave-22-2026-08-08` | 200 | 92 | 77313 | 84162 |
| `deploy-reliability-wave-23-2026-08-08` | 200 | 137 | 86113 | 90791 |
| `deploy-reliability-wave-24-2026-08-08` | 200 | 116 | 71159 | 74249 |
| `deploy-reliability-wave-25-2026-08-08` | 200 | 93 | 87370 | 85236 |
| `deploy-reliability-wave-26-2026-08-09` | 200 | 81 | 81841 | 80388 |
| `deploy-reliability-wave-27-2026-08-09` | 200 | 0 | 90521 | 96038 |
| `deploy-reliability-wave-28-2026-08-09` | 200 | 0 | 82973 | 89121 |
| `deploy-reliability-wave-29-2026-08-09` | 200 | 0 | 61573 | 71993 |
| `deploy-reliability-wave-30-2026-08-09` | 200 | 80 | 77293 | 77838 |
| `deploy-reliability-wave-31-2026-08-09` | 200 | 66 | 73530 | 76230 |
| `deploy-reliability-wave-32-2026-08-09` | 200 | 94 | 65776 | 67375 |
| `deploy-reliability-wave-33-2026-08-09` | 200 | 105 | 83961 | 80325 |
| `deploy-reliability-wave-34-2026-08-10` | 200 | 83 | 64254 | 66914 |

### The shipped repair tool, dry-run over all 53 — the fidelity proof

`200` and a character count still do not prove the prose is the ORIGINAL prose. The
converter that shipped with `c2de1e51c` re-derives the text from the legacy `body`
ProseMirror source and diffs it against the blocks actually stored, so its own dry-run
is the stronger instrument. Run from the worktree, no `--apply`:

    $ node tooling/paper-repair/repair-paper-blocks.mjs $(cat named.txt | tr '\n' ' ')
    ; exit=0, 53 slugs

    $ grep -E '^  [A-Z]' dryrun.txt | sed 's/[0-9][0-9]*/N/g' | sort | uniq -c
       3   REFUSE html_only paper — it renders today; writing blocks would arm its divergence 422
      50   VERIFY already carries a top-level blocks list (N blocks) · body text identical (N chars) · reader 200

**50/53: blocks present, body text IDENTICAL to the legacy ProseMirror source, reader 200.**
**3/53: deploy-reliability-wave-27/-28/-29 — the tool REFUSES them by design** (`html_only`:
they serve their prose off `body_html`, and writing `blocks` over them would arm the
`:divergent` 422 they currently dodge). Those three are readable — measured above at
96,038 / 89,121 / 71,993 chars of rendered prose — and are correctly left alone.
**Zero slugs had anything to repair. Nothing was written.**

### Controls (a uniform 200 is also what a broken instrument prints)

| control | command | result |
|---|---|---|
| the reader is not blanket-200 | `curl -o/dev/null -w %{http_code} $BASE/papers/studio-w21-no-such-paper-xyz` | `404` |
| the 422 arm is still live in code | `api/lib/barkpark_web/live/bulldocs_live.ex:74` | `defexception [:message, plug_status: 422]` |
| the `:semantic_empty` classifier still fires | `api/lib/barkpark/content/papers.ex:174` | `Hollow.hollow?(blocks) -> {:error, :semantic_empty}` |
| **the producer defect can no longer reproduce** | published a deliberately body-only paper (`{"body":{"type":"doc","content":[…]}}`) to guerrilla via `bp doc mutate --yes` | **refused**, see below |

    $ bp doc mutate --file ctl.json --yes -o json
    {"error":{"code":"halted","message":"This paper's body is in a shape no reader can
     read (Content.Papers.reader_source/3 classifies it as semantic_empty). A paper body
     must present a block list — content.blocks, content.body.blocks, content.body as a
     list of blocks, or content.body as a markdown string — or a non-blank
     content.body_html. A ProseMirror document node, a bare {"content": [...]} wrapper,
     and a null body with nodes parked at content.content are none of those …"},"ok":false}
    $ bp doc get paper studio-w21-blockless-control -o json
    {"error":{"code":"not_found", …},"ok":false}

Nothing landed. The exact 2026-08 dialect is now rejected at write time by the live server.

## 2 · Producer audit

**The producer is a prompt, not code.** Both epics ran `.claude/workflows/bp-epic-cycle.workflow.js`;
the workflow never posts a paper itself — its `PAPER_BLOCK` constant instructs the agent,
which hand-writes the mutation. The pre-fix `PAPER_BLOCK` said *"write/extend the **body**
via the HTTP /v1/data/mutate path (patch merges into content)"* and used the word `blocks`
**zero times**. An agent following it patches `content.body = {"type":"doc","content":[…]}`
— a ProseMirror node, which `PortableDoc.Projection.read_blocks/1` matches none of its four
accepted shapes for, so it returns `nil` → no `body_html` → `:semantic_empty` → 422.

Honest caveat: **no commit dated 2026-08-05/06 introduced the wording.** It is unchanged
back to `607584bd9` (2026-07-10). The window's *start* is dialect drift inside the two
epics then running, not a code regression — the filing's implied "a defect landed 08-06"
is not supported by the tree. The window's *end* is explained:

| sha | date | what it did |
|---|---|---|
| **`a64f036e3`** | 2026-08-09 | `fix(epic-cycle): PAPER_BLOCK mandates top-level blocks + a read-back that can fail (cch-w57-s7) (#11079)` — **the producer fix.** Adds "THE BODY IS A TOP-LEVEL `blocks` ARRAY — nothing else renders … NEVER `body.content`", the `value`-keyed inline leaf rule, and a read-back obligation that fails the phase. Fix date 08-09 vs. population last day 08-10. |
| `7812ea887` | 2026-08-12 | derived read-back host (`bp capabilities` base_url) + enforced paper-wall dialect (#11604) |
| **`c2de1e51c`** | 2026-08-09 | `fix(papers): repair ProseMirror-bodied papers with a reusable blocks converter (#10946)` — ships `tooling/paper-repair/{prosemirror-to-blocks,repair-paper-blocks}.mjs`: dry-run by default, refuses `html_only` rows, aborts on any whitespace-normalised text mismatch, re-reads and curls after `--apply`. **The repair tool this row asked for already exists — a second one was not written.** The bulk apply over the remaining rows was a data write, so it is correctly absent from git. |
| **`21b4547f4`** | 2026-09-03 | `fix(bulldocs): refuse a paper body no reader can read, at write time (#15802)` — `api/lib/barkpark/plugins/bulldocs/readable_body.ex`, wired into the `before_save` hooks at `plugins/bulldocs.ex:76`. Its predicate IS the reader's own `Projection.read_blocks/1`, not a retyped list. **This is why the population cannot regrow**, and it is what the live control above fired. Test: `api/test/barkpark/plugins/bulldocs/readable_body_write_gate_test.exs`, parameterised over all three observed dialects, each arm first asserting the premise `{:error, :semantic_empty} = Papers.reader_source(…)`. |
| `a1d365bed` | 2026-08-17 | the *other* 422 population — 59 integer-`body_html_sv` papers → `:ambiguous_source`. **Different class; do not conflate** (that is `pe-w2-reader-stamp-guard`). |

**Residual hole, not fixed here:** the producer's contract lives in prompt text with no
test over it — the only gate on `bp-epic-cycle.workflow.js` is `node --check`. A prompt-text
assertion would be a brittle duplicate of the server-side write gate, which is strictly
stronger and already proven live, so none was added. Named so it is not rediscovered.

## Re-derivation

    BASE=https://guerrilla.barkpark.cloud
    bp doc query paper --fields _id --limit 1000 --count -o json > allids.json
    bp doc query paper --fields _id --limit 1000 --offset 1000 -o json > allids2.json
    while read -r p; do echo "$(curl -s -o /dev/null -w '%{http_code}' $BASE/papers/$p) $p"; done < allids.txt

Trap: `bp doc query paper --filter 'blocks is null'` is NOT a census of the blockless
population — it returned 43 rows, of which 9 demonstrably carry a populated `blocks` array
(e.g. `cloud-site-spawner-cf-wave-2026-07-14`, 200-serving). Enumerate and inspect the
documents; do not trust that filter clause.
