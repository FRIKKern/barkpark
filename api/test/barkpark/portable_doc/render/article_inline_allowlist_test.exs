defmodule Barkpark.PortableDoc.Render.ArticleInlineAllowlistTest do
  # Pure, in-process render — no DB, no Phoenix boot.
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render
  alias Barkpark.PortableDoc.Render.ParityFixture

  # ── the Stage-2 article inline-style RATCHET (Wave 1, rail B) ────────────────
  #
  # Endgame (charter Decision 3): in `:article` mode the ONLY inline `style=`
  # left on renderer output is author DATA — content that must survive a surface
  # with no stylesheet (email, a bare .html export). Everything structural
  # (typography, spacing, tone colours, table/sheet/chip chrome) moves to the
  # single paper-surface stylesheet, so View and Edit render the same selectors
  # by construction.
  #
  # This test pins the CSS PROPERTY NAMES that `:article` output may carry inline
  # against @allowlist, which is SEEDED WITH TODAY'S FULL REALITY. The contract
  # is exact-set-equality, which makes the list SHRINK-ONLY in practice:
  #
  #   • A property emitted but NOT allowlisted (a reintroduced structural inline
  #     style) fails immediately — the tripwire.
  #   • An allowlisted property no longer emitted (a THEME entry whose walk.ex
  #     emission moved to a class) ALSO fails — forcing the deletion to land in
  #     the SAME diff as the walk.ex change. That is the ratchet: THEME entries
  #     leave the list one migration slice at a time and can never silently
  #     return.
  #
  # LIMITATION (stated honestly): the allowlist is by property NAME. Now that the
  # list is TERMINAL, any brand-new property name on `:article` output fails
  # immediately (the tripwire). The one remaining hole is a THEME REUSE of a name
  # that still has a permanent DATA use (e.g. `color`, `background`, `margin`,
  # `padding`) — those names can't be removed, so a THEME reintroduction of that
  # SAME property slips past. The charter's grep-refute of `[style*=` selectors in
  # root.html.heex (Decision 8) is the complementary guard for those dual-use names.

  # Each entry: {property, classification}. Classification is DOCUMENTARY — the
  # assertion only checks set membership. As of Stage-2 wave 2 the list is
  # TERMINAL: every `:theme` row has been retired (its walk.ex emission moved to
  # a `.bp-paper-surface` class rule), so the ONLY inline `style=` on `:article`
  # output is author DATA — content that must survive a stylesheet-less sink.
  #
  #   :data  — permanent. Author content; survives a stylesheet-less surface.
  @allowlist [
    # ── DATA — author content, stays inline forever (TERMINAL, data-only) ─────
    {"background", :data},
    # sheet per-cell `bg` (sheets_parity-pinned).
    {"background-color", :data},
    # PdBox `backgroundColor` geometry.
    {"border", :data},
    # PdBox border geometry.
    {"border-top-width", :data},
    # PdHr thickness — article emits `border-top-width:Npx`; the rule colour +
    #   `border:none` reset moved to `.bp-hr`.
    {"color", :data},
    # author PdText/PdParagraph colour mark + sheet error mark.
    {"display", :data},
    # PdBox flex geometry (`display:flex`).
    {"flex-direction", :data},
    # PdBox flex geometry.
    {"font-style", :data},
    # author italic mark + sheet per-cell `i`.
    {"font-weight", :data},
    # author bold mark + sheet per-cell `b` + sheet error bold.
    {"height", :data},
    # PdBox height geometry + PdImage `height:auto` responsive reset.
    {"margin", :data},
    # PdContainer `margin:0 auto` + PdBox margin geometry.
    {"max-width", :data},
    # PdContainer maxWidth + PdImage `max-width:100%`.
    {"padding", :data},
    # PdContainer `padding:24px` + PdBox padding geometry.
    {"text-align", :data},
    # sheet per-cell explicit `al` (sheets_parity-pinned).
    {"text-decoration", :data},
    # author underline/strike marks.
    {"vertical-align", :data},
    # PdBox verticalAlign geometry.
    {"width", :data}
    # sheet col_widths + PdBox width geometry.
  ]

  @allowed MapSet.new(@allowlist, fn {prop, _class} -> prop end)

  describe ":article inline-style ratchet" do
    test "every inline style property is on the allowlist, and the allowlist has no dead rows" do
      emitted = emitted_style_properties()

      # New structural inline style slipped in → not on the allowlist.
      unexpected = MapSet.difference(emitted, @allowed)

      # A THEME row whose emission already moved to a class → stale allowlist row
      # that must be deleted in THIS diff (the shrink-only ratchet).
      stale = MapSet.difference(@allowed, emitted)

      assert MapSet.size(unexpected) == 0, """
      New inline style property on :article renderer output — this is a
      structural style that must move to the paper-surface stylesheet, or (if it
      is genuinely author DATA) be added to @allowlist as :data with a comment:

        #{unexpected |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")}
      """

      assert MapSet.size(stale) == 0, """
      @allowlist carries #{MapSet.size(stale)} property(ies) no longer emitted by
      :article output. If your slice moved their emission to a class, DELETE the
      matching @allowlist row in this same diff (the ratchet is shrink-only):

        #{stale |> MapSet.to_list() |> Enum.sort() |> Enum.join(", ")}
      """
    end

    test "@allowlist has no duplicate property rows" do
      names = Enum.map(@allowlist, fn {prop, _} -> prop end)
      dupes = names -- Enum.uniq(names)
      assert dupes == [], "duplicate allowlist rows: #{inspect(Enum.uniq(dupes))}"
    end

    test "the fixture actually exercises the article palette (guards a mis-wired render)" do
      html = Render.render_html(ParityFixture.tree(), ParityFixture.render_opts(:article))
      # Article-only signals: the role + tone CLASS emission. `:email` never
      # stamps `bp-role-*` or `bp-callout--*` (its clauses emit inline styles),
      # so if the render silently fell back to :email these vanish and the whole
      # inventory would be measuring the wrong palette. (Wave 2 moved the byline
      # rule from an inline `border-bottom` to the `.bp-role-byline` class — hence
      # a class signal now, not an inline one.)
      assert html =~ ~s(class="bp-role-byline")
      assert html =~ ~s(class="bp-callout bp-callout--info")
      assert MapSet.size(emitted_style_properties()) > 0
    end
  end

  # Render the shared all-kinds fixture in :article mode and inventory every CSS
  # property NAME that appears inside a `style="…"` attribute. Values are
  # attribute-escaped (`"` → `&quot;`), so a raw `"` never appears inside a style
  # body and the `[^"]*` capture is exact.
  defp emitted_style_properties do
    html = Render.render_html(ParityFixture.tree(), ParityFixture.render_opts(:article))

    ~r/style="([^"]*)"/
    |> Regex.scan(html)
    |> Enum.flat_map(fn [_, body] -> String.split(body, ";", trim: true) end)
    |> Enum.map(fn decl -> decl |> String.split(":", parts: 2) |> hd() |> String.trim() end)
    |> MapSet.new()
  end
end
