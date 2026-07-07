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
end
