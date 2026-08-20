# pe-w3 — BPML D7 frame variant round-trip: parser leg sizing (2026-08-17)

Re-derivation recipes for the claims backing the D7 section-frame BPML third-surface leg.

## Claim 1 — parser REJECTS an unknown section attr (does NOT silently drop it)

    cd /Volumes/SATECHI/github/barkpark/api && mix run --no-start -e \
      'IO.inspect(Barkpark.PortableDoc.Bpml.Parser.parse_blocks(~s(<section id="x" title="T" variant="framed"><paragraph>hi</paragraph></section>)))' 2>/dev/null

Expect: `{:error, [%{code: "unknown-attr", message: "unknown attribute variant= on <section>", hint: "allowed on <section>: id, title"}]}`.
Mechanism: `check_attrs/3` (parser.ex:772-802) rejects any attr not in `Map.get(@block_attrs, tag, [])`; `@block_attrs["section"] = ~w(id title)` (parser.ex:13). Public entry is `parse_blocks/1` / `parse_paper/1` — there is NO `parse/1`.

## Claim 2 — printer DROPS a variant key already in the block map

    cd /Volumes/SATECHI/github/barkpark/api && mix run --no-start -e \
      'IO.puts(Barkpark.PortableDoc.Bpml.Printer.print_blocks([%{"type"=>"section","title"=>"T","variant"=>"framed","blocks"=>[%{"type"=>"paragraph","content"=>[%{"type"=>"text","value"=>"hi"}]}]}]))' 2>/dev/null

Expect: `<section title="T">` — NO variant. `block(section)` (printer.ex:122-125) calls `attr_str(b, ["id","title"])` (line 124); attr_str emits only listed keys.

## Claim 3 — attr_str is scalar-only (crashes on a map value)

    cd .../api && mix run --no-start -e 'to_string(%{"a"=>1})' 2>&1 | grep "String.Chars"

Expect: `protocol String.Chars not implemented for Map`. attr_str (printer.ex:181-188) does `to_string(v)` at line 185 → a map-valued variant crashes the printer. Variant MUST be a scalar string.

## Lines builders must touch for a true 3-surface round-trip

- parser.ex:13 — `"section" => ~w(id title)` → `~w(id title variant)` (else Claim 1 rejects).
- parser.ex:307-326 — add `|> put_attr("variant", attrs)` in BOTH `build_block("section",...)` branches (self-close 309-312 AND full 317-321) so the parsed value lands in the block map.
- printer.ex:124 — `attr_str(b, ["id", "title"])` → `attr_str(b, ["id", "title", "variant"])` (else Claim 2 drops it on print).
- attr_str (181-188) needs NO change; put_attr is present-only so existing variant-less sections are byte-identical (no pinned-test breakage).
