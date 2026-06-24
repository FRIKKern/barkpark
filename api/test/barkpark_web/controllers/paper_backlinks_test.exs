defmodule BarkparkWeb.PaperBacklinksTest do
  @moduledoc """
  `BarkparkWeb.PaperBacklinks.section_html/1` — the reader's "Linked mentions"
  section render. Pure over the `Content.Backlinks` result shape (no DB): N
  backlinks → a section listing linked titles + snippets; zero backlinks → NO
  section (empty string).
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.PaperBacklinks

  test "N backlinks → a 'Linked mentions' section with linked titles + snippets" do
    backlinks = [
      %{
        slug: "p-alpha",
        title: "Alpha Paper",
        contexts: [%{text: "Alpha mentions the target here.", match: :precise}]
      },
      %{
        slug: "p-beta",
        title: "Beta Paper",
        contexts: [%{text: "Beta names it loosely.", match: :fallback}]
      }
    ]

    html = PaperBacklinks.section_html(backlinks)

    assert html =~ "Linked mentions"
    assert html =~ ~s(<section)
    # Linked titles point at /papers/<slug>.
    assert html =~ ~s(href="/papers/p-alpha")
    assert html =~ ~s(href="/papers/p-beta")
    assert html =~ "Alpha Paper"
    assert html =~ "Beta Paper"
    # Context snippets render.
    assert html =~ "Alpha mentions the target here."
    assert html =~ "Beta names it loosely."
    # A fallback-only context carries the muted "~" affordance; a precise one
    # does not get the best-effort marker.
    assert html =~ "best-effort match"
  end

  test "zero backlinks → NO section (empty string)" do
    assert PaperBacklinks.section_html([]) == ""
  end

  test "a non-list input renders nothing (defensive)" do
    assert PaperBacklinks.section_html(nil) == ""
  end

  test "escapes HTML in titles and snippets" do
    backlinks = [
      %{
        slug: "p-x",
        title: "Title <b>bold</b> & more",
        contexts: [%{text: ~s(snippet with <script> & "quote"), match: :precise}]
      }
    ]

    html = PaperBacklinks.section_html(backlinks)

    refute html =~ "<b>bold</b>"
    refute html =~ "<script>"
    assert html =~ "&lt;b&gt;bold&lt;/b&gt;"
    assert html =~ "&amp; more"
  end

  test "falls back to the slug when a title is blank" do
    backlinks = [%{slug: "p-untitled", title: "", contexts: []}]
    html = PaperBacklinks.section_html(backlinks)
    assert html =~ "p-untitled"
    assert html =~ ~s(href="/papers/p-untitled")
  end
end
