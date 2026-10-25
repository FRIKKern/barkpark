defmodule BarkparkWeb.QueryFieldsReadInSqlTest do
  @moduledoc """
  `GET /v1/data/query/:dataset/:type?fields=…` reads only the top-level
  content keys it keeps.

  A page of 200 products on the gyldendal-no catalogue cost about 1 ms a row
  to read and render, whatever `?fields=` kept, because every row's whole
  `content` (about 6 kB) was sent, decoded and rendered before the
  projection. The kept keys come out as they did.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.Query

  @type_name "fieldsreadbook"

  setup do
    dataset = "fields_read_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Fields read book",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "state", "type" => "string"},
            %{"name" => "secret", "type" => "string", "private" => true},
            %{
              "name" => "meta",
              "type" => "object",
              "fields" => [
                %{"name" => "slug", "type" => "string"},
                %{"name" => "note", "type" => "string", "private" => true}
              ]
            },
            %{"name" => "body", "type" => "string"}
          ]
        },
        dataset
      )

    for {id, state} <- [{"b1", "live"}, {"b2", "held"}] do
      {:ok, _} =
        Content.create_document(
          @type_name,
          %{
            "_id" => id,
            "title" => "Book #{id}",
            "state" => state,
            "secret" => "s-#{id}",
            "meta" => %{"slug" => id, "note" => "n-#{id}"},
            "body" => String.duplicate("text ", 200)
          },
          dataset
        )

      {:ok, _} = Content.publish_document(id, @type_name, dataset)
    end

    raw = "fieldsread-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "fields read token", dataset, ["read"])

    {:ok, dataset: dataset, raw: raw}
  end

  defp docs(conn, ctx, qs) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> ctx.raw)
    |> get("/v1/data/query/#{ctx.dataset}/#{@type_name}?" <> qs)
    |> json_response(200)
    |> get_in(["result", "documents"])
    |> Enum.sort_by(& &1["_id"])
  end

  defp kept(docs, keys) do
    Enum.map(docs, fn doc ->
      Map.filter(doc, fn {k, _} -> String.starts_with?(k, "_") or k in keys end)
    end)
  end

  test "the kept keys come out as they do from the whole document", %{conn: conn} = ctx do
    for perspective <- ["published", "drafts", "raw"] do
      whole = docs(conn, ctx, "perspective=#{perspective}")

      assert docs(conn, ctx, "perspective=#{perspective}&fields=state,meta.slug") ==
               kept(whole, ["state", "meta"])

      assert docs(conn, ctx, "perspective=#{perspective}&fields=title,nope") ==
               kept(whole, ["title"])

      assert docs(conn, ctx, "perspective=#{perspective}&fields=_id") == kept(whole, [])
    end
  end

  test "a field this caller may not read stays out, at any depth", %{conn: conn} = ctx do
    [doc | _] = docs(conn, ctx, "perspective=published&fields=secret,meta")

    refute Map.has_key?(doc, "secret")
    assert doc["meta"] == %{"slug" => "b1"}
  end

  test "the read holds only the named keys", ctx do
    keys = fn opts ->
      @type_name
      |> Query.list_documents(ctx.dataset, opts)
      |> Enum.map(&(&1.content |> Map.keys() |> Enum.sort()))
      |> Enum.uniq()
    end

    assert keys.(perspective: :published, content_keys: ["state", "meta", "nope"]) == [
             ["meta", "state"]
           ]

    assert keys.(perspective: :drafts, content_keys: ["state"]) == [["state"]]
    assert [all] = keys.(perspective: :published)
    assert "body" in all
  end
end
