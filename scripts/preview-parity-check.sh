#!/usr/bin/env bash
# preview-parity-check.sh — the STRUCTURAL tripwire for the preview contract
# (preview-contract W4, charter D20 Layer 2). The cross-surface FIELD parity is
# proven by the golden-fixture tests (api preview_parity_fixture_test.exs, web
# preview-parity.test.ts, Go preview_parity_test.go — all reading the SAME
# mirror). This script guards the invariants a fixture test cannot see: that no
# surface RESURRECTS a hand-rolled preview, and that D10 stays executable law.
#
#   Part 1 — the web finder detail page consumes the ONE manifest. The per-type
#     `docDescription` / `paperExcerpt` switch (a paper/post-only excerpt fork,
#     the exact drift W3 killed) must stay DEAD; `metadataFromPreview` must be
#     the metadata source.
#   Part 2 — D22: the web detail fetch must carry NO `?fields=` projection.
#     query_controller's project_fields STRIPS any content key a fields list
#     omits — a `fields=` on the detail query would silently drop `preview` off
#     the wire and every card would degrade to the branded default. The by-id
#     doc endpoint (no projection) is the only correct fetch here.
#   Part 3 — D10, recorded as executable law: NO oEmbed. Anywhere. Ever. Slack
#     prefers oEmbed over og and a careless endpoint downgrades every card to a
#     tiny thumbnail. `grep -ri oembed` over the source tree must be ZERO. The
#     decision is CLOSED — this gate exists so it can never be silently reopened.
#
# Usage: scripts/preview-parity-check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "preview-parity-check: FAILED — $1" >&2; exit 1; }

DETAIL_PAGE="web/app/(finder)/d/[type]/[slug]/page.tsx"
GET_DOC="web/lib/get-document.ts"

# ── Part 1: the per-type preview switch stays dead ──────────────────────────
[ -f "$DETAIL_PAGE" ] || fail "web finder detail page not found at $DETAIL_PAGE"

if grep -Eq '\b(docDescription|paperExcerpt)\b' "$DETAIL_PAGE"; then
  fail "part 1 — the per-type preview switch (docDescription/paperExcerpt) is BACK in
  $DETAIL_PAGE. The finder must derive every meta tag from the ONE write-time
  preview manifest via metadataFromPreview — not a paper/post excerpt fork (D17/W3)."
fi

if ! grep -q 'metadataFromPreview' "$DETAIL_PAGE"; then
  fail "part 1 — $DETAIL_PAGE no longer calls metadataFromPreview; the finder must
  render its metadata from the shared preview manifest."
fi
echo "preview-parity-check part 1: PASS — the finder consumes the ONE manifest (no per-type switch)."

# ── Part 2: no ?fields= projection on the web detail fetch (D22) ─────────────
for f in "$DETAIL_PAGE" "$GET_DOC"; do
  [ -f "$f" ] || continue
  # Any `fields=` / `fields:` / `"fields"` projection on the detail read would
  # strip `preview` (query_controller project_fields). The by-id doc endpoint
  # carries no projection — keep it that way.
  if grep -Eqi 'fields[[:space:]]*[=:]|["'\'']fields["'\'']' "$f"; then
    fail "part 2 (D22) — a fields= projection appeared in $f. The detail read must NOT
  project content fields, or query_controller strips \`preview\` off the wire and
  every card degrades to the branded default. Fetch the whole doc (by-id endpoint)."
  fi
done
echo "preview-parity-check part 2: PASS — the web detail fetch carries no fields= projection (D22)."

# ── Part 3: D10 — NO oEmbed, anywhere, ever ─────────────────────────────────
OEMBED_HITS="$(grep -roil oembed \
  --include='*.ex' --include='*.exs' --include='*.go' \
  --include='*.ts' --include='*.tsx' --include='*.heex' \
  --exclude-dir=node_modules --exclude-dir=deps --exclude-dir=_build \
  . 2>/dev/null || true)"

if [ -n "$OEMBED_HITS" ]; then
  fail "part 3 (D10) — oEmbed appeared in the source tree:
$OEMBED_HITS
  D10 is CLOSED: NO oEmbed, anywhere, ever. Slack prefers oEmbed over og and a
  careless endpoint downgrades every card. Remove it."
fi
echo "preview-parity-check part 3: PASS — D10 upheld: zero oEmbed references in the source tree."

echo "preview-parity-check: PASS — cross-surface preview contract structurally sound."
