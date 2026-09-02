<!-- doc-tier: agent | canonical-for: canonical-block-type-count | budget: 1300tok -->
# 0006 — The canonical block-type count is DERIVED, and these are the exclusions

Status: accepted 2026-09-02 · closes `mob-zb-bl-canonical-anchor` (charter D48)

Five rival block-type counts were in circulation and **all of them were wrong**.
Each was produced by a quoted-string census, and each census was blind to a
construct the language sees: the `:section` list in `Tiers` is an unquoted `~w()`
sigil, and the two camelCase types (`arrayOf`, `localizedText`) fall outside any
lowercase-only character class. This ADR states the counting rule, records the
numbers it produces, and lists every exclusion with the reason it is excluded.

**The rule: a block-type count is only citable with the command that derived it.**
Never quote a number from a paper. Numbers below were re-derived 2026-09-02.

## The three registries

| Surface | Count | Derivation |
|---|---|---|
| Elixir `Tiers.known_types/0` | **79** | `mix run --no-start -e 'IO.inspect(length(Barkpark.PortableDoc.Tiers.known_types()))'` |
| Elixir `compose.ex` render surface | **79** | the extractor in `tiers_test.exs`; byte-identical set to the above |
| React `REGISTERED_TYPES` | **75** | `Object.keys(DISPATCH).length`; pinned by `toHaveLength(75)` in the react suite |
| Go `pdrender` registry | **90** | `go/ast` walk for `r.blocks[<string>] =` over non-test files |

79 is the number to cite for "the server renders N block types". It is pinned by
`length(known_types/0)` in `api/test/barkpark/portable_doc/tiers_test.exs`, which
reds in both directions and reds when a type is added to or removed from the
`~w()` sigil — the construct that manufactured the rival counts.

## Exclusions ledger — why the registries differ

**A. Elixir ∖ react = 14 server-only types.** React renders documents; it has no
schema-field editor, so field atoms have no emitter.

| Types | Reason |
|---|---|
| `embed`, `codelist`, `composite` | server-side embed / field-composition atoms; no browser twin authored |
| `arrayOf`, `localizedText` | schema-FIELD kinds, not block types — bound fields edited as one unit; camelCase, which is why lowercase-only censuses dropped them |
| `field-boolean` `field-color` `field-datetime` `field-image` `field-reference` `field-select` `field-slug` `field-string` `field-text` | 9 field atoms of the schema-field family; each needs a react emitter before it can render in the browser |

**B. Go-only keys = 2, neither a server block type.**

| Key | Reason |
|---|---|
| `dashboard` | registered in the Go registry only. **MEASURED, not assumed**: 0 occurrences across 1050 published `paper` documents on `guerrilla.barkpark.cloud` (2026-09-02). It renders nothing that exists; treat it as unexercised, not as a parity debt. |
| `PdSheet` | the Go spelling of the sheet block's schema KIND, registered alongside `sheet`. Not an Elixir block type and never was. |

**C. React ∪ Go ∖ Elixir = 10 authoring-drift aliases** — `bulletList`,
`bullet_list`, `bulleted-list`, `bulleted_list`, `numbered_list`, `ordered-list`,
`quote`, `h1`, `h2`, `h3`. Both client surfaces normalize these hand-typed
spellings; the server does not. Open work: `mob-zb-bl-heading-alias-drift`.
Live-corpus check 2026-09-02: 0 occurrences of `h1`/`h2`/`h3`/`ordered-list` in
the 1050 published papers, so the remaining drift is not in the paper corpus.

**D. `paper-links` — a REAL gap the "Go is a strict superset" claim hid.**
Elixir and react both render it; the Go `pdrender` tree does not register it at
all. **MEASURED: 151 blocks across 145 of 1050 published papers** — it is one of
the most-used custom blocks in the corpus, and it unknown-boxes in the TUI. This
is the only type in Elixir ∖ Go. Not fixed here; recorded so it stops hiding
behind an arithmetic claim.

## Rival counts, retired at their sources

| Claim | Where | Correction |
|---|---|---|
| `known_types` = 73 | `mob-zb-bl-canonical-anchor` (task row) | 79 |
| canonical 71 ≡ `known_types`; Go a strict superset of both | mobile charter D48 | 79 ≡ 79; the superset claim is **FALSE** — `paper-links` (see D above) |
| react 66 keys / 59 canonical | charter D48, wave digest | 75 |
| Go 76 · Go 82 · Go 83 · Go 79 | wave digest, shell-and-cache paper, D48 MUST-RUN | 90 |
| Elixir 75 = element 29 + widget 43 + section 3 | `tooling/grip/ledger/block-registry-truth-2026-07-31.md` | correct **on its date**; today 79 = element 29 + widget 47 + section 3. Dated fact records are left standing, not rewritten. |

Papers on the server carry the same retired numbers and are **not** editable from
this repo — the wave digest, the shell-and-cache paper, and papers-pro-toolkit
(75/60) each need a correction note applied by their owner.
