defmodule Barkpark.PortableDoc.RenderSheetTest do
  @moduledoc """
  Tests for the `"sheet"` block compose and PdSheet walk in Render.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Render

  @opts %{doctype: false}

  # ── compose_block "sheet" ──────────────────────────────────────────────────

  describe "compose_block/2 — sheet" do
    test "block with full snapshot composes to PdSheet with head, rows, col_widths" do
      block = %{
        "type" => "sheet",
        "ref" => "sheet-1",
        "tab" => 0,
        "snapshot" => %{
          "head" => ["Name", "Score"],
          "rows" => [["Alice", "42"], ["Bob", "7"]],
          "col_widths" => [120, 80]
        }
      }

      pd = Render.compose_block(block)

      assert pd["kind"] == "PdSheet"
      assert pd["head"] == ["Name", "Score"]
      assert pd["rows"] == [["Alice", "42"], ["Bob", "7"]]
      assert pd["col_widths"] == [120, 80]
    end

    test "block with no snapshot composes to empty PdSheet" do
      block = %{"type" => "sheet", "ref" => "sheet-1"}
      pd = Render.compose_block(block)

      assert pd["kind"] == "PdSheet"
      assert pd["rows"] == []
      refute Map.has_key?(pd, "head")
      refute Map.has_key?(pd, "col_widths")
    end

    test "snapshot without head or col_widths composes correctly" do
      block = %{
        "type" => "sheet",
        "ref" => "sheet-1",
        "snapshot" => %{"rows" => [["a", "b"]]}
      }

      pd = Render.compose_block(block)

      assert pd["kind"] == "PdSheet"
      assert pd["rows"] == [["a", "b"]]
      refute Map.has_key?(pd, "head")
      refute Map.has_key?(pd, "col_widths")
    end

    test "compose_block/2 style arg is ignored for sheet (style-invariant)" do
      block = %{
        "type" => "sheet",
        "ref" => "s1",
        "snapshot" => %{"rows" => [["x"]]}
      }

      pd_email = Render.compose_block(block, :email)
      pd_article = Render.compose_block(block, :article)

      assert pd_email == pd_article
    end
  end

  # ── walk PdSheet → HTML (email / default) ─────────────────────────────────

  describe "render_html PdSheet — email mode" do
    test "empty rows renders empty table" do
      node = %{"kind" => "PdSheet", "rows" => []}
      html = Render.render_html(node, @opts)

      assert html =~ "<table"
      assert html =~ "</table>"
      assert html =~ "<tbody></tbody>"
    end

    test "rows without head renders flat td table" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["Alice", "42"], ["Bob", "7"]]
      }

      html = Render.render_html(node, @opts)

      assert html =~ "<tr>"
      assert html =~ "<td"
      assert html =~ "Alice"
      assert html =~ "42"
      assert html =~ "Bob"
      assert html =~ "7"
      refute html =~ "<thead>"
    end

    test "head field renders thead with th cells" do
      node = %{
        "kind" => "PdSheet",
        "head" => ["Name", "Score"],
        "rows" => [["Alice", "42"]]
      }

      html = Render.render_html(node, @opts)

      assert html =~ "<thead>"
      assert html =~ "<th"
      assert html =~ "Name"
      assert html =~ "Score"
    end

    test "col_widths applied to th and td cells" do
      node = %{
        "kind" => "PdSheet",
        "head" => ["A", "B"],
        "rows" => [["1", "2"]],
        "col_widths" => [80, 120]
      }

      html = Render.render_html(node, @opts)

      assert html =~ "width:80px"
      assert html =~ "width:120px"
    end

    test "cell values are HTML-escaped" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["<script>", "a&b"]]
      }

      html = Render.render_html(node, @opts)

      assert html =~ "&lt;script&gt;"
      assert html =~ "a&amp;b"
      refute html =~ "<script>"
    end

    test "a per-cell #rrggbb background is emitted into the td inline style" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["x"]],
        "styles" => %{"0,0" => %{"bg" => "#aabbcc"}}
      }

      html = Render.render_html(node, @opts)
      assert html =~ "background:#aabbcc"
    end

    test "a background with a trailing newline is REJECTED (no CSS-attr stowaway)" do
      # The stored bg is emitted into the `<td style="…">` attribute. "#aabbcc\n"
      # passes the old `$`-anchored copy but is rejected by the canonical `\z`
      # owner (CondFormat.valid_bg?/1) this path now delegates to — the newline
      # can never smuggle into the inline style attribute.
      node = %{
        "kind" => "PdSheet",
        "rows" => [["x"]],
        "styles" => %{"0,0" => %{"bg" => "#aabbcc\n"}}
      }

      html = Render.render_html(node, @opts)
      refute html =~ "background:#aabbcc"
    end

    test "an invalid background value is dropped" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["x"]],
        "styles" => %{"0,0" => %{"bg" => "#gggggg"}}
      }

      html = Render.render_html(node, @opts)
      refute html =~ "background:"
    end

    test "the bg style is produced with the Sheets PLUGIN absent — the walker resolves no plugin function" do
      # The fresh-install invariant, checked where it actually decides: what the
      # COMPILED walker calls. A paper embedding a sheet must render its
      # cond-format background on a box booted with the sheet plugin off, and
      # the only way that can hold is if the walker's own beam resolves nothing
      # in the plugin namespace. `:beam_lib`'s imports chunk IS that module's
      # external-call table, so this reds the moment a `Barkpark.Plugins.*` call
      # comes back into core render — where a text grep would also match the
      # comments that (correctly) name the canonical owner, the ImpT chunk
      # cannot be fooled by prose.
      beam = :code.which(Barkpark.PortableDoc.Render.Walk)
      {:ok, {_mod, [imports: imports]}} = :beam_lib.chunks(beam, [:imports])

      plugin_calls =
        imports
        |> Enum.filter(fn {m, _f, _a} ->
          String.starts_with?(Atom.to_string(m), "Elixir.Barkpark.Plugins.")
        end)
        |> Enum.uniq()

      assert plugin_calls == [],
             """
             PortableDoc.Render.Walk resolves plugin functions — core render              would break with that plugin off (fresh-install invariant):
               #{inspect(plugin_calls)}
             Mirror the rule locally (see `@sheet_bg_re` / `@error_values`) and              lock the mirror in sheets_parity_test.
             """

      # ...and the style string the local mirror produces is the SAME one the
      # plugin-calling version produced: accepted `#rrggbb` in, rejection out.
      styled = %{
        "kind" => "PdSheet",
        "rows" => [["x"]],
        "styles" => %{"0,0" => %{"bg" => "#aabbcc"}}
      }

      assert Render.render_html(styled, @opts) =~ "background:#aabbcc"
    end
  end

  # ── walk PdSheet → HTML (article mode) ─────────────────────────────────────

  describe "render_html PdSheet — article mode" do
    @article_opts %{doctype: false, style: :article}

    test "article mode renders thead with uppercase th styling" do
      node = %{
        "kind" => "PdSheet",
        "head" => ["Column"],
        "rows" => [["value"]]
      }

      html = Render.render_html(node, @article_opts)

      assert html =~ "<thead>"
      # Stage 2 wave 2: the header band is class-driven (`.bp-sheet__th` owns the
      # uppercase/muted/rule chrome); no inline theme.
      assert html =~ ~s(<th class="bp-sheet__th")
      refute html =~ "text-transform:uppercase"
      assert html =~ "Column"
      assert html =~ "value"
    end

    test "article mode applies monospace font to td cells" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["data"]]
      }

      html = Render.render_html(node, @article_opts)

      # Stage 2 wave 2: the mono font is class-driven (`.bp-sheet__td` resolves
      # `var(--paper-font-mono)`); no inline font-family on the cell.
      assert html =~ ~s(<td class="bp-sheet__td")
      refute html =~ "font-family:ui-monospace"
      assert html =~ "data"
    end
  end

  # ── hyperlink cells (display-time URL auto-detect) ─────────────────────────

  describe "render_html PdSheet — hyperlink cells" do
    @article_opts %{doctype: false, style: :article}

    test "an http(s) URL cell renders a safe anchor with rel=noopener (email mode)" do
      node = %{"kind" => "PdSheet", "rows" => [["https://example.com/a?b=1"]]}
      html = Render.render_html(node, @opts)

      assert html =~ ~s(<a href="https://example.com/a?b=1")
      assert html =~ ~s(rel="noopener noreferrer nofollow")
      assert html =~ ~s(target="_blank")
    end

    test "an http(s) URL cell renders a safe anchor (article mode)" do
      node = %{"kind" => "PdSheet", "rows" => [["http://example.com"]]}
      html = Render.render_html(node, @article_opts)

      assert html =~ ~s(<a href="http://example.com")
      assert html =~ ~s(rel="noopener noreferrer nofollow")
    end

    test "a javascript: value renders as plain escaped text — NO anchor" do
      node = %{"kind" => "PdSheet", "rows" => [["javascript:alert(1)"]]}
      html = Render.render_html(node, @opts)

      refute html =~ "<a "
      assert html =~ "javascript:alert(1)"
    end

    test "a data:text/html payload renders as plain text — NO anchor" do
      node = %{"kind" => "PdSheet", "rows" => [["data:text/html,<script>alert(1)</script>"]]}
      html = Render.render_html(node, @opts)

      refute html =~ "<a "
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end

    test "a URL that is only PART of the cell stays plain text — NO anchor" do
      node = %{"kind" => "PdSheet", "rows" => [["see http://example.com"]]}
      html = Render.render_html(node, @opts)

      refute html =~ "<a "
      assert html =~ "see http://example.com"
    end

    test "an attribute-breaking URL payload never becomes an anchor" do
      node = %{"kind" => "PdSheet", "rows" => [["http://x\" onmouseover=\"alert-1"]]}
      html = Render.render_html(node, @opts)

      refute html =~ "<a "
      refute html =~ "onmouseover=\"alert"
    end

    test "the head <th> band never links a URL — only body cells do" do
      node = %{"kind" => "PdSheet", "head" => ["https://example.com"], "rows" => [["x"]]}
      html = Render.render_html(node, @article_opts)

      # The <th> keeps escape_html (no anchor inside the head band).
      assert html =~ ~s(<th)
      refute html =~ ~s(<a href="https://example.com")
    end
  end

  # ── spreadsheet-default alignment (mirror of Studio's Cells.default_align_class) ──

  describe "render_html PdSheet — spreadsheet-default alignment class" do
    @article_opts %{doctype: false, style: :article}

    # A CLASS, not an inline style, on purpose (same mechanism as the Studio
    # grid's `Cells.default_align_class/1`): the sheets-parity suite pins the
    # inline b/i/bg/al styles identical across every render surface, so the
    # derived default must never leak into the <td>'s style attribute.
    test "a numeric cell right-aligns by default; a text cell does not" do
      node = %{"kind" => "PdSheet", "rows" => [["Alice", "42"]]}
      html = Render.render_html(node, @opts)

      assert html =~ ~r/<td class="sheet-al-right"[^>]*>42<\/td>/
      assert html =~ ~r/<td style="[^"]*">Alice<\/td>/
      refute html =~ ~r/<td[^>]*sheet-al-[^>]*>Alice<\/td>/
    end

    test "number-fmt display strings right-align (thousands/currency/percent/fixed/exponent)" do
      for v <- ["1,200", "$1,234.50", "-$1,234.50", "25.00%", "3.50", "-7", "1.0e-7"] do
        html = Render.render_html(%{"kind" => "PdSheet", "rows" => [[v]]}, @opts)
        assert html =~ ~s(class="sheet-al-right"), "value #{inspect(v)} did not right-align"
      end
    end

    test "date and datetime display strings right-align" do
      for v <- ["2026-06-12", "2026-06-12 10:30:00"] do
        html = Render.render_html(%{"kind" => "PdSheet", "rows" => [[v]]}, @opts)
        assert html =~ ~s(class="sheet-al-right"), "value #{inspect(v)} did not right-align"
      end
    end

    test "TRUE/FALSE (booleans and checkbox cells) center" do
      html = Render.render_html(%{"kind" => "PdSheet", "rows" => [["TRUE", "FALSE"]]}, @opts)

      assert html =~ ~r/<td class="sheet-al-center"[^>]*>TRUE<\/td>/
      assert html =~ ~r/<td class="sheet-al-center"[^>]*>FALSE<\/td>/
    end

    test "text, URL and engine-error cells get NO alignment class (inherit left)" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["hello", "see http://example.com", "#DIV/0!", ""]]
      }

      html = Render.render_html(node, @opts)
      refute html =~ "sheet-al-"
    end

    test "an explicit s.al=left on a numeric cell suppresses the class and stays left inline" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["42"]],
        "styles" => %{"0,0" => %{"al" => "left"}}
      }

      html = Render.render_html(node, @opts)

      refute html =~ "sheet-al-"
      assert html =~ "text-align:left;"
    end

    test "an explicit s.al=center suppresses the class (no duplicate mechanisms)" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["TRUE"]],
        "styles" => %{"0,0" => %{"al" => "center"}}
      }

      html = Render.render_html(node, @opts)

      refute html =~ "sheet-al-"
      assert html =~ "text-align:center;"
    end

    test "the article palette stamps the same classes" do
      node = %{"kind" => "PdSheet", "rows" => [["42", "TRUE", "x"]]}
      html = Render.render_html(node, @article_opts)

      # Stage 2 wave 2: the derived-align class now rides alongside the chrome
      # class in one attribute (`class="bp-sheet__td sheet-al-right"`), so match
      # the align token as a substring rather than the whole attribute.
      assert html =~ "sheet-al-right"
      assert html =~ "sheet-al-center"
    end

    test "the head <th> band never gets a default alignment class" do
      node = %{"kind" => "PdSheet", "head" => ["42"], "rows" => [["x"]]}

      for opts <- [@opts, @article_opts] do
        html = Render.render_html(node, opts)
        refute html =~ "sheet-al-"
      end
    end

    test "the default never leaks into the inline style attribute (parity seal)" do
      # sheets_parity_test extracts text-align from the INLINE styles across
      # all surfaces — a derived inline default would break A↔D↔F parity.
      html = Render.render_html(%{"kind" => "PdSheet", "rows" => [["42"]]}, @opts)
      refute html =~ "text-align"
    end
  end

  # Every class the walker stamps must have a real CSS rule in the layouts
  # that host walker HTML — same source-presence lock as the Studio grid's
  # cells_test ("shipped class-only (invisible) once already"). The walker's
  # own output stays inline-first; the alignment default is the one
  # class-carried style, by parity design.
  describe "alignment classes have CSS rules in the paper layouts" do
    @bulldocs_layout Path.expand(
                       "../../../lib/barkpark_web/layouts/bulldocs.html.heex",
                       __DIR__
                     )
    @root_layout Path.expand(
                   "../../../lib/barkpark_web/layouts/root.html.heex",
                   __DIR__
                 )

    test "the public paper reader (bulldocs.html.heex) styles both classes" do
      css = File.read!(@bulldocs_layout)
      assert css =~ "td.sheet-al-right { text-align: right; }"
      assert css =~ "td.sheet-al-center { text-align: center; }"
    end

    test "the Studio paper view (root.html.heex) styles both classes" do
      css = File.read!(@root_layout)
      assert css =~ "td.sheet-al-right { text-align: right; }"
      assert css =~ "td.sheet-al-center { text-align: center; }"
    end
  end

  # ── render_block end-to-end ─────────────────────────────────────────────────

  describe "render_block/2 — sheet block end-to-end" do
    test "renders a sheet block with snapshot to an HTML table fragment" do
      block = %{
        "id" => "s1",
        "type" => "sheet",
        "ref" => "sheet-abc",
        "snapshot" => %{
          "head" => ["Q", "A"],
          "rows" => [["x", "y"]]
        }
      }

      html = Render.render_block(block)

      assert html =~ "<table"
      assert html =~ "Q"
      assert html =~ "A"
      assert html =~ "x"
      assert html =~ "y"
    end

    test "renders a sheet block without snapshot to an empty table" do
      block = %{"id" => "s2", "type" => "sheet", "ref" => "sheet-xyz"}
      html = Render.render_block(block)

      assert html =~ "<table"
      assert html =~ "<tbody></tbody>"
    end
  end
end
