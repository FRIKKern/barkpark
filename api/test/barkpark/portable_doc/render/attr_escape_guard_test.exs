defmodule Barkpark.PortableDoc.Render.AttrEscapeGuardTest do
  # Pure source scan — no DB, no render, no fixtures.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render.AttrEscapeScan, as: Scan

  # ── the ATTRIBUTE-ESCAPING tripwire (source-scan sibling) ───────────────────
  #
  # THE INVARIANT: no value that can carry author-supplied text reaches an HTML
  # attribute value in `api/lib/barkpark/portable_doc/render/` without passing
  # `Util.escape_attr/1`, `Util.escape_html/1`, `Util.safe_url/1`, or a
  # provably-closed transform (a numeric formatter, a slug strip, a case/cond
  # whose every branch is a string literal, a palette field, a zero-arg engine
  # helper).
  #
  # WHY A SOURCE SCAN AND NOT A RENDER. `xss_render_sentinel_test.exs` is the
  # behavioural twin, and its own moduledoc scopes it to THREE block types
  # driven through `render_block/2` — it proves those three, and says nothing
  # about the other ~60 emitters. The defect that motivated this guard
  # (`api-endpoint`'s method badge minting `class="…--#{method}"` from a raw
  # user field) lived in a block no sentinel drove. A scan over SOURCE covers
  # every emitter the moment the file is saved, including ones no fixture
  # exercises. Same trade the class-coverage sibling makes
  # (`compose_class_coverage_test.exs`): breadth over per-value granularity.
  #
  # HOW IT DECIDES. The scan parses each render module to AST (never regex —
  # `compose.ex` alone is 135KB and a regex over it manufactures both misses
  # and phantoms), finds every interpolation that lands INSIDE an attribute
  # value (the literal text before it ends with `="`, unbalanced), and asks one
  # question of the interpolated expression: can it be PROVEN not to carry raw
  # author text? Proof follows values through same-clause bindings, through
  # private-function parameters to their in-file call sites, and through
  # case/cond/if branches. Anything it cannot prove is a FINDING — the scan
  # fails closed, which is why the residue below is explicit and justified
  # rather than silently tolerated.
  #
  # THE RESIDUE IS SHRINK-ONLY IN SPIRIT. An entry means a human read the site
  # and concluded the value cannot carry author text (or is escaped by a route
  # the prover cannot see). Adding one is a security decision; ship the
  # `escape_attr/1` instead whenever that is honest.

  @render_dir Path.expand("../../../../lib/barkpark/portable_doc/render", __DIR__)

  # Sites the prover cannot discharge, each read by hand. Keyed
  # {file, attribute, expression source} — NOT by line, so an unrelated edit
  # above does not silently re-arm or void an entry.
  @reviewed %{
    # ── components.ex ─────────────────────────────────────────────────────────
    {"components.ex", "class", "role"} =>
      "role is StatusVocab.role_for_status/1 output or a board_roles/0 literal; glyph_html/1 never sees author text",
    {"components.ex", "class", "src_class"} =>
      "pnode_source/1 returns the literal \" bp-pnode--src\" or \"\" — the author string goes to the escaped body, not the class",
    {"components.ex", "style", "color"} =>
      "the @filetree_markers module attribute's literal token colour (split_filetree_note/1 returns the marker, not the line)",
    {"components.ex", "style", "pad"} =>
      "pad = 14 + depth * 18 and row_html/1 int-guards depth (is_integer, 0 < d < 6, else 0)",

    # ── cards_email.ex / figures.ex / fleet_email.ex ──────────────────────────
    {"cards_email.ex", "style", "border"} =>
      "pnode_source/2 returns a skin hex (accent for an origin node, border otherwise) — the author's `source` string goes to the escaped provenance line",
    {"figures.ex", "data-cast-rows", "rows"} =>
      "emitted only under `is_integer(rows) and rows in 6..40`",
    {"fleet_email.ex", "style", "6 + pad"} =>
      "pad = depth * 16 and row_email/2 int-guards depth (is_integer, 0 < d < 6, else 0)",

    # ── compose.ex ────────────────────────────────────────────────────────────
    {"compose.ex", "data-level", "rel"} =>
      "the TOC relative level — an integer (it is used as an Enum.slice/2 range bound)",
    {"compose.ex", "data-tab-index", "i"} => "Enum.with_index/1's index — an integer",

    # ── data_viz.ex (SVG geometry: every coordinate is a formatted float) ──────
    {"data_viz.ex", "class", "cls"} =>
      "tone_class/2 allowlists the tone in its case-clause guard (~w(info ok warn danger)) and otherwise returns the literal base class",
    {"data_viz.ex", "class", "k"} => "Enum.map_join(0..3, …)'s integer bin index",
    {"data_viz.ex", "cx", "sx"} => "route coordinate — a float off the computed coords list",
    {"data_viz.ex", "cy", "sy"} => "route coordinate — a float off the computed coords list",
    {"data_viz.ex", "cx", "fx"} => "route coordinate — a float off the computed coords list",
    {"data_viz.ex", "cy", "fy"} => "route coordinate — a float off the computed coords list",
    {"data_viz.ex", "points", "pts"} => "a space-joined list of fmt/1-formatted floats",
    {"data_viz.ex", "d", "d"} =>
      "the SVG path — \"M\"/\"L\" literals joined with the computed float coords",

    # ── fleet_email.ex ────────────────────────────────────────────────────────
    {"fleet_email.ex", "width", "remaining"} =>
      "100 - left - width, both of which are clampf/1 floats",

    # ── walk.ex ───────────────────────────────────────────────────────────────
    {"walk.ex", "class", "role_class"} =>
      "apply_text_role/4 returns one of five literal bp-role-* classes (or nil, which emits no attribute)",
    {"walk.ex", "class", "td_class"} =>
      "\"bp-sheet__td\" joined with sheet_default_align_class/1's literal class or nil",
    {"walk.ex", "data-valueref-state", "state"} =>
      "one of the literals \"resolved\" / \"drift\" / \"dangling\" — valueref/2's case returns it in a tuple with the escaped text",
    {"walk.ex", "style", "bg"} => "Util.tone_palette/1's {bg, fg} hex pair from the TokensGen callout table",
    {"walk.ex", "style", "fg"} => "Util.tone_palette/1's {bg, fg} hex pair from the TokensGen callout table",
    {"walk.ex", "style", "box_style(Map.get(n, \"style\"))"} =>
      "box_style/1 wraps EVERY value it emits in escape_attr/1 (maybe_flex/maybe_push/maybe_border) — the raw node map never reaches the attribute",
    {"walk.ex", "style", "extra"} =>
      "sheet_cell_style/3: literal b/i fragments, a bg validated against ~r/^#[0-9a-f]{6}\\z/ (sheet_bg_valid?/1), and an al allowlisted to left|center|right",
    {"walk.ex", "style", "style"} =>
      "sheet_inline_style/1's subject is w_style <> extra <> err — each validated at its own site (see the two entries around this one)",
    {"walk.ex", "colspan", "cs"} =>
      "sheet_merge_lookup/1 admits a span only under is_integer(cs) and cs >= 1 (and an area cap)",
    {"walk.ex", "rowspan", "rs"} =>
      "sheet_merge_lookup/1 admits a span only under is_integer(rs) and rs >= 1 (and an area cap)",
    {"walk.ex", "style", "Enum.join(out, \";\")"} =>
      "the inline-style accumulator: literal declarations, a literal-joined text-decoration, and the author colour — which escape_attr/1 now owns (walk.ex text/3 and paragraph_html/4)",
    {"walk.ex", "style", "w_style"} =>
      "col_width_style/2 emits width:<n>px only when the stored width is a positive INTEGER, else \"\""
  }

  test "every attribute interpolation in the render tree is provably escape-safe" do
    result = Scan.run(@render_dir)

    # POSITIVE CONTROL — an empty or collapsed population is the failure mode
    # that makes a guard like this pass forever while measuring nothing.
    assert result.files >= 15,
           "the scan parsed #{result.files} render modules — did the render dir move?"

    assert result.total >= 400,
           "the scan found only #{result.total} attribute interpolations; expected 400+ — " <>
             "the extractor is broken, not the tree"

    assert result.by_verdict[:sanitizer] >= 30,
           "only #{result.by_verdict[:sanitizer] || 0} interpolations resolve through " <>
             "escape_attr/escape_html/safe_url; expected 30+ — the sanitizer detector is broken"

    IO.puts(
      "\n[attr-escape-guard] #{result.total} attribute interpolations across " <>
        "#{result.files} modules; verdicts: " <>
        (result.by_verdict
         |> Enum.sort_by(&(-elem(&1, 1)))
         |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end))
    )

    findings =
      Enum.reject(result.unproven, &Map.has_key?(@reviewed, {&1.file, &1.attr, &1.expr}))

    assert findings == [],
           """
           #{length(findings)} attribute interpolation(s) in the render tree carry a value the
           scan cannot prove is escaped or closed. A raw author field here is stored XSS
           (the `api-endpoint` method badge was exactly this shape):

           #{Enum.map_join(findings, "\n", fn f -> "  #{f.file}:#{f.line}  #{f.attr}=\"\#{#{f.expr}}\"" end)}

           Wrap the value in `Util.escape_attr/1` (or `safe_url/1` for an href), or — after
           reading the site and concluding it cannot carry author text — add
           {file, attr, expr} to @reviewed with a one-line justification.
           """
  end

  test "every @reviewed entry still names a live site and carries a justification" do
    result = Scan.run(@render_dir)
    live = MapSet.new(result.unproven, &{&1.file, &1.attr, &1.expr})

    for {{f, a, e} = key, why} <- @reviewed do
      assert is_binary(why) and String.trim(why) != "",
             "@reviewed entry #{inspect(key)} needs a one-line justification"

      assert MapSet.member?(live, key),
             "@reviewed entry #{f} #{a}=\"\#{#{e}}\" no longer matches any unproven site — " <>
               "the code changed; delete the entry (a stale suppression hides the next defect)"
    end
  end
end
