defmodule Barkpark.Plugins.Sheets.MarkdownHtmlTest do
  @moduledoc """
  M5 Markdown + standalone-HTML export locks. Markdown is documented-lossy
  (values only, GitHub table per tab); HTML reuses the reader's sheet table
  renderer so merges and styles paint exactly as at /papers/:slug. Pure
  unit tests, no DB.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Sheets.{Html, Markdown}

  defp content do
    %{
      "tabs" => [
        %{
          "name" => "Scores",
          "frozen_rows" => 1,
          "merges" => ["A2:B2"],
          "cells" => %{
            "A1" => %{"v" => "Name"},
            "B1" => %{"v" => "Score"},
            "A2" => %{"v" => "merged band", "s" => %{"b" => true, "bg" => "#ffcc00"}},
            "A3" => %{"v" => "Alice|Bob"},
            "B3" => %{"f" => "1+1", "v" => 2, "t" => "n"}
          }
        },
        %{"cells" => %{"A1" => %{"v" => "two"}}}
      ]
    }
  end

  describe "Markdown.export/1" do
    test "frozen first row becomes the table header; values only" do
      md = Markdown.export(content())

      assert md =~ "## Scores"
      assert md =~ "| Name | Score |"
      assert md =~ "| --- | --- |"
      # formula cell flattens to its cached value — lossy by design
      assert md =~ "| 2 |"
      refute md =~ "1+1"
      # merges/styles do not travel
      refute md =~ "ffcc00"
    end

    test "pipes escape" do
      assert Markdown.export(content()) =~ ~s(Alice\\|Bob)
    end

    test "without a frozen row the header synthesizes column letters" do
      md = Markdown.export(%{"tabs" => [%{"cells" => %{"B2" => %{"v" => "x"}}}]})
      assert md =~ "| A | B |"
      assert md =~ "|  | x |"
    end

    test "unnamed tabs in a multi-tab doc get Sheet<n> headings" do
      assert Markdown.export(content()) =~ "## Sheet2"
    end

    test "empty content exports to an empty string" do
      assert Markdown.export(%{}) == ""
    end
  end

  describe "Html.export/2" do
    test "standalone page with title, tab headings and the reader's table renderer" do
      html = Html.export(content(), "Q3 <Scores>")

      assert html =~ "<!doctype html>"
      assert html =~ "<title>Q3 &lt;Scores&gt;</title>"
      assert html =~ "<h2 style="
      assert html =~ "Scores</h2>"
      assert html =~ "<table role=\"presentation\""
      # head band renders via the article palette's thead
      assert html =~ "<thead>"
      assert html =~ ">Name</th>"
      # merges + styles ride the same renderer the reader uses
      assert html =~ ~s(colspan="2")
      assert html =~ "font-weight:bold;"
      assert html =~ "background:#ffcc00;"
      # no scripts, no external CSS — self-contained
      refute html =~ "<script"
      refute html =~ "<link"
    end

    test "title defaults and escapes; empty content still renders a page" do
      html = Html.export(%{}, nil)
      assert html =~ "<title>Sheet</title>"
      assert html =~ "</body></html>"
    end
  end
end
