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

      refute html =~ "<script"
      refute html =~ "<link"
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
      refute html =~ "<Profits>"
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

      refute html =~ "<h2"
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
      refute html =~ "<script>alert(1)</script>"
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
      refute html =~ "<table"
      assert html =~ "</body></html>"
    end
  end
end
