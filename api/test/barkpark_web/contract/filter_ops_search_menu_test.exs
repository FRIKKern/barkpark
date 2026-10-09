defmodule BarkparkWeb.Contract.FilterOpsSearchMenuTest do
  @moduledoc """
  The Sanity search-filter operators `/v1/data/query` could not express
  (task-aaf4d51bf8a51aec): a string "does not contain", an array "does not
  include", array length comparisons, and "references document".

    * `notContains` — case-insensitive; a document without the field counts as
      not containing it (Sanity's `!(field match …)`).
    * `nhas` — the array lacks the value (`_ref` or scalar); no array, no value.
    * `countEq countNeq countGt countGte countLt countLte` — array length; no
      array counts 0. The value must be an integer: anything else is a 400.
    * `filter[_references]=<id>` — the document references `id` anywhere in its
      content (`references(id)`).
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content

  @ds "test"

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    for {id, content} <- [
          {"m1",
           %{
             "excerpt" => "Short Excerpt",
             "tags" => [%{"_ref" => "tag-a"}, %{"_ref" => "tag-b"}],
             "seo" => %{"image" => %{"asset" => %{"_ref" => "image-1"}}}
           }},
          {"m2", %{"excerpt" => "Long read", "tags" => [%{"_ref" => "tag-c"}]}},
          {"m3", %{"tags" => []}}
        ] do
      {:ok, _} =
        Content.create_document("post", Map.merge(%{"_id" => id, "title" => "M"}, content), @ds)

      {:ok, _} = Content.publish_document(id, "post", @ds)
    end

    :ok
  end

  defp ids(conn, query) do
    %{"result" => body} =
      conn |> get("/v1/data/query/#{@ds}/post?filter[title]=M&" <> query) |> json_response(200)

    body["documents"] |> Enum.map(& &1["_id"]) |> Enum.sort()
  end

  test "notContains: case-insensitive, and a missing field does not contain", %{conn: conn} do
    assert ids(conn, "filter[excerpt][notContains]=excerpt") == ["m2", "m3"]
  end

  test "nhas: the array lacks the reference", %{conn: conn} do
    assert ids(conn, "filter[tags][nhas]=tag-a") == ["m2", "m3"]
  end

  test "array length comparisons", %{conn: conn} do
    assert ids(conn, "filter[tags][countEq]=2") == ["m1"]
    assert ids(conn, "filter[tags][countNeq]=1") == ["m1", "m3"]
    assert ids(conn, "filter[tags][countGt]=0") == ["m1", "m2"]
    assert ids(conn, "filter[tags][countGte]=1") == ["m1", "m2"]
    assert ids(conn, "filter[tags][countLt]=1") == ["m3"]
    assert ids(conn, "filter[tags][countLte]=1") == ["m2", "m3"]
  end

  test "a count op with a non-integer value is a 400", %{conn: conn} do
    resp = get(conn, "/v1/data/query/#{@ds}/post?filter[tags][countGt]=two")
    assert resp.status == 400
  end

  test "_references: the document references the id anywhere", %{conn: conn} do
    assert ids(conn, "filter[_references]=image-1") == ["m1"]
    assert ids(conn, "filter[_references]=tag-c") == ["m2"]
    assert ids(conn, "filter[_references]=nothing") == []
  end

  describe "_references matches a BARE STRING in a schema-declared reference field (task-cecd2cb193365b71)" do
    setup do
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Author",
          "visibility" => "public",
          "fields" => [%{"name" => "name", "type" => "string"}]
        },
        @ds
      )

      Content.upsert_schema(
        %{
          "name" => "refpost",
          "title" => "RefPost",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "author", "type" => "reference", "refType" => "author"},
            %{
              "name" => "coauthors",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "author"}
            },
            # An ORDINARY string field — must never match the probed id, even
            # though it is not declared as a reference. This is the negative
            # the schema-scoping exists for.
            %{"name" => "slug", "type" => "string"}
          ]
        },
        @ds
      )

      for {id, content} <- [
            # Scalar `author`, stored as a BARE STRING — the live report's
            # exact shape (`filter[_references]=author-alan` missed this).
            {"rp1", %{"title" => "R", "author" => "author-alan", "slug" => "r1"}},
            # Scalar `author`, stored as the structural {"_ref": id} object —
            # must keep matching, unchanged.
            {"rp2", %{"title" => "R", "author" => %{"_ref" => "author-bea"}, "slug" => "r2"}},
            # `coauthors` arrayOf-reference, a BARE STRING element.
            {"rp3", %{"title" => "R", "coauthors" => ["author-cal"], "slug" => "r3"}},
            # `coauthors` arrayOf-reference, the {"_ref": id} element shape.
            {"rp4",
             %{"title" => "R", "coauthors" => [%{"_ref" => "author-dee"}], "slug" => "r4"}},
            # NEGATIVE: an ordinary (non-reference) string field happens to
            # hold the SAME string as a probed id below — must never match.
            {"rp5", %{"title" => "R", "slug" => "author-alan"}}
          ] do
        {:ok, _} =
          Content.create_document("refpost", Map.merge(%{"_id" => id}, content), @ds)

        {:ok, _} = Content.publish_document(id, "refpost", @ds)
      end

      :ok
    end

    defp refpost_ids(conn, query) do
      %{"result" => body} =
        conn
        |> get("/v1/data/query/#{@ds}/refpost?filter[title]=R&" <> query)
        |> json_response(200)

      body["documents"] |> Enum.map(& &1["_id"]) |> Enum.sort()
    end

    test "a scalar reference field stored as a bare string matches", %{conn: conn} do
      assert refpost_ids(conn, "filter[_references]=author-alan") == ["rp1"]
    end

    test "a scalar reference field stored as {_ref} still matches, unchanged", %{conn: conn} do
      assert refpost_ids(conn, "filter[_references]=author-bea") == ["rp2"]
    end

    test "an arrayOf-reference element stored as a bare string matches", %{conn: conn} do
      assert refpost_ids(conn, "filter[_references]=author-cal") == ["rp3"]
    end

    test "an arrayOf-reference element stored as {_ref} still matches, unchanged", %{
      conn: conn
    } do
      assert refpost_ids(conn, "filter[_references]=author-dee") == ["rp4"]
    end

    test "an ordinary non-reference string field holding the SAME value never matches", %{
      conn: conn
    } do
      refute "rp5" in refpost_ids(conn, "filter[_references]=author-alan")
    end
  end

  describe "nbetween: exclusion-range filter (task-cecd2cb193365b71)" do
    setup do
      for {id, days_ago} <- [{"d1", 10}, {"d2", 5}, {"d3", 0}] do
        full_id = "nb-" <> id
        {:ok, _draft} = Content.create_document("post", %{"_id" => full_id, "title" => "NB"}, @ds)
        {:ok, published} = Content.publish_document(full_id, "post", @ds)

        # `inserted_at` is stamped fresh by `publish_document/4`'s own write,
        # not copied from the draft — override the PUBLISHED row (the one
        # `ids/2` below actually reads) directly.
        ts = DateTime.add(DateTime.utc_now(), -days_ago * 86400, :second)

        Barkpark.Repo.update_all(
          from(d in Barkpark.Content.Document, where: d.id == ^published.id),
          set: [inserted_at: ts]
        )
      end

      :ok
    end

    defp nb_ids(conn, query) do
      %{"result" => body} =
        conn
        |> get("/v1/data/query/#{@ds}/post?filter[title]=NB&" <> query)
        |> json_response(200)

      body["documents"] |> Enum.map(& &1["_id"]) |> Enum.sort()
    end

    test "excludes rows whose _createdAt falls inside the range, both bounds inclusive", %{
      conn: conn
    } do
      now = DateTime.utc_now()
      six_days_ago = DateTime.add(now, -6 * 86400, :second) |> DateTime.to_iso8601()
      four_days_ago = DateTime.add(now, -4 * 86400, :second) |> DateTime.to_iso8601()

      kept =
        nb_ids(
          conn,
          "filter[_createdAt][nbetween]=#{six_days_ago},#{four_days_ago}"
        )

      # d2 (5 days ago) falls inside [6 days ago, 4 days ago] and must be
      # EXCLUDED; d1 (10 days ago) and d3 (today) fall outside and survive.
      assert "nb-d2" not in kept
      assert "nb-d1" in kept
      assert "nb-d3" in kept
    end

    test "a value that isn't a 2-element list is refused 400", %{conn: conn} do
      resp = get(conn, "/v1/data/query/#{@ds}/post?filter[_createdAt][nbetween]=2026-01-01")
      assert resp.status == 400
    end
  end
end
