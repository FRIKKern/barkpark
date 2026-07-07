defmodule Barkpark.PortableDoc.Render.SectionLayoutTest do
  @moduledoc """
  STEP-2 layout engine — reader byte-identity + grid emission gate.

  A `section` MAY carry an optional `layout` object. `grid_layout/1` (compose.ex)
  is the ONE predicate that gates the grid path: it fires ONLY when
  `layout.mode == "grid"`. This locks the two invariants that make the step
  backward-compatible AND correct:

    * BYTE-IDENTITY (tests 8): a no-layout section AND an explicit
      `{"mode":"stack"}` section render the CURRENT stack HTML byte-for-byte
      (the callout maybe_put_true precedent — absence and explicit-stack are
      indistinguishable at the bytes). This is the legacy-corpus tripwire.
    * GRID EMISSION (tests 9-10): a `{"mode":"grid","tracks":N}` section emits the
      shared `.bp-section__grid` wrapper with `--bp-tracks:N`, each child inside a
      `.bp-section__cell`, children STILL routed through their own emitters; the
      gap is a token CSS VAR, never a px literal (D2).
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  @article %{style: :article}

  # The CURRENT stack render for a titled one-paragraph section (article mode).
  # Captured from the pre-layout engine — the literal today-string tripwire.
  @stack_html ~s(<div style="display:flex;flex-direction:column">) <>
                ~s(<hr class="bp-hr" style="border-top-width:1px">) <>
                ~s(<span style="font-weight:bold">Overview</span>) <>
                ~s(<p>hi</p>) <>
                ~s(<hr class="bp-hr" style="border-top-width:1px"></div>)

  defp stack_section, do: %{
    "type" => "section",
    "title" => "Overview",
    "blocks" => [%{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "hi"}]}]
  }

  # ── TEST 8: reader anti-regression — no-layout AND explicit-stack are byte-identical
  describe "byte-identity: stack path is untouched" do
    test "a no-layout section renders the CURRENT stack HTML byte-for-byte" do
      assert Render.render_block(stack_section(), @article) == @stack_html
    end

    test "an EXPLICIT {mode:stack} section renders byte-identically to no-layout" do
      explicit = Map.put(stack_section(), "layout", %{"mode" => "stack"})
      assert Render.render_block(explicit, @article) == @stack_html
    end

    test "a non-grid mode (or malformed layout) also falls to the stack path" do
      for layout <- [%{"mode" => "flow"}, %{"tracks" => 3}, %{}, "grid", nil, 42] do
        b = Map.put(stack_section(), "layout", layout)
        assert Render.render_block(b, @article) == @stack_html,
               "layout #{inspect(layout)} must NOT reach the grid path"
      end
    end

    test "the stack render carries NO grid markup" do
      html = Render.render_block(stack_section(), @article)
      refute String.contains?(html, "bp-section__grid")
      refute String.contains?(html, "--bp-tracks")
    end
  end

  # ── TEST 9: grid emission — shared class + tracks + per-child cell + own emitters
  describe "grid emission" do
    defp grid_section(tracks) do
      %{
        "type" => "section",
        "title" => "Overview",
        "layout" => %{"mode" => "grid", "tracks" => tracks},
        "blocks" => [
          %{"type" => "callout", "tone" => "info", "content" => [%{"type" => "text", "value" => "note"}]},
          %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "two"}]}
        ]
      }
    end

    test "emits the shared .bp-section__grid wrapper with --bp-tracks:N" do
      html = Render.render_block(grid_section(3), @article)
      assert String.contains?(html, ~s(class="bp-section__grid"))
      assert String.contains?(html, "--bp-tracks:3")
    end

    test "each child is wrapped in a .bp-section__cell" do
      html = Render.render_block(grid_section(2), @article)
      # Two children ⇒ two cells.
      cells = html |> String.split(~s(class="bp-section__cell")) |> length()
      assert cells == 3, "expected exactly two .bp-section__cell wrappers"
    end

    test "children still route through their OWN emitters (a callout child emits bp-callout)" do
      html = Render.render_block(grid_section(2), @article)
      assert String.contains?(html, "bp-callout"),
             "the callout child must render through its own emitter inside the cell"
      assert String.contains?(html, "<p>two</p>"), "the paragraph child renders as a real <p>"
    end

    test "grid mode keeps the flex-column wrapper + leading/trailing rules" do
      html = Render.render_block(grid_section(2), @article)
      assert String.starts_with?(html, ~s(<div style="display:flex;flex-direction:column">))
      assert String.contains?(html, ~s(<hr class="bp-hr">))
      assert String.contains?(html, ~s(<div class="bp-section__title" style="font-weight:bold">Overview</div>))
    end

    test "an absent title emits NO title node in the grid path" do
      b = grid_section(2) |> Map.delete("title")
      html = Render.render_block(b, @article)
      refute String.contains?(html, "bp-section__title")
    end
  end

  # ── TEST 10: D2 — gap is a token CSS VAR, never a px literal
  describe "gap token vocabulary (D2)" do
    defp grid_wrapper_style(html) do
      [_, style | _] = Regex.run(~r/class="bp-section__grid" style="([^"]*)"/, html)
      style
    end

    test "the default gap resolves to a CSS var (never px)" do
      html = Render.render_block(%{"type" => "section", "layout" => %{"mode" => "grid"}, "blocks" => []}, @article)
      style = grid_wrapper_style(html)
      assert String.contains?(style, "--bp-grid-gap:var(--bp-space-md,1.6rem)")
      refute String.contains?(style, "px"), "the grid wrapper style must carry NO px literal (D2)"
    end

    test "each gap token maps to its --bp-space-* var, never px" do
      tokens = %{
        "none" => "var(--bp-space-none,0)",
        "sm" => "var(--bp-space-sm,0.8rem)",
        "md" => "var(--bp-space-md,1.6rem)",
        "lg" => "var(--bp-space-lg,2.4rem)"
      }

      for {token, expected} <- tokens do
        b = %{"type" => "section", "layout" => %{"mode" => "grid", "gap" => token}, "blocks" => []}
        style = b |> Render.render_block(@article) |> grid_wrapper_style()
        assert String.contains?(style, "--bp-grid-gap:#{expected}"), "gap #{token} → #{expected}"
        refute String.contains?(style, "px"), "gap #{token} must not emit a px literal"
      end
    end
  end

  # ── null-layout patch semantics (risk #6): {layout: null} renders as stack
  test "a null layout renders as the stack path (compose grid_layout treats null as stack)" do
    b = Map.put(stack_section(), "layout", nil)
    assert Render.render_block(b, @article) == @stack_html
  end

  # ═══ STEP-6: per-child span/order emission on the grid cell ════════════════════
  #
  # A grid child MAY carry `span` (positive int → grid-column:span N) and/or `order`
  # (any int → order:K). The reader emits these PRESENT-ONLY on the child's
  # `.bp-section__cell` wrapper. A child with NEITHER emits a bare cell (byte-
  # identical to pre-step-6), and children STILL route through their own emitters.

  # A one-child grid section whose lone child carries the given placement keys.
  defp grid_one(child_extra) do
    child =
      Map.merge(
        %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "x"}]},
        child_extra
      )

    %{"type" => "section", "layout" => %{"mode" => "grid", "tracks" => 2}, "blocks" => [child]}
  end

  defp cell_style(html) do
    case Regex.run(~r/<div class="bp-section__cell" style="([^"]*)">/, html) do
      [_, style] -> style
      _ -> nil
    end
  end

  describe "STEP-6 per-child span/order emission" do
    test "a child with span:2 → cell carries grid-column:span 2" do
      html = Render.render_block(grid_one(%{"span" => 2}), @article)
      assert cell_style(html) == "grid-column:span 2"
    end

    test "a child with order:1 → cell carries order:1" do
      html = Render.render_block(grid_one(%{"order" => 1}), @article)
      assert cell_style(html) == "order:1"
    end

    test "a child with BOTH → grid-column:span 2;order:1 (span first, deterministic)" do
      html = Render.render_block(grid_one(%{"span" => 2, "order" => 1}), @article)
      assert cell_style(html) == "grid-column:span 2;order:1"
    end

    test "a child with order:0 and negative order are legal (0 and -1 emit)" do
      assert cell_style(Render.render_block(grid_one(%{"order" => 0}), @article)) == "order:0"
      assert cell_style(Render.render_block(grid_one(%{"order" => -3}), @article)) == "order:-3"
    end

    test "children still route through their OWN emitters inside a styled cell" do
      section = %{
        "type" => "section",
        "layout" => %{"mode" => "grid", "tracks" => 2},
        "blocks" => [
          %{
            "type" => "callout",
            "tone" => "info",
            "span" => 2,
            "content" => [%{"type" => "text", "value" => "note"}]
          }
        ]
      }

      html = Render.render_block(section, @article)
      # The cell carries the placement AND wraps the callout's own emitter markup.
      assert String.contains?(html, ~s(<div class="bp-section__cell" style="grid-column:span 2">))
      assert String.contains?(html, "bp-callout"), "callout child renders through its own emitter"
    end
  end

  # ── STEP-6 BACKWARD-COMPAT: a grid section with NO child span/order is byte-
  #    identical to the pre-step-6 grid HTML. The frozen literal is the tripwire.
  describe "STEP-6 no-cells grid byte-identity (the backward-compat tripwire)" do
    # The exact bytes a two-child grid section (tracks:2, no title) emitted BEFORE
    # step 6 — bare .bp-section__cell wrappers, no per-child style.
    @grid_html_no_cells ~s(<div style="display:flex;flex-direction:column">) <>
                          ~s(<hr class="bp-hr">) <>
                          ~s|<div class="bp-section__grid" style="--bp-tracks:2;--bp-grid-gap:var(--bp-space-md,1.6rem)">| <>
                          ~s(<div class="bp-section__cell"><p>a</p></div>) <>
                          ~s(<div class="bp-section__cell"><p>b</p></div>) <>
                          ~s(</div>) <>
                          ~s(<hr class="bp-hr"></div>)

    defp grid_no_cells do
      %{
        "type" => "section",
        "layout" => %{"mode" => "grid", "tracks" => 2},
        "blocks" => [
          %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "a"}]},
          %{"type" => "paragraph", "content" => [%{"type" => "text", "value" => "b"}]}
        ]
      }
    end

    test "a grid section with no child span/order renders BYTE-IDENTICALLY to pre-step-6" do
      assert Render.render_block(grid_no_cells(), @article) == @grid_html_no_cells
    end

    test "the no-cells grid emits NO per-child style attr (bare cells only)" do
      html = Render.render_block(grid_no_cells(), @article)
      refute String.contains?(html, ~s(class="bp-section__cell" style=)),
             "a child with no span/order must emit a BARE cell (byte-compat)"
    end
  end

  # ── STEP-6 INT-GUARD / SECURITY + D2 — malformed span/order fall safe, no px ──
  describe "STEP-6 int-guard (security) + D2 no-px" do
    test "a malformed span emits NO grid-column (no style injection)" do
      # A stringy value with trailing CSS, 0, -1, a float, and a non-numeric string
      # must ALL drop the span (positive-int only, whole-string parse). The CSS
      # injection probe is built by concatenation so the SOURCE never puts an
      # `identifier:` adjacent (a 1.19 keyword-tokenizer ambiguity), while the
      # RUNTIME value is exactly `2;background:url(x)`.
      injection = "2;" <> "background" <> ":" <> "url(x)"

      for bad <- [injection, 0, -1, 1.5, "abc", "  3  ", true] do
        html = Render.render_block(grid_one(%{"span" => bad}), @article)

        refute String.contains?(html, "grid-column"),
               "span #{inspect(bad)} must NOT emit grid-column"

        refute String.contains?(html, "background"),
               "span #{inspect(bad)} must not leak an injected declaration"
      end
    end

    test "a stringy positive-int span IS honored (mirror of grid_tracks)" do
      html = Render.render_block(grid_one(%{"span" => "2"}), @article)
      assert cell_style(html) == "grid-column:span 2"
    end

    test "a malformed order drops (non-int), but a stringy int is honored" do
      assert cell_style(Render.render_block(grid_one(%{"order" => "1x"}), @article)) == nil
      assert cell_style(Render.render_block(grid_one(%{"order" => 1.0}), @article)) == nil
      assert cell_style(Render.render_block(grid_one(%{"order" => "2"}), @article)) == "order:2"
    end

    test "no per-child cell style ever carries a px literal (D2)" do
      for extra <- [%{"span" => 2}, %{"order" => 3}, %{"span" => 4, "order" => -1}] do
        style = grid_one(extra) |> Render.render_block(@article) |> cell_style()
        assert style != nil
        refute String.contains?(style, "px"), "cell style #{inspect(style)} must carry NO px (D2)"
      end
    end
  end
end
