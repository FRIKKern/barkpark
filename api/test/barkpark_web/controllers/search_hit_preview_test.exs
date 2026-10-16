defmodule BarkparkWeb.SearchHitPreviewTest do
  @moduledoc """
  task-75cb2cac1e875214: `?preview=1` puts each hit's `list_preview` subtitle,
  description and media on it as `_preview`, so the reference picker tells
  three editions named "Eventyrnettene" apart. A referenced document's field
  the caller may not read stays out, and an anonymous caller gets no preview.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy

  @ds "search-hit-preview-test"

  setup do
    ws = Tenancy.get_default_workspace()
    raw = "hit-preview-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "hit-preview", @ds, ["read"], ws.id)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "contributor",
          "title" => "Bidragsyter",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Navn", "type" => "string"},
            %{
              "name" => "secret",
              "title" => "Hemmelig",
              "type" => "string",
              "visibility" => "private"
            }
          ]
        },
        @ds
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "product",
          "title" => "Produkt",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Tittel", "type" => "string"},
            %{"name" => "isbn", "title" => "ISBN", "type" => "string"},
            %{"name" => "format", "title" => "Format", "type" => "string"},
            %{"name" => "cover", "title" => "Omslag", "type" => "url"},
            %{
              "name" => "contributors",
              "title" => "Bidragsytere",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "contributor"}
            }
          ],
          "list_preview" => %{
            "subtitle" => %{"parts" => ["isbn", "format"]},
            "description" => %{"each" => "contributors", "show" => ["{title} {secret}", "title"]},
            "media" => "cover"
          }
        },
        @ds
      )

    {:ok, _} =
      Content.create_document(
        "contributor",
        %{"doc_id" => "c1", "title" => "Kari Nord", "content" => %{"secret" => "X"}},
        @ds
      )

    {:ok, _} = Content.publish_document("c1", "contributor", @ds)

    for {id, isbn, format} <- [{"p1", "9788205627765", "Bok"}, {"p2", "9788205627772", "E-bok"}] do
      {:ok, _} =
        Content.create_document(
          "product",
          %{
            "doc_id" => id,
            "title" => "Eventyrnettene",
            "content" => %{
              "isbn" => isbn,
              "format" => format,
              "cover" => "https://media.example/#{id}.jpg",
              "contributors" => [%{"_ref" => "c1", "_type" => "reference"}]
            }
          },
          @ds
        )

      {:ok, _} = Content.publish_document(id, "product", @ds)
    end

    {:ok, token: raw}
  end

  defp search(conn, params),
    do:
      get(
        conn,
        "/v1/data/search/#{@ds}",
        Keyword.merge([q: "Eventyrnettene", type: "product"], params)
      )

  test "each hit carries its list preview", %{conn: conn, token: token} do
    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> search(preview: "1")
      |> json_response(200)

    previews = Map.new(body["documents"], &{&1["_id"], &1["_preview"]})

    assert previews["p1"]["subtitle"] == "9788205627765 · Bok"
    assert previews["p2"]["subtitle"] == "9788205627772 · E-bok"
    assert previews["p1"]["media"] == "https://media.example/p1.jpg"

    # `{title} {secret}` needs the target's private field, which a read token
    # may not see, so the template has an empty slot and the next part shows.
    assert previews["p1"]["description"] == "Kari Nord"
  end

  test "without preview=1 a hit has no _preview", %{conn: conn, token: token} do
    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> search([])
      |> json_response(200)

    assert body["documents"] != []
    refute Enum.any?(body["documents"], &Map.has_key?(&1, "_preview"))
  end

  test "an anonymous caller gets no preview", %{conn: conn} do
    body = conn |> search(preview: "1") |> json_response(200)
    assert body["documents"] != []
    refute Enum.any?(body["documents"], &Map.has_key?(&1, "_preview"))
  end
end
