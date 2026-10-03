defmodule BarkparkWeb.Integration.V1MediaCollectionsAnonRedactionTest do
  @moduledoc """
  Owner ruling #22 (2026-10-03, task-76ddf1b3b0587fe6): media collections
  clamp and redact.

    * An anonymous caller follows the public-read rule: with the shipped
      `mediaCollection` schema (`visibility: "private"`) it lists no
      collection and a collection read 404s. Before the ruling the flat index
      listed every collection to a tokenless caller.
    * The collection's own fields go through `Envelope.redact/4`: a field the
      schema declares private is absent for a caller who may not read it, on
      the index, the show route and a share view. Before, `Collections.render`
      copied `description` / `virtualFilter` straight out of content.
    * The legitimate paths keep working: a read token and an admin still list
      and read collections, and an install that declares the type public gets
      open folders back for anonymous callers.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Media.Storage.Share
  alias Barkpark.Repo

  @ds "production"

  setup do
    Auth.create_token("col-redact-admin", "admin", "col-redact", ["read", "write", "admin"])
    Auth.create_token("col-redact-read", "read", "col-redact", ["read"])

    id = "col-redact-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_document(
        "mediaCollection",
        %{
          "doc_id" => id,
          "title" => "Redaction probe #{id}",
          "content" => %{
            "kind" => "folder",
            "slug" => id,
            "description" => "internal launch notes"
          }
        },
        @ds,
        source: :api
      )

    {:ok, _} = Content.publish_document(id, "mediaCollection", @ds)
    on_exit(fn -> Content.delete_document(id, "mediaCollection", @ds) end)

    %{id: id}
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp listed(conn, id) do
    conn
    |> get("/v1/media/#{@ds}/collections?limit=1000")
    |> json_response(200)
    |> get_in(["result", "collections"])
    |> Enum.find(&(&1["id"] == id))
  end

  # Make the collection type public (open folders), and optionally declare
  # `description` private, on every mediaCollection schema row.
  defp set_schema!(opts) do
    rows = Repo.all(from(s in SchemaDefinition, where: s.name == "mediaCollection"))
    assert rows != []

    for row <- rows do
      fields =
        Enum.map(row.fields, fn f ->
          if f["name"] == "description" and opts[:private_description],
            do: Map.put(f, "private", true),
            else: f
        end)

      row |> Ecto.Changeset.change(visibility: "public", fields: fields) |> Repo.update!()
    end
  end

  test "anonymous: the shipped private collection type lists nothing and reads 404", %{
    conn: conn,
    id: id
  } do
    assert listed(conn, id) == nil

    conn
    |> get("/v1/media/#{@ds}/collections/#{id}")
    |> json_response(404)
  end

  test "a read token and an admin still list and read the collection", %{conn: conn, id: id} do
    for token <- ["col-redact-read", "col-redact-admin"] do
      row = conn |> bearer(token) |> listed(id)
      assert row["title"] =~ "Redaction probe"

      show =
        conn
        |> bearer(token)
        |> get("/v1/media/#{@ds}/collections/#{id}")
        |> json_response(200)

      assert show["result"]["id"] == id
    end
  end

  test "a public collection type gives anonymous callers open folders again", %{
    conn: conn,
    id: id
  } do
    set_schema!([])
    row = listed(conn, id)
    assert row["description"] == "internal launch notes"
  end

  test "a private field is redacted for anonymous and read tokens, kept for admin", %{
    conn: conn,
    id: id
  } do
    set_schema!(private_description: true)

    anon_row = listed(conn, id)
    assert anon_row["title"] =~ "Redaction probe"
    assert anon_row["description"] == nil

    anon_show =
      conn |> get("/v1/media/#{@ds}/collections/#{id}") |> json_response(200)

    assert anon_show["result"]["description"] == nil

    read_row = conn |> bearer("col-redact-read") |> listed(id)
    assert read_row["description"] == nil

    admin_row = conn |> bearer("col-redact-admin") |> listed(id)
    assert admin_row["description"] == "internal launch notes"
  end

  test "a share view renders the collection for the anonymous reader", %{conn: conn, id: id} do
    set_schema!(private_description: true)
    {:ok, share} = Share.create(id, @ds, [])

    result =
      conn
      |> get(Share.share_path(@ds, share.token))
      |> json_response(200)
      |> Map.fetch!("result")

    assert result["collection"]["id"] == id
    assert result["collection"]["description"] == nil
  end
end
