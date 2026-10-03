defmodule BarkparkWeb.BulldocsBacklinksDraftSourceTest do
  @moduledoc """
  task-1005db05b44e2c39 — the anonymous paper reader's "Related papers" section rendered
  the title and description of an UNPUBLISHED paper that links to it.

  `BulldocsLive.assign_linked_sections/3` builds the section from
  `Content.Graph.reverse_referencers/2`, whose `docs_by_id/2` hydration scoped
  by tenancy, owner and grants only — never by perspective. Whether a draft
  could appear there rested entirely on the edge projector: its default
  REBUILD reads the published corpus, but with `incremental_project` on, a
  draft save upserts that draft's outbound edges from the draft row's PK
  (`Projector.doc_pk/2` falls back to the `drafts.` twin when no published row
  exists). The reader then hydrated the draft row and printed its title and
  description to an anonymous visitor.

  The edge is written here exactly as the incremental projector writes it:
  `Content.add_edges/2` with the bare slug, which resolves to the draft row
  when the paper has never been published.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tenancy}

  @ds "production"
  @target "bl-draft-target"
  @published_src "bl-published-src"
  @draft_src "bl-embargoed-src"

  defp heading(text) do
    [
      %{"id" => "title", "type" => "heading", "level" => 1, "text" => text},
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Body."}]
      }
    ]
  end

  setup do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: @target, blocks: heading("Backlink target")})
      )

    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @published_src,
          blocks: heading("Published citing paper")
        })
      )

    scope = [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

    {:ok, _} =
      Content.create_document(
        "paper",
        %{
          "doc_id" => @draft_src,
          "title" => "Embargoed merger announcement",
          "content" => %{
            "description" => "Acquisition closes Friday",
            "blocks" => heading("Embargoed merger announcement")
          }
        },
        @ds,
        scope
      )

    Content.add_edges(
      [
        %{from_id: @published_src, to_id: @target, kind: "references"},
        %{from_id: @draft_src, to_id: @target, kind: "references"}
      ],
      [dataset: @ds] ++ scope
    )

    :ok
  end

  test "ANONYMOUS reader: an unpublished citing paper's title and description stay hidden",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, "/papers/#{@target}")

    # CONTROL: the section renders, with the published citing paper.
    assert html =~ "Published citing paper"

    refute html =~ "Embargoed merger announcement"
    refute html =~ "Acquisition closes Friday"
  end

  test "reverse_referencers/2 with published_only drops a draft source; without it keeps it" do
    scope = [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

    all = Content.Graph.reverse_referencers(@target, [dataset: @ds] ++ scope)
    assert "drafts.#{@draft_src}" in Enum.map(all, & &1.from_doc_id)

    published =
      Content.Graph.reverse_referencers(@target, [dataset: @ds, published_only: true] ++ scope)

    assert Enum.map(published, & &1.from_doc_id) == [@published_src]
  end
end
