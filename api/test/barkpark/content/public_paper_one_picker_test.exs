defmodule Barkpark.Content.PublicPaperOnePickerTest do
  @moduledoc """
  task-0db9c861491a2ab2: the public paper surfaces had three pickers.

    * `PaperRevisionHeaders` picked the flat `/papers/<slug>` validator with
      its own query: the Default workspace, any owner. The reader
      (`Content.get_public_paper/2`) reads unowned rows only. So the revision
      header and the ETag could describe another row than the body, or a row
      the reader 404s on. The plug's query now carries the reader's predicates
      (an extra resolve would cost the reader's statement budget a statement).
    * `BoundFieldGuard` kept the NEWEST of two rows under one doc_id (two
      types), while the value resolve renders the OLDEST. It now keeps the
      oldest too.

  Owned and shared-layer rows are made by moving a fixture row's columns.
  Shared-layer rows never disagreed (both pickers read the Default workspace
  only), so that case is a control. `create_document/3` writes drafts, so the
  guard case binds two `drafts.q3` rows.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.{BoundFieldGuard, Document, SchemaDefinition}
  alias Barkpark.Repo

  @rev "x-barkpark-paper-revision"

  describe "the /papers/<slug> validator describes the row the reader renders" do
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
      %{ws: ws, p1: p1, p2: p2, ds: ds, slug: "ppop-#{System.unique_integer([:positive])}"}
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

      # A fixture paper carries no released revision; name its current one so
      # the revision header tells the two rows apart.
      doc = Repo.reload!(doc)
      assert is_binary(doc.current_revision_id)
      move!(doc, released_revision_id: doc.current_revision_id)
      %{doc | released_revision_id: doc.current_revision_id}
    end

    defp move!(doc, set) do
      {1, _} = Repo.update_all(from(d in Document, where: d.id == ^doc.id), set: set)
    end

    test "control: a lone shared-layer row is served by neither, and mints no validator",
         %{conn: conn} = c do
      # Both pickers read the Default workspace only (`scope_to_workspace_or_global/3`
      # with a workspace id is the workspace-only scope), so this case agreed on
      # main too.
      shared = paper!(c, c.p1, "Shared words")
      move!(shared, workspace_id: nil, project_id: nil)

      {404, headers, _body} = assert_error_sent(404, fn -> get(conn, "/papers/#{c.slug}") end)
      refute List.keymember?(headers, @rev, 0)
    end

    test "an owned row the reader skips is not the row the revision names", %{conn: conn} = c do
      owned = paper!(c, c.p1, "Owned words")
      open = paper!(c, c.p2, "Open words")
      move!(owned, owner_id: Ecto.UUID.generate())

      conn = get(conn, "/papers/#{c.slug}")
      body = html_response(conn, 200)
      assert body =~ "Open words"
      refute body =~ "Owned words"
      assert get_resp_header(conn, @rev) == [open.released_revision_id]
    end

    test "a lone owned row mints no validator on the 404", %{conn: conn} = c do
      owned = paper!(c, c.p1, "Owned words")
      move!(owned, owner_id: Ecto.UUID.generate())

      {404, headers, _body} = assert_error_sent(404, fn -> get(conn, "/papers/#{c.slug}") end)
      refute List.keymember?(headers, @rev, 0)
      refute List.keymember?(headers, "etag", 0)
    end
  end

  describe "BoundFieldGuard judges the row the value resolve renders" do
    defp schema!(name, ds, fields) do
      {:ok, _} =
        %SchemaDefinition{}
        |> SchemaDefinition.changeset(%{
          "name" => name,
          "title" => name,
          "dataset" => ds,
          "visibility" => "public",
          "fields" => fields
        })
        |> Repo.insert()
    end

    test "of two types under one doc_id, the oldest type's private field is refused" do
      ds = "ppop_guard_#{System.unique_integer([:positive])}"
      schema!("memo", ds, [%{"name" => "budget", "type" => "string", "private" => true}])
      schema!("note", ds, [%{"name" => "budget", "type" => "string"}])

      {:ok, _} =
        Content.create_document("memo", %{"doc_id" => "q3", "content" => %{"budget" => "1M"}}, ds)

      {:ok, _} =
        Content.create_document("note", %{"doc_id" => "q3", "content" => %{"budget" => "2M"}}, ds)

      assert [%{type: "memo"}, %{type: "note"}] =
               Content.resolve_docs_by_ids(["drafts.q3"], ds, [])

      block = %{
        "id" => "v-budget",
        "type" => "paragraph",
        "content" => [
          %{"type" => "valueref", "target" => "q3", "field" => "budget", "fallback" => "1M"}
        ]
      }

      assert {:error, {:private_field_bound, ["q3.budget"]}} =
               BoundFieldGuard.check([block], "paper", ds, nil)
    end
  end
end
