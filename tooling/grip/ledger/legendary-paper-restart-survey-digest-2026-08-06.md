<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-digest | budget: 2200tok -->
# Legendary Paper restart — Survey digest

## Numeric reconciliation

The immutable restart Survey is sealed: **60/60 completed**, **61 starts** including one replaced historical attempt, one historical failed record, zero unresolved failures, zero unresolved missing results, and zero invalid assignments/results. Coverage is exact: four current revision-pinned Papers × five readers × three independent lenses = 60 terminal reports.

The frozen inventory remains 20 reader units with digest `227c9defff49f185dc5e580f731ab2419da17fc2dc5cf2304a664e4b230f7ccc`. The restart wave revision is `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`.

## What is proven

All four current Paper/source chains were re-read, hashed, and joined to immutable history. Current content is generally stable; the campaign is not reacting to unexplained authoring drift. PDS45 at `_rev` `b992fd8aaa028b0dab30a8da76f077fd`, for example, has the same exact 227-block array in document, source, newest history revision `4afe0099-26af-40eb-8943-f6935c16c29d`, authenticated Studio seed, and direct CLI/TUI render input.

Public and email projections preserve PDS45's 536/536 authored fragments and 33/33-heading outline. Public desktop geometry passes. Direct terminal rendering at width 80 is deterministic and bounded. Machine CLI/API document and source payloads preserve exact blocks and ordered IDs. Authenticated Studio server HTML carries the exact source seed.

These passes are narrow. They prove content carriage at specific boundaries, not reader safety.

## Cross-reader failures

### Semantics

Tables, callouts, and marks repeatedly lose meaning. PDS45 public/email render all 12 data tables as presentation-only, leave nine header cells without associations, give nine callouts no semantic role, and expose zero authored strong elements. Studio conversion imports 0/9 legacy table headers and 0/8 marked runs. TUI rendering also drops the nine legacy header cells.

### Identity and history

Readers cannot independently say which immutable Paper revision they represent. Public flat/dataset HTML, email preview, Studio server HTML, direct CLI human output, and TUI output omit the document `_rev`. Scoped public emits a released-revision header but matching ETag still returns 200/full body. Revision query parameters are ignored by public rendering. TUI retains `_rev` internally but never displays it; its Paper key branch intercepts `H`, so history is inaccessible.

### Responsive geometry and controls

PDS45 public overflows by 127px at 390px and 197px at 320px. All 12 phone tables require horizontal scrolling, and fixed TUI/email controls overlap authored text in 3/5 sampled positions. Email preview overflows by 733px at 390px and 803px at 320px. Studio phone geometry remains blocked without a connected authenticated browser, while current three-column topbar CSS still lacks a phone override.

### Product reachability

The no-argument TUI cannot open the exact Paper despite the data existing. The live server desk emits a direct `document_type_list`, while traversal only follows `item.Child`. Separately, seven tasks carry `wave_paper` references, but taskboard hydration reads only `papers[]` and `design_doc`. Direct renderer success cannot proxy discovery, selection, open, scroll, mouse, or focus.

### Narrow terminal loss

Bounded output is not equivalent to complete output. PDS45 tables retain 22,054/22,054 alphanumeric body characters at width80, 22,033 at the inferred 50-column Paper pane, 20,363 at20, 1,158 at8, and zero at1. The renderer never overflows because it discards content as space collapses.

### Studio input safety

The Studio projector preserves block count/order for valid source but permissively normalizes malformed data. Missing IDs can mint synthetic IDs and operations; malformed paragraphs can become literal `[object Object]`; malformed tables normalize to empty cells; unknown opaque payloads survive; canvas JSON parse failure silently becomes an empty seed. Exploitability and persistence are not inferred, but silent loss/corruption risk is real.

### API and CLI contracts

Machine payload parity passes while surrounding contracts fail. History limits are ignored; Paper source accepts HTML/`*/*` but returns 406 `internal_error` for JSON; invalid perspectives can be accepted; missing and upstream Paper errors are flattened or mislabeled; JSON-mode parse failures can become human text; schema omits PortableDoc/block dialect details; conditional and request-ID behavior differs by route. Intermittent 500/404 observations later recover, but their operational cause is unproven because historical request IDs/log correlation is incomplete.

## Explicitly blocked

No Survey report proxy-passed real mail clients, real assistive technology, authenticated Studio role/MFA/grant matrices, connected edit/save/reconnect behavior, browser screen-reader trees, or a long-duration availability window. These are Verify work, not omissions to hide.

## Verification direction

The 30-verifier phase must decide which failures are causal and which are symptoms. It must reproduce source semantics and geometry across all four Papers, prove revision/cache/error contracts by route, establish authenticated connected Studio behavior with disposable state, distinguish TUI discovery defects from renderer defects, quantify narrow-table loss, and correlate intermittent failures with request IDs/build identity. Every assignment needs a falsifiable threshold and a durable artifact; historical prose alone cannot pass.
