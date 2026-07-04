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
  # LIMITATION (stated honestly): the allowlist is by property NAME, so a name
  # with ANY permanent DATA use (e.g. `color`, `background`, `margin`, `padding`)
  # cannot be removed and thus won't catch a THEME reintroduction of that SAME
  # property. The ratchet bites hardest on the pure-THEME names below (removing
  # them makes reintroduction fail CI); the charter's grep-refute of `[style*=`
  # selectors in root.html.heex (Decision 8) is the complementary guard for the
  # dual-use names.

  # Each entry: {property, classification}. Classification is DOCUMENTARY — the
  # assertion only checks set membership — but it names the later slice that
  # retires each THEME row, so the diff that deletes the walk.ex emission knows
  # exactly which line to delete here too.
  #
  #   :data  — permanent. Author content; survives a stylesheet-less surface.
  #   :theme — to be DELETED (with its walk.ex emission) in the named slice.
  @allowlist [
    # ── DATA — author content, stays inline forever ──────────────────────────
    # A `:data` name may ALSO have a `:theme` co-user today (noted inline); the
    # name persists because the DATA use is permanent, so its ratcheting power
    # is limited to blocking brand-new property names (see LIMITATION above).
    {"background", :data},
    # DATA: sheet per-cell `bg` (sheets_parity-pinned).
    # theme co-users → container paper, callout/collapsible bg, inline-code chip,
    #   tag chip (retire in Wave 2 slices 4 & 5 + prose slice 3).
    {"background-color", :data},
    # PdBox `backgroundColor` geometry.
    {"border", :data},
    # DATA: PdBox border geometry. theme co-user → hr `border:none` reset (slice 5).
    {"border-top", :data},
    # DATA: PdHr thickness. theme co-user → hr rule colour (slice 5).
    {"color", :data},
    # DATA: author PdText/PdParagraph colour mark + sheet error mark.
    # theme co-users → container/heading/link/muted-role/button/chip colours
    #   (retire across slices 3, 4, 5).
    {"display", :data},
    # DATA: PdBox flex geometry. theme co-users → pullquote block, button
    #   inline-block (slices 4 & 5).
    {"flex-direction", :data},
    # PdBox flex geometry.
    {"font-style", :data},
    # DATA: author italic mark + sheet per-cell `i`. theme co-user → unresolved
    #   embed italic (slice 5).
    {"font-weight", :data},
    # DATA: author bold mark + sheet per-cell `b` + sheet error bold.
    # theme co-users → heading/eyebrow/summary/button weight (slices 3, 4, 5).
    {"height", :data},
    # DATA: PdBox height geometry + PdImage `height:auto` responsive reset.
    {"margin", :data},
    # DATA: PdBox margin geometry. theme co-users → container/list/hr/byline/
    #   pullquote/truncation-note margins (slices 3, 4, 5).
    {"max-width", :data},
    # DATA: PdContainer maxWidth + PdImage `max-width:100%`.
    {"padding", :data},
    # DATA: PdBox padding geometry. theme co-users → container/callout/table/
    #   sheet/tag/button padding (slices 3, 4, 5).
    {"text-align", :data},
    # DATA: sheet per-cell explicit `al` (sheets_parity-pinned). theme co-users →
    #   table/sheet header `text-align:left` (slice 5).
    {"text-decoration", :data},
    # DATA: author underline/strike marks + sheet URL-cell link. theme co-users →
    #   link/wikilink/tag/button decoration (slices 3, 4, 5).
    {"vertical-align", :data},
    # DATA: PdBox verticalAlign geometry. theme co-user → table/sheet cell
    #   `vertical-align:top` (slice 5).
    {"width", :data},
    # DATA: sheet col_widths + PdBox width geometry. theme co-user → table/sheet
    #   `width:100%` (slice 5).

    # ── THEME — pure structural chrome, retire entirely in the named slice ────
    {"border-bottom", :theme},
    # link soft-border + byline rule + table/sheet header & cell rules (slices 3,4,5).
    {"border-collapse", :theme},
    # table/sheet chrome (slice 5).
    {"border-left", :theme},
    # callout/collapsible/pullquote/embed accent bar (slices 4 & 5).
    {"border-radius", :theme},
    # inline-code/tag/task-chip/button corners (slices 3, 4, 5).
    {"cursor", :theme},
    # collapsible <summary> pointer (slice 4).
    {"font-family", :theme},
    # container/heading/role/table/sheet/code typography (slices 3, 4, 5).
    {"font-size", :theme},
    # heading/role/code/table/sheet/chip/note type scale (slices 3, 4, 5).
    {"letter-spacing", :theme},
    # heading + eyebrow + table/sheet header tracking (slices 3, 4, 5).
    {"line-height", :theme},
    # heading/ingress/pullquote/list rhythm (slices 3 & 4).
    {"margin-top", :theme},
    # collapsible callout inner spacing (slice 4).
    {"padding-bottom", :theme},
    # byline rule spacing (slice 4).
    # list indent (slice 3).
    {"text-transform", :theme},
    # eyebrow + table/sheet header uppercasing (slices 4 & 5).
    {"white-space", :theme}
    # task-chip `nowrap` (slice 5).
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
      # Article-only signals: serif heading font + the soft link border. If the
      # render silently fell back to :email these vanish and the whole inventory
      # would be measuring the wrong palette.
      assert html =~ "Iowan Old Style"
      assert html =~ "border-bottom:1px solid var(--paper-rule"  # byline rule stays inline (theme; retires slice 4)
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
