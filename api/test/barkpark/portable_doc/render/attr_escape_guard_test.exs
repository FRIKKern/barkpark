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
    # -- engine-owned CSS fragments: locals bound to literal-only branches the
    #    prover loses across a multi-clause helper boundary.
    {"cards_email.ex", "style", "top"} => "skin accent hex chosen by kind; no author text",
    {"cards_email.ex", "style", "border"} => "skin border hex; no author text",
    {"walk.ex", "style", "Enum.join(out, \";\")"} =>
      "out is a list of literal CSS fragments built in-clause",
    {"walk.ex", "colspan", "cs"} => "integer from Map.get |> to_int clamp",
    {"walk.ex", "rowspan", "rs"} => "integer from Map.get |> to_int clamp",
    {"fleet_email.ex", "style", "6 + pad"} => "integer arithmetic",
    {"panels_email.ex", "style", "hex"} => "skin hex literal",
    {"data_viz.ex", "viewBox", "h"} => "numeric viewBox string built from floats",
    {"data_viz.ex", "d", "d"} => "SVG path built from formatted floats",
    {"figures.ex", "data-cast-rows", "rows"} => "integer row count"
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
