defmodule Barkpark.Plugins.Sheets.HtmlTest do
  @moduledoc """
  Focused unit tests for Barkpark.Plugins.Sheets.Html.export/2.

  Covers: default title, HTML escaping in title + tab names, single-tab
  (no heading rendered), multi-tab unnamed tabs (Sheet<n> fallback),
  self-contained output contract (no <script>, no <link>), and nil/missing
  content producing a valid page skeleton.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.Html
  alias Barkpark.Test.ExportedDocument

  defp single_tab_content do
    %{
      "tabs" => [
        %{
          "name" => "Data",
          "cells" => %{
            "A1" => %{"v" => "Col1"},
            "B1" => %{"v" => "Col2"},
            "A2" => %{"v" => "alpha"},
            "B2" => %{"v" => 7}
          }
        }
      ]
    }
  end

  defp two_tab_content do
    %{
      "tabs" => [
        %{"name" => "First", "cells" => %{"A1" => %{"v" => "one"}}},
        %{"cells" => %{"A1" => %{"v" => "two"}}}
      ]
    }
  end

  describe "export/2 — error cells" do
    # #NAME? is an error VALUE like every other `t: "e"` code — the html
    # exporter renders a cell's "v" verbatim, so it must reach the page as the
    # error string, not as an empty cell.
    test "a #NAME? cell reaches the page as the error string" do
      content = %{
        "tabs" => [
          %{
            "name" => "Data",
            "cells" => %{
              "A1" => %{"v" => "Label"},
              "A2" => %{"f" => "=FOO(1)", "v" => "#NAME?", "t" => "e"}
            }
          }
        ]
      }

      assert Html.export(content, "T") =~ "#NAME?"
    end
  end

  describe "export/2 — page skeleton" do
    test "always emits a valid standalone HTML document" do
      html = Html.export(single_tab_content(), "Report")

      assert html =~ "<!doctype html>"
      assert html =~ "<html>"
      assert html =~ ~s(<meta charset="utf-8">)
      assert html =~ "</body></html>"
    end

    test "self-contained: no external scripts or stylesheets" do
      html = Html.export(single_tab_content(), "Report")

      # WHOLE DOCUMENT ON PURPOSE: an external `<script src>` or
      # `<link rel="stylesheet">` would live in `<head>`, so scoping this to the
      # body would blind it. The export inlines the canonical paper-surface
      # stylesheet into that same `<head>`, so the CSS BYTES are excluded
      # structurally — the `<style>` element's content is dropped, the element
      # and the rest of the document stay — rather than by allowlisting the
      # literals the stylesheet happens to contain.
      doc = ExportedDocument.outside_stylesheet(html)

      # The excluded region is the stylesheet and nothing else: head and body
      # chrome are both still in scope, so these refutes can still fail.
      assert doc =~ "<title>Report</title>"
      assert doc =~ "</body></html>"

      refute doc =~ "<script"
      refute doc =~ "<link"
    end
  end

  describe "export/2 — title handling" do
    test "explicit title appears in <title> and <h1>" do
      html = Html.export(single_tab_content(), "My Sheet")

      assert html =~ "<title>My Sheet</title>"
      assert html =~ "<h1 style="
      assert html =~ ">My Sheet</h1>"
    end

    test "nil title defaults to 'Sheet'" do
      html = Html.export(single_tab_content(), nil)

      assert html =~ "<title>Sheet</title>"
      assert html =~ ">Sheet</h1>"
    end

    test "empty-string title defaults to 'Sheet'" do
      html = Html.export(single_tab_content(), "")

      assert html =~ "<title>Sheet</title>"
    end

    test "title with HTML special characters is escaped" do
      html = Html.export(single_tab_content(), "Q3 <Profits> & \"Losses\"")

      assert html =~ "<title>Q3 &lt;Profits&gt; &amp; &quot;Losses&quot;</title>"

      # The title reaches BOTH `<title>` (in `<head>`) and `<h1>` (in the body),
      # so this one refute must keep the head in scope — only the inlined
      # stylesheet's bytes are excluded, structurally.
      refute ExportedDocument.outside_stylesheet(html) =~ "<Profits>"
    end
  end

  describe "export/2 — tab headings" do
    test "single named tab: <h2> is still rendered with the tab name" do
      html = Html.export(single_tab_content(), "Report")

      # a named tab always gets an <h2>, even when it's the only tab
      assert html =~ "<h2 style="
      assert html =~ ">Data</h2>"
    end

    test "single unnamed tab: no <h2> rendered (only one tab, no name)" do
      content = %{"tabs" => [%{"cells" => %{"A1" => %{"v" => "x"}}}]}
      html = Html.export(content, "Report")

      refute ExportedDocument.body(html) =~ "<h2"
    end

    test "multi-tab: named tabs emit their name as <h2>" do
      html = Html.export(two_tab_content(), "Multi")

      assert html =~ "<h2 style="
      assert html =~ ">First</h2>"
    end

    test "multi-tab: unnamed tab falls back to Sheet<n>" do
      html = Html.export(two_tab_content(), "Multi")

      # second tab has no name → Sheet2
      assert html =~ ">Sheet2</h2>"
    end

    test "tab name with special characters is escaped in <h2>" do
      content = %{
        "tabs" => [
          %{"name" => "Tab A", "cells" => %{"A1" => %{"v" => "x"}}},
          %{"name" => "<script>alert(1)</script>", "cells" => %{"A1" => %{"v" => "y"}}}
        ]
      }

      html = Html.export(content, "Test")

      assert html =~ "&lt;script&gt;alert(1)&lt;/script&gt;</h2>"
      refute ExportedDocument.body(html) =~ "<script>alert(1)</script>"
    end
  end

  describe "export/2 — empty / nil content" do
    test "content with no 'tabs' key still yields a valid page" do
      html = Html.export(%{}, "Empty")

      assert html =~ "<!doctype html>"
      assert html =~ "<title>Empty</title>"
      assert html =~ "</body></html>"
    end

    test "empty tabs list yields a valid page with no sections" do
      html = Html.export(%{"tabs" => []}, "No Tabs")

      assert html =~ "<title>No Tabs</title>"
      refute ExportedDocument.body(html) =~ "<table"
      assert html =~ "</body></html>"
    end
  end

  describe "export/2 — cell content escaping (XSS defense)" do
    # Protective test for the Sobelow XSS.SendResp skip on
    # `ExportController.export_html/2`: the export serves this HTML inline
    # (`text/html`), so an unescaped user cell would be stored XSS when the
    # export is viewed. A cell value carrying markup must render inert.
    test "a cell value with an HTML/script payload is escaped, not injected" do
      content = %{
        "tabs" => [
          %{
            "name" => "Data",
            "cells" => %{
              "A1" => %{"v" => "<script>alert('xss')</script>"},
              "A2" => %{"v" => "<img src=x onerror=\"alert(1)\">"}
            }
          }
        ]
      }

      html = Html.export(content, "Report")

      # The dangerous markup is HTML-escaped in the rendered grid …
      assert html =~ "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"
      assert html =~ "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;"
      # … and no live <script>/onerror sink reaches the output body.
      body = ExportedDocument.body(html)
      refute body =~ "<script>alert('xss')</script>"
      refute body =~ "<img src=x onerror=\"alert(1)\">"
    end
  end

  # ── refute scoping: the regions themselves ────────────────────────────────
  #
  # Every absence assertion above runs against a region DERIVED from the export
  # document rather than against the whole string, because the document inlines
  # the canonical paper-surface stylesheet. These two tests are the control pair
  # for that scoping, in both directions: a literal that exists only inside the
  # stylesheet must be invisible, and a literal the export really emits must
  # still be visible. The second is the one that matters — a scoping that made
  # these refutes unable to fail would be worse than the bug it fixes.
  describe "export/2 — refute region scoping" do
    test "a tag literal living only in the inlined stylesheet is outside both regions" do
      html = Html.export(single_tab_content(), "Report")

      [before_close, after_close] = String.split(html, "</style>", parts: 2)

      injected = ~s(/* <h2 class="bp-section__title"> <table> <script src="x"> */)
      mutated = before_close <> injected <> "</style>" <> after_close

      # Control: the literals really are in the mutated document, so the
      # refutes below are a claim about the SCOPING and not about an absence
      # that was there anyway.
      assert mutated =~ ~s(<h2 class="bp-section__title">)
      assert mutated =~ "<script src="

      body = ExportedDocument.body(mutated)
      refute body =~ ~s(<h2 class=)
      refute body =~ "<script src="

      outside = ExportedDocument.outside_stylesheet(mutated)
      refute outside =~ ~s(<h2 class=)
      refute outside =~ "<script src="
    end

    test "a tag the export really emits into the body is still visible to both regions" do
      # single_tab_content/0 has a NAMED tab, so the export emits a real <h2>
      # and a real <table>. If the scoping above could not see these, every
      # refute in this file would have gone vacuous.
      html = Html.export(single_tab_content(), "Report")

      body = ExportedDocument.body(html)
      assert body =~ "<h2"
      assert body =~ "<table"

      assert ExportedDocument.outside_stylesheet(html) =~ "<h2"
    end

    test "body/1 raises rather than degrading to an empty region" do
      assert_raise ArgumentError, fn -> ExportedDocument.body("<p>no head here</p>") end
    end

    test "outside_stylesheet/1 raises when there is no inlined stylesheet to exclude" do
      assert_raise ArgumentError, fn ->
        ExportedDocument.outside_stylesheet(
          "<!doctype html><html><head></head><body></body></html>"
        )
      end
    end
  end
end
