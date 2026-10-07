defmodule BarkparkWeb.Contract.BacklinksLiveTest do
  use BarkparkWeb.ConnCase, async: true
  import Ecto.Query
  alias Barkpark.{Auth, Content, Repo, TenancyFixtures}
  alias Barkpark.Content.{CallerContext, Graph}

  @ds "backlinks-live"

  setup do
    Auth.create_token("backlinks-live-token", "read", @ds, ["read"])

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "person", "title" => "Person", "visibility" => "public", "fields" => []},
        @ds
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "article",
          "title" => "Article",
          "visibility" => "public",
          "fields" => [
            %{"name" => "author", "type" => "reference", "refType" => "person"},
            %{"name" => "reviewer", "type" => "reference", "refType" => "person"},
            %{
              "name" => "people",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "person"}
            },
            %{"name" => "details", "type" => "object"},
            %{"name" => "secret", "type" => "reference", "private" => true},
            %{"name" => "description", "type" => "string", "private" => true}
          ]
        },
        @ds
      )

    {:ok, target} =
      Content.create_document("person", %{"_id" => "target", "title" => "Target"}, @ds)

    %{target: target}
  end

  defp draft!(id, fields) do
    {:ok, doc} =
      Content.create_document("article", Map.merge(%{"_id" => id, "title" => id}, fields), @ds)

    doc
  end

  defp backlinks(id, token \\ "backlinks-live-token") do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/v1/data/backlinks/#{@ds}/#{id}")
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "draft-only source and target work before projection, once per logical source" do
    draft!("source", %{
      "author" => "target",
      "reviewer" => "target",
      "description" => "secret text"
    })

    for id <- ["target", "drafts.target"] do
      assert %{"count" => 1, "backlinks" => [row]} = backlinks(id)
      assert row["from_doc_id"] == "source"
      assert row["description"] == nil
    end

    # The public graph remains projection-based; this change belongs to used-in.
    assert Graph.reverse_referencers("target", dataset: @ds) == []
  end

  test "bare arrays and reference objects are found; arbitrary strings are not" do
    draft!("array", %{"people" => ["target", "target"]})
    draft!("object", %{"reviewer" => %{"_ref" => "target", "_weak" => true}})
    draft!("text", %{"description" => "target"})
    draft!("private", %{"secret" => "target"})
    assert %{"count" => 2, "backlinks" => rows} = backlinks("target")
    assert Enum.sort(Enum.map(rows, & &1["from_doc_id"])) == ["array", "object"]

    # An older projection must not reintroduce a field the live read hides.
    {:ok, _} = Content.publish_document("private", "article", @ds)
    {:ok, _} = Content.add_edge("private", "target", "secret", dataset: @ds)
    assert %{"count" => 2, "backlinks" => rows} = backlinks("target")
    assert Enum.sort(Enum.map(rows, & &1["from_doc_id"])) == ["array", "object"]

    Auth.create_token("backlinks-admin", "admin", @ds, ["read", "admin"])
    assert %{"count" => 3, "backlinks" => admin_rows} = backlinks("target", "backlinks-admin")
    assert Enum.any?(admin_rows, &(&1["from_doc_id"] == "private"))
  end

  test "draft and published twins plus two projected edges produce one card" do
    draft!("source", %{"author" => "target", "reviewer" => "target"})
    {:ok, _} = Content.publish_document("source", "article", @ds)

    {:ok, _} =
      Content.create_document(
        "article",
        %{"_id" => "source", "title" => "Draft title", "author" => "target"},
        @ds
      )

    {:ok, _} = Content.add_edge("source", "target", "author", dataset: @ds)
    {:ok, _} = Content.add_edge("source", "target", "reviewer", dataset: @ds)
    assert %{"count" => 1, "backlinks" => [row]} = backlinks("target")
    assert row["title"] == "Draft title"
  end

  test "projected plugin links without a schema field remain visible" do
    draft!("plugin-source", %{})

    {:ok, _} =
      Content.add_edge("plugin-source", "target", "plugin-link",
        dataset: @ds,
        plugin_source: "example"
      )

    assert %{"count" => 1, "backlinks" => [row]} = backlinks("target")
    assert row["from_doc_id"] == "plugin-source"
    assert row["plugin_source"] == "example"
  end

  test "live holders obey tenant, owner and grant scope", %{target: target} do
    source = draft!("source", %{"author" => "target"})
    other = TenancyFixtures.create_workspace!()
    project = TenancyFixtures.create_project!(other)

    {:ok, _} =
      Content.create_document(
        "article",
        %{"_id" => "foreign", "title" => "Foreign", "author" => "target"},
        @ds,
        workspace_id: other.id,
        project_id: project.id
      )

    opts = [dataset: @ds, workspace_id: target.workspace_id, project_id: target.project_id]
    assert [%{from_doc_id: "source"}] = Graph.backlinks("target", opts)
    assert Graph.backlinks("target", Keyword.put(opts, :grant_scoped, true)) == []
    # A source owned by another editor must never become a backlink stub.
    Repo.update_all(from(d in Content.Document, where: d.id == ^source.id),
      set: [owner_id: Ecto.UUID.generate()]
    )

    # Graph's keyed hydration is unconditional, including malformed ownership
    # on an otherwise plain schema. The live read must retain that protection.
    assert Graph.backlinks(
             "target",
             Keyword.put(opts, :caller_context, CallerContext.anonymous())
           ) == []
  end
end
