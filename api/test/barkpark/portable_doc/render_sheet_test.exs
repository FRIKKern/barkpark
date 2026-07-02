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
      assert html =~ "text-transform:uppercase"
      assert html =~ "Column"
      assert html =~ "value"
    end

    test "article mode applies monospace font to td cells" do
      node = %{
        "kind" => "PdSheet",
        "rows" => [["data"]]
      }

      html = Render.render_html(node, @article_opts)

      assert html =~ "font-family:ui-monospace"
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
