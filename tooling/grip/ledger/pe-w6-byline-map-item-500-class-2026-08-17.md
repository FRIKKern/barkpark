<!-- doc-tier: cold | canonical-for: pe-w6-byline-map-item-500-class re-derivation | budget: 600tok -->

# Residual raw-500 on /source?format=bpml — the byline map-item class (wave-6 verifier)

VERDICT: wave-5 and wave-6 papers 500 (not the typed 422) because the `byline`
block clause `esc(&1)` runs `to_string/1` on a MAP item `%{"value" => …}` →
`Protocol.UndefinedError` (String.Chars not implemented for Map) → escapes the
callers' rescue as a raw HTTP 500. It is NOT an uncovered block type: every type
present has a printer clause. It is a covered clause crashing on a non-canonical
item shape. Canonical byline items are BARE STRINGS (parser `tag_text`,
epic-memory-plan doc), so the map shape is generator drift, not a legal paper.

Re-derive:

    # 1. confirm both still 500
    curl -s -o /dev/null -w '%{http_code}\n' \
      'https://guerrilla.barkpark.cloud/papers/paper-excellence-wave-5-2026-08-17/source?format=bpml'
    curl -s -o /dev/null -w '%{http_code}\n' \
      'https://guerrilla.barkpark.cloud/papers/paper-excellence-wave-6-2026-08-17/source?format=bpml'

    # 2. fetch json, show the byline block — items are maps, not strings
    curl -s '.../paper-excellence-wave-5-2026-08-17/source?format=json' \
      | python3 -c 'import json,sys;j=json.load(sys.stdin);print([b for b in j["source"]["blocks"] if b.get("type")=="byline"])'
    # => items: [{"value":"Epic task-…"}, …]   (map, not "…")

    # 3. the crashing clause (git show origin/main:api/lib/barkpark/portable_doc/bpml/printer.ex ~L61)
    #    items = Enum.map(Map.get(b,"items",[]), &"…<item>#{esc(&1)}</item>")
    #    esc(other) -> esc(to_string(other));  to_string(%{}) raises Protocol.UndefinedError
    # 4. parser canonical (parser.ex L241 build_block("byline") -> tag_text -> STRING items)
    # 5. test blind spot: bpml_test.exs gen_block(7) items = gen_text() -> strings only

DISPOSITION:
- NOT the notes-tier PR's job (different block, different clause).
- Census MUST keep a residual-500 bucket keyed on byline-map-items until fixed —
  the "0-in-500" / "141 fixed by #11640" headline is false for this class.
- File a SEPARATE bug task: make byline item printing fail-honest — coerce
  `%{"value" => binary}` to the string (fail-soft, mirrors head_cell/inline
  string coercion) OR raise UnprintableError(:block) for a non-binary item; add a
  gen_block(7) property arm that feeds a map item. Also fix the wave-paper
  generator to emit string byline items.
