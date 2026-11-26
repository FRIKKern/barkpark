defmodule BarkparkWeb.BulldocsReaderDeleteSiblingTest do
  @moduledoc """
  task-9097b1abe87e7b06: two published same-slug papers in two projects of the
  Default workspace. A reader open on P1's paper (the oldest, so the one
  `/papers/<slug>` serves) got P1's delete frame and re-read the slug through
  the public resolver, which now found only P2's row and painted it live. The
  reader's re-reads keep to the mounted paper's project, so P1's delete reads
  as gone.

  Deletes go through `Content.apply_mutations/3`: a direct
  `Content.delete_document/4` call under the sandbox broadcasts nothing (see
  `bulldocs_reader_deleted_paper_test.exs`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  setup do
    {ws, p1} = Barkpark.TenancyFixtures.ensure_default_scope!()
    p2 = Barkpark.TenancyFixtures.create_project!(ws)
    ds = Content.paper_default_dataset()

    for p <- [p1, p2] do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "paper",
            "title" => "Papers",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          ds,
          workspace_id: ws.id,
          project_id: p.id
        )
    end

    Barkpark.LabelFixtures.register_tags!(ds)
    %{ws: ws, p1: p1, p2: p2, ds: ds, slug: "rds-#{System.unique_integer([:positive])}"}
  end

  defp paper!(c, p, text) do
    {:ok, doc} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => c.slug,
          "title" => "T",
          "dataset" => c.ds,
          "workspace_id" => c.ws.id,
          "project_id" => p.id,
          "blocks" => [
            %{"id" => "h-1", "type" => "heading", "text" => "Title"},
            %{
              "id" => "b-1",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => text}]
            }
          ]
        })
      )

    assert doc.project_id == p.id
    doc
  end

  defp delete!(c, p) do
    assert {:ok, _} =
             Content.apply_mutations(
               [%{"delete" => %{"id" => c.slug, "type" => "paper"}}],
               c.ds,
               source: :api,
               workspace_id: c.ws.id,
               project_id: p.id
             )
  end

  defp open!(conn, c) do
    paper!(c, c.p1, "P1 words")
    paper!(c, c.p2, "P2 words")
    {:ok, view, html} = live(conn, "/papers/#{c.slug}")
    assert html =~ "P1 words"
    view
  end

  defp settle(view) do
    _ = :sys.get_state(view.pid)
    render(view)
  end

  test "deleting P1's paper never paints P2's paper in the open P1 reader", %{conn: conn} = c do
    view = open!(conn, c)

    delete!(c, c.p1)
    assert Content.get_public_paper(c.slug, c.ds).project_id == c.p2.id

    out = settle(view)
    refute out =~ "P2 words"
    refute out =~ "P1 words"
    assert out =~ ~s(id="paper-empty")
    assert Process.alive?(view.pid)
  end

  test "control: deleting P2's paper leaves the open P1 reader on P1", %{conn: conn} = c do
    view = open!(conn, c)

    delete!(c, c.p2)

    out = settle(view)
    assert out =~ "P1 words"
    refute out =~ "P2 words"
  end

  test "control: P1's own update still repaints the open P1 reader", %{conn: conn} = c do
    view = open!(conn, c)

    paper!(c, c.p1, "P1 later")

    assert settle(view) =~ "P1 later"
  end
end
