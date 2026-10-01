defmodule BarkparkWeb.BacklinksContentRedactionTest do
  @moduledoc """
  `GET /v1/data/backlinks/:dataset/:id`: a backlink row's `description` /
  `event_type` (lifted from the referencing document's `content`) obey field
  visibility like every other read.

  `Graph.reverse_referencers/2` copies both straight out of `content`, and the
  route emitted them raw, so a read token received a `private` `description`
  that `/query` and `/doc` redact. Found in the task-3c68de39a19285c4 authz
  sweep (graph.ex ~1370).
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content}

  @ds "backlinks-redaction"

  setup do
    Auth.create_token("bl-read", "read", @ds, ["read"])
    Auth.create_token("bl-admin", "admin", @ds, ["read", "write", "admin"])

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
            %{"name" => "description", "type" => "string", "private" => true}
          ]
        },
        @ds
      )

    # `note` declares nothing: its description is public.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "note",
          "title" => "Note",
          "visibility" => "public",
          "fields" => [%{"name" => "author", "type" => "reference", "refType" => "person"}]
        },
        @ds
      )

    publish!("person", "ada", %{})
    publish!("article", "a1", %{"author" => "ada", "description" => "embargoed plot"})
    publish!("note", "n1", %{"author" => "ada", "description" => "open remark"})

    {:ok, _} = Content.add_edge("a1", "ada", "author", dataset: @ds, plugin_source: nil)
    {:ok, _} = Content.add_edge("n1", "ada", "author", dataset: @ds, plugin_source: nil)
    :ok
  end

  defp publish!(type, id, attrs) do
    {:ok, _} =
      Content.create_document(type, Map.merge(%{"_id" => id, "title" => id}, attrs), @ds)

    {:ok, _} = Content.publish_document(id, type, @ds)
  end

  defp descriptions(token) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/v1/data/backlinks/#{@ds}/ada")
    |> json_response(200)
    |> get_in(["result", "backlinks"])
    |> Map.new(&{&1["from_doc_id"], &1["description"]})
  end

  test "a read token never receives a private description; a public one stays" do
    d = descriptions("bl-read")

    assert Map.has_key?(d, "a1"), "the referencing row itself must still be listed"
    assert d["a1"] == nil
    assert d["n1"] == "open remark"
  end

  test "CONTROL: an admin token still receives every description" do
    d = descriptions("bl-admin")
    assert d["a1"] == "embargoed plot"
    assert d["n1"] == "open remark"
  end
end
