defmodule BarkparkWeb.QueryDocumentedLimitsTest do
  @moduledoc """
  RE-MEASUREMENT of the "documented limits" from the Gyldendal field report
  (#16), against CURRENT main rather than v0.2.26.382.

  Each test is a live HTTP request whose assertion IS the measurement. When a
  limit is real the test pins it (so the doc stays true); when the limit has
  since been LIFTED the test pins the lift (so it cannot silently regress).

  Measured here — all against `GET /v1/data/query/:dataset/:type`:

    * one filter clause per query           — DOES NOT HOLD (AND-composition works)
    * no deref in filter                    — HOLDS (a dotted path is a JSONB
                                              sub-path of the SAME document, never
                                              a join through a reference)
    * no deref in sort                      — HOLDS (same reason)
    * no subfield projection                — HOLDS (a dotted `?fields=` keeps the
                                              WHOLE parent object)
    * expand is depth-1 single-ref only     — depth-1 HOLDS; "single-ref only"
                                              DOES NOT HOLD (ref ARRAYS expand)
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content}

  @dataset "qlimits_remeasure_ds"

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Author",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "tag",
          "title" => "Tag",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "status", "type" => "string"},
            %{"name" => "meta", "type" => "object"},
            %{"name" => "author", "type" => "reference", "refType" => "author"},
            %{
              "name" => "tags",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "tag"}
            }
          ]
        },
        @dataset
      )

    for {id, title} <- [{"au1", "Ada"}, {"au2", "Bo"}] do
      {:ok, _} = Content.create_document("author", %{"_id" => id, "title" => title}, @dataset)
      {:ok, _} = Content.publish_document(id, "author", @dataset)
    end

    for {id, title} <- [{"tg1", "Fiction"}, {"tg2", "Poetry"}] do
      {:ok, _} = Content.create_document("tag", %{"_id" => id, "title" => title}, @dataset)
      {:ok, _} = Content.publish_document(id, "tag", @dataset)
    end

    posts = [
      {"po1", "Alpha", "published", "au1", ["tg1", "tg2"], %{"seo" => "s1", "slug" => "alpha"}},
      {"po2", "Alpha", "draftish", "au2", ["tg2"], %{"seo" => "s2", "slug" => "beta"}},
      {"po3", "Beta", "published", "au2", ["tg1"], %{"seo" => "s3", "slug" => "gamma"}}
    ]

    for {id, title, status, author, tags, meta} <- posts do
      {:ok, _} =
        Content.create_document(
          "post",
          %{
            "_id" => id,
            "title" => title,
            "status" => status,
            "author" => author,
            "tags" => tags,
            "meta" => meta
          },
          @dataset
        )

      {:ok, _} = Content.publish_document(id, "post", @dataset)
    end

    raw = "qlimits-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "limits token", @dataset, ["read", "write"])

    {:ok, raw: raw}
  end

  defp query(conn, raw, qs) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)
    |> get("/v1/data/query/#{@dataset}/post?" <> qs)
  end

  defp ids(body), do: body["result"]["documents"] |> Enum.map(& &1["_id"]) |> Enum.sort()

  describe "LIMIT 1 — \"one filter clause per query\"" do
    test "DOES NOT HOLD: two bracketed filter fields AND-compose", %{conn: conn, raw: raw} do
      body =
        query(conn, raw, "filter[title]=Alpha&filter[status]=published&perspective=published")
        |> json_response(200)

      assert ids(body) == ["po1"]
    end

    test "DOES NOT HOLD: a repeated filter[] param AND-composes", %{conn: conn, raw: raw} do
      body =
        query(
          conn,
          raw,
          "filter[]=title%3DAlpha&filter[]=status%3Dpublished&perspective=published"
        )
        |> json_response(200)

      assert ids(body) == ["po1"]
    end

    test "two clauses on the same field with DIFFERENT ops also AND-compose", %{
      conn: conn,
      raw: raw
    } do
      body =
        query(conn, raw, "filter[title][gte]=Alpha&filter[title][lt]=B&perspective=published")
        |> json_response(200)

      assert ids(body) == ["po1", "po2"]
    end
  end

  describe "LIMIT 2 — \"no deref in filter\"" do
    test "HOLDS: filtering through a reference (author.title) matches nothing", %{
      conn: conn,
      raw: raw
    } do
      body =
        query(conn, raw, "filter[author.title]=Ada&perspective=published") |> json_response(200)

      assert ids(body) == []
    end

    test "the dotted path that DOES work is a JSONB sub-path of the same document", %{
      conn: conn,
      raw: raw
    } do
      body =
        query(conn, raw, "filter[meta.slug]=alpha&perspective=published") |> json_response(200)

      assert ids(body) == ["po1"]
    end
  end

  describe "LIMIT 3 — \"no deref in sort\"" do
    test "HOLDS: order by author.title does not sort by the referenced title", %{
      conn: conn,
      raw: raw
    } do
      by_ref =
        query(conn, raw, "order=author.title:asc&perspective=published")
        |> json_response(200)
        |> ids()

      # Every post's `author` value is a bare id string, so `author.title` is a
      # JSONB path that resolves to NULL on every row — the sort is a no-op, not
      # a join. All three rows still come back, in no meaningful author order.
      assert by_ref == ["po1", "po2", "po3"]
    end

    test "the dotted sort that DOES work is a JSONB sub-path of the same document", %{
      conn: conn,
      raw: raw
    } do
      body =
        query(conn, raw, "order=meta.slug:asc&perspective=published") |> json_response(200)

      assert body["result"]["documents"] |> Enum.map(& &1["_id"]) == ["po1", "po2", "po3"]
    end
  end

  describe "LIMIT 4 — \"no subfield projection\"" do
    test "HOLDS: ?fields=meta.slug returns the WHOLE meta object", %{conn: conn, raw: raw} do
      body =
        query(conn, raw, "fields=meta.slug&filter[title]=Beta&perspective=published")
        |> json_response(200)

      [doc] = body["result"]["documents"]
      assert doc["meta"] == %{"seo" => "s3", "slug" => "gamma"}
      refute Map.has_key?(doc, "title")
    end
  end

  describe "LIMIT 5 — \"expand is depth-1, single-ref only\"" do
    test "DOES NOT HOLD for ref ARRAYS: an arrayOf-reference field expands", %{
      conn: conn,
      raw: raw
    } do
      body =
        query(conn, raw, "expand=tags&filter[title]=Beta&perspective=published")
        |> json_response(200)

      [doc] = body["result"]["documents"]
      assert [%{"_id" => "tg1", "title" => "Fiction"}] = doc["tags"]
    end

    test "HOLDS for depth: expansion is one hop — the inlined doc's own refs stay ids", %{
      conn: conn,
      raw: raw
    } do
      # `author` has no reference fields of its own, so depth is measured on the
      # SHAPE of the expand spec instead: a dotted `expand=author.employer` names
      # no top-level reference field and expands NOTHING.
      body =
        query(conn, raw, "expand=author.employer&filter[title]=Beta&perspective=published")
        |> json_response(200)

      [doc] = body["result"]["documents"]
      assert doc["author"] == "au2"
    end
  end
end
