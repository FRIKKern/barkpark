defmodule BarkparkWeb.PaperBacklinksTest do
  @moduledoc """
  `BarkparkWeb.PaperBacklinks.section_html/1` — graph-backed related Paper cards.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.PaperBacklinks

  test "N referencers → rich related-Paper cards with real details" do
    referencers = [
      %{
        from_id: "uuid-alpha",
        from_doc_id: "p-alpha",
        title: "Alpha Paper",
        description: "The weekly product and delivery brief.",
        event_type: "weekly_review",
        rev: "17",
        updated_at: ~U[2026-08-23 07:00:00Z],
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

    assert html =~ "Related papers"
    assert html =~ "Live from Barkpark’s content graph"
    assert html =~ ~s(data-live="true")
    assert html =~ "The weekly product and delivery brief."
    assert html =~ "Weekly review"
    assert html =~ "Updated 23 Aug 2026"
    assert html =~ ~s(data-paper-revision="17")
    refute html =~ "Rev 17"
    assert html =~ ~s(class="bp-paper-card")
    assert html =~ ~s(style="display:flex;min-width:0;min-height:10.5rem)
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

  test "keeps the graph useful without turning the reader into a card wall" do
    referencers =
      for index <- 1..6 do
        %{
          from_doc_id: "paper-#{index}",
          title: "Paper #{index}",
          type: "paper",
          event_type: "changelog.day"
        }
      end

    html = PaperBacklinks.section_html(referencers)

    assert length(Regex.scan(~r/class="bp-paper-card"/, html)) == 4
    assert html =~ "Daily edition"
    refute html =~ "Changelog.day"
    refute html =~ "Paper 5"
    refute html =~ "Paper 6"
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
    assert html =~ "Related papers"
    assert html =~ "Shown Paper"
    refute html =~ "Hidden"
  end

  test "keeps task referencers in the dedicated Driven tasks component" do
    assert PaperBacklinks.section_html([
             %{from_doc_id: "task-1", title: "Ship it", type: "task", kind: "references"}
           ]) == ""
  end

  describe "'Used by' grouping — valueref-kind referencers (lvw-t3)" do
    # The body-walk extractor (#714) emits kind: "valueref" for docs whose body
    # inline-references a canonical value doc. The reader groups those under a
    # dedicated "Used by" section (the impact list), FIRST, leaving every other
    # referencer in the related-Papers section.

    defp valueref_ref(doc_id, title) do
      %{
        from_id: "uuid-#{doc_id}",
        from_doc_id: doc_id,
        title: title,
        type: "paper",
        kind: "valueref",
        via_field: "valueref",
        plugin_source: "bulldocs"
      }
    end

    test "valueref referencers render under 'Used by'; others stay under related Papers" do
      referencers = [
        valueref_ref("p-impact", "Impact Paper"),
        %{
          from_id: "uuid-mention",
          from_doc_id: "p-mention",
          title: "Mention Paper",
          type: "paper",
          kind: "references",
          via_field: "references",
          plugin_source: nil
        }
      ]

      html = PaperBacklinks.section_html(referencers)

      # Both sections render; "Used by" comes FIRST. Split on the mentions
      # section's class: everything before it is the Used-by group.
      assert [used_by_html, mentions_html] =
               String.split(html, ~s(class="bp-paper-connections bp-paper-related"))

      assert used_by_html =~ "bp-paper-usedby"
      assert used_by_html =~ "Used by"
      assert used_by_html =~ "Impact Paper"
      assert used_by_html =~ ~s(href="/papers/p-impact")
      refute used_by_html =~ "Mention Paper"

      assert mentions_html =~ "Related papers"
      assert mentions_html =~ "Mention Paper"
      refute mentions_html =~ "Impact Paper"
    end

    test "valueref-only input renders ONLY the Used by section" do
      html = PaperBacklinks.section_html([valueref_ref("p-only", "Only User")])

      assert html =~ "Used by"
      assert html =~ "Only User"
      refute html =~ "Related papers"
      refute html =~ "bp-paper-related"
    end

    test "an all-unresolved valueref group leaves NO Used by markup (fail-closed, no stub)" do
      # A valueref source the engine could not hydrate under the caller's scope
      # arrives with a nil from_doc_id (reverse_referencers already dropped the
      # hidden ones entirely — MEDIUM-5); a defensive nil here renders nothing:
      # no stub row, no aggregate count, no empty section.
      hidden = %{valueref_ref("p-hidden", "Hidden User") | from_doc_id: nil}
      assert PaperBacklinks.section_html([hidden]) == ""
    end
  end
end
