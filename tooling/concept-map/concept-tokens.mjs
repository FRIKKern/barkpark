#!/usr/bin/env node
// concept-tokens.mjs — the single CONCEPT-TOKEN matcher, shared across the cqv8
// passes. Sibling of entrypoints.mjs and registration.mjs, and built to the same
// shape for the same reason: every pass must speak ONE concept vocabulary, so
// the rule that decides which concept a cross-tree file folds into lives in one
// place and is imported, never re-typed.
//
// ── WHAT THE FOLD IS ─────────────────────────────────────────────────────────
// concepts.mjs names every domain/plugin concept structurally off the tree
// (api/lib/barkpark/<X> → concept X). A SECOND pass then attaches the cross-tree
// members — web-layer files, tests, anything else — to whichever already-
// discovered concept token appears as a path SEGMENT, longest token first. That
// is what makes barkpark_web/live/sheets_reader_live.ex and plugins/sheets one
// "sheets" concept.
//
// ── THE DEFECT THIS MODULE EXISTS TO REMOVE ──────────────────────────────────
// The matcher was `(^|[/_.])<token>([/_.]|$)`, duplicated verbatim at SEVEN
// sites across five files (anatomy, boundary, concepts, grade, manifest). The
// `^` alternative let a token match the FIRST path segment — which is never a
// concept designator, it is the language/tree root. So:
//
//   api/lib/barkpark/api/openapi.ex   (ONE file) mints the token "api"
//   → `(^|[/_.])api([/_.]|$)` then matches `^api/`
//   → every Elixir path in the repo is a candidate member of concept "api"
//
// Because the fold is longest-token-first and breaks on first match, "api" did
// not swallow the tree outright — it became the CATCH-ALL SINK for everything no
// longer token claimed first. Measured on origin/main by replaying this exact
// pass over the tracked source files:
//
//   api          673 → 26 files   (−647)
//   connectors   105 → 26 files   (−79)
//   scaffy        38 → 35 files   (−3)
//   sso           13 → 21 files   (+8, landing on their correct owner)
//
// Three tokens collide with a top-level directory name — `api`, `connectors`,
// `scaffy` — so this was never an api-only artifact. Downstream, concept `api`
// became a magnet TARGET: 12 of the boundary gate's reported feature→feature
// regressions pointed at it (`sheets>api`, `quiz>api`, `tickets>api`, …), debt
// that describes the repo's directory layout rather than its architecture.
//
// ── THE RULE ─────────────────────────────────────────────────────────────────
// A concept token must be preceded by a separator: `/`, `_` or `.`. Dropping
// the `^` arm is the whole fix. The only paths the `^` arm ever matched were
// the three false folds above — a top-level directory is a tree root, never a
// concept — so nothing legitimate depended on it. Files that genuinely carry
// the token deeper in the path (api/lib/barkpark/api/openapi.ex,
// barkpark_web/plugs/api_security_headers.ex, web/app/api/**/route.ts) still
// match, because there the token IS separator-preceded.
//
// Dependency-free. ESM, node: builtins only — a pure path string predicate.

// The matcher for ONE concept token. Anchored on a separator, never on the
// start of the path. Callers lowercase the path before testing (tokens are
// already lowercase by construction — primaryConcept only captures [a-z0-9_]).
//
// @canonical capability:concept-token-fold aka:tokenRe,token fold,concept token,path segment,cross-tree fold
export function conceptTokenRe(token) {
  return new RegExp("([/_.])" + token + "([/_.]|$)");
}

// Precompiled matchers for a whole token set, as `token → RegExp`. The fold
// loops over `tokens` in longest-first order and consults this map, so building
// the regexes once per pass (not once per file) stays the hot-path shape every
// caller already had.
export function conceptTokenMatchers(tokens) {
  return new Map(tokens.map((t) => [t, conceptTokenRe(t)]));
}
