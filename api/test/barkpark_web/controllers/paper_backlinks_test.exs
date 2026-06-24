defmodule BarkparkWeb.PaperBacklinksTest do
  @moduledoc """
  `BarkparkWeb.PaperBacklinks.section_html/1` — the reader's "Linked mentions"
  section render. Pure over the `Content.Graph.reverse_referencers/2` result
  shape (inbound-edge maps, no DB): N referencers → a section listing the
  linking titles; zero referencers → NO section (empty string). No context
  snippets — the indexed engine returns none (the old scan's snippets were
  dropped when the reader was repointed at the engine).
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.PaperBacklinks

  test "N referencers → a 'Linked mentions' section with linked titles" do
    referencers = [
      %{
        from_id: "uuid-alpha",
        from_doc_id: "p-alpha",
        title: "Alpha Paper",
        type: "paper",
        kind: "references",
        via_field: "references",
        plugin_source: "bulldocs"
      },
      %{
        from_id: "uuid-beta",
        from_doc_id: "p-beta",
        title: "Beta Paper",
        type: "paper",
        kind: "references",
        via_field: "references",
        plugin_source: nil
      }
    ]

    html = PaperBacklinks.section_html(referencers)

    assert html =~ "Linked mentions"
    assert html =~ ~s(<section)
    # Linked titles point at /papers/<from_doc_id>.
    assert html =~ ~s(href="/papers/p-alpha")
    assert html =~ ~s(href="/papers/p-beta")
    assert html =~ "Alpha Paper"
    assert html =~ "Beta Paper"
  end

  test "zero referencers → NO section (empty string)" do
    assert PaperBacklinks.section_html([]) == ""
  end

  test "a non-list input renders nothing (defensive)" do
    assert PaperBacklinks.section_html(nil) == ""
  end

  test "escapes HTML in titles" do
    referencers = [
      %{from_doc_id: "p-x", title: "Title <b>bold</b> & more", type: "paper"}
    ]

    html = PaperBacklinks.section_html(referencers)

    refute html =~ "<b>bold</b>"
    assert html =~ "&lt;b&gt;bold&lt;/b&gt;"
    assert html =~ "&amp; more"
  end

  test "falls back to the doc_id when a title is blank" do
    referencers = [%{from_doc_id: "p-untitled", title: ""}]
    html = PaperBacklinks.section_html(referencers)
    assert html =~ "p-untitled"
    assert html =~ ~s(href="/papers/p-untitled")
  end

  test "skips a referencer with no resolvable from_doc_id; omits an all-unresolved section" do
    # A source the engine could not hydrate under the caller's scope carries a
    # nil from_doc_id — it is skipped, never linked to an opaque id.
    referencers = [%{from_id: "uuid-only", from_doc_id: nil, title: "Hidden"}]
    assert PaperBacklinks.section_html(referencers) == ""

    # Mixed: one resolvable, one not → only the resolvable one renders.
    mixed = [
      %{from_id: "uuid-only", from_doc_id: nil, title: "Hidden"},
      %{from_doc_id: "p-shown", title: "Shown Paper"}
    ]

    html = PaperBacklinks.section_html(mixed)
    assert html =~ "Linked mentions"
    assert html =~ "Shown Paper"
    refute html =~ "Hidden"
  end
end
