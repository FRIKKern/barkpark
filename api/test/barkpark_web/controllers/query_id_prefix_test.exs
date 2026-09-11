defmodule BarkparkWeb.QueryIdPrefixTest do
  @moduledoc """
  `?id_prefix=` on the document-LIST doors — the parameter that was read by
  nobody (`cloud-console-data-query-id-prefix-bug`).

  THE DEFECT. `GET /v1/data/query/production/task?id_prefix=cloud-console-c11`
  answered 200 with ~100 unrelated documents in default order. No door read the
  key, so the response was the UNFILTERED default page wearing the shape of a
  filtered one — a sweep could count it, diff it and declare a family complete
  while every row in the answer belonged to a different family.

  THE CONTRACT under test: `id_prefix` IS a filter — exactly
  `?filter[_id][startsWith]=<p>` against the `doc_id` column — and the shapes
  that would rebuild the silent full page (blank prefix, non-string prefix, a
  prefix that collides with a caller's own `_id`/`doc_id` clause) are a 400
  `invalid_filter` naming `id_prefix`, never a 200.

  BOTH ARMS, AND THE THIRD DOOR. The row names the flat and the
  workspace/project-scoped `/v1/data/query` routes; the CODE says both are the
  same `QueryController.index/2`, and that `LegacyController.index/2`
  (`GET /api/documents/:type`) is a SECOND list emitter with its own filter
  parse — and a worse blast radius, since it walks up to 10,000 rows. All three
  are proved here.

  NON-VACUITY IS THE POINT. `@noise` unrelated rows are seeded ALONGSIDE the
  `@family` target rows, and `@noise` is deliberately larger than the route's
  100-row default page, so an unfiltered fallback is a FULL page that cannot be
  mistaken for a filtered one. `"the corpus can produce a full unfiltered page"`
  asserts that directly: if the fixture ever shrinks below the page size, that
  test reds and every exclusion assertion below it stops being evidence.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Repo

  # The legacy door hardcodes `@dataset "production"`, so the whole fixture
  # lives there and all three doors read ONE corpus. The type name is unique to
  # this file, so committed migration-seeded rows of other types cannot leak in.
  @ds "production"
  @type_name "idprefixdoc"

  @prefix "cc-c11-"
  @family ~w(cc-c11-alpha cc-c11-beta cc-c11-gamma)
  # STRICTLY GREATER than the 100-row default page. An unfiltered answer is
  # therefore a full 100-row page with hasMore=true — visibly different from the
  # 3-row filtered answer, in a way a smaller fixture could not be.
  @noise 105

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Id Prefix Doc",
          "visibility" => "public",
          "fields" => []
        },
        @ds
      )

    seed!()

    raw = "id-prefix-token-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "id_prefix test", @ds, ["read", "write"])

    {:ok, raw_token: raw}
  end

  # One real create+publish carries whatever tenancy scope this install resolves
  # (workspace / project / dataset_id) — `Content.Scope.scope_to_workspace/3` is
  # STRICT, so rows seeded outside it are invisible to the request and every
  # assertion here would go vacuous. The rest are bulk copies of that scope.
  # (Same technique as `QueryControllerTruncationSignalTest.seed!/1`.)
  defp seed!() do
    [first | rest] = @family

    {:ok, _} = Content.create_document(@type_name, %{"_id" => first, "title" => first}, @ds)
    {:ok, _} = Content.publish_document(first, @type_name, @ds)

    seed = Repo.get_by!(Document, doc_id: first, type: @type_name)
    now = DateTime.utc_now()

    ids =
      rest ++
        for i <- 1..@noise//1 do
          "unrelated-#{String.pad_leading(Integer.to_string(i), 4, "0")}"
        end

    rows =
      for id <- ids do
        %{
          id: Ecto.UUID.generate(),
          doc_id: id,
          type: @type_name,
          dataset: seed.dataset,
          dataset_id: seed.dataset_id,
          workspace_id: seed.workspace_id,
          project_id: seed.project_id,
          title: id,
          status: "published",
          content: %{},
          rev: Ecto.UUID.generate(),
          inserted_at: now,
          updated_at: now
        }
      end

    {inserted, _} = Repo.insert_all(Document, rows)
    ^inserted = length(ids)

    corpus = length(@family) + @noise

    assert Repo.aggregate(from(d in Document, where: d.type == ^@type_name), :count) == corpus,
           "the fixture must hold #{corpus} rows — the exclusion assertions in this " <>
             "file are only evidence while the unrelated rows outnumber the page size"

    :ok
  end

  defp authed(conn, raw), do: put_req_header(conn, "authorization", "Bearer " <> raw)

  defp ids(body), do: body["result"]["documents"] |> Enum.map(& &1["_id"]) |> Enum.sort()

  # Read the BODY before naming a cause: a 429 from the suite's shared limiter
  # says `rate_limited` while the assertion below would blame the filter.
  defp resp!(conn, status) do
    refute_rate_limited!(conn)
    json_response(conn, status)
  end

  describe "the fixture itself" do
    test "the corpus can produce a full unfiltered page", %{conn: conn} do
      body = conn |> get("/v1/data/query/#{@ds}/#{@type_name}") |> resp!(200)

      assert body["result"]["count"] == 100,
             "an unfiltered read must fill the default page — otherwise 'the filtered " <>
               "answer is short' proves nothing about filtering"

      assert body["result"]["hasMore"] == true
      assert @noise > 100, "the noise corpus must exceed the default page size"
    end
  end

  describe "GET /v1/data/query/:dataset/:type?id_prefix= — the flat route" do
    test "returns ONLY the id family, never the default page", %{conn: conn} do
      # RED before the fix: 100 documents, `hasMore` true, none of them family.
      body =
        conn |> get("/v1/data/query/#{@ds}/#{@type_name}?id_prefix=#{@prefix}") |> resp!(200)

      assert ids(body) == Enum.sort(@family)
      assert body["result"]["count"] == 3
      assert body["result"]["hasMore"] == false

      refute Enum.any?(ids(body), &String.starts_with?(&1, "unrelated-")),
             "an unrelated row in the answer means the prefix was ignored"
    end

    test "a prefix that matches nothing is an EMPTY page, not the corpus", %{conn: conn} do
      body =
        conn |> get("/v1/data/query/#{@ds}/#{@type_name}?id_prefix=no-such-family-") |> resp!(200)

      assert body["result"]["documents"] == []
      assert body["result"]["count"] == 0
    end

    test "the prefix is literal — % and _ are not wildcards", %{conn: conn} do
      body = conn |> get("/v1/data/query/#{@ds}/#{@type_name}?id_prefix=%25") |> resp!(200)

      assert body["result"]["count"] == 0,
             "an unescaped LIKE wildcard would match the whole corpus"
    end

    test "a blank id_prefix is a 400 naming the parameter, not the full page", %{conn: conn} do
      body = conn |> get("/v1/data/query/#{@ds}/#{@type_name}?id_prefix=") |> resp!(400)

      assert body["error"]["code"] == "invalid_filter"
      assert body["error"]["message"] =~ "id_prefix"
      assert body["error"]["details"]["param"] == "id_prefix"
    end

    test "a non-string id_prefix is a 400, not a 500 and not the full page", %{conn: conn} do
      body = conn |> get("/v1/data/query/#{@ds}/#{@type_name}?id_prefix[]=a") |> resp!(400)

      assert body["error"]["code"] == "invalid_filter"
      assert body["error"]["message"] =~ "id_prefix"
    end

    test "id_prefix colliding with an explicit _id clause is refused, not clobbered", %{
      conn: conn
    } do
      body =
        conn
        |> get("/v1/data/query/#{@ds}/#{@type_name}?id_prefix=#{@prefix}&filter[_id][eq]=x")
        |> resp!(400)

      assert body["error"]["code"] == "invalid_filter"
      assert body["error"]["message"] =~ "id_prefix"
      assert body["error"]["details"]["field"] == "_id"
    end

    test "an absent id_prefix changes nothing", %{conn: conn} do
      body = conn |> get("/v1/data/query/#{@ds}/#{@type_name}") |> resp!(200)
      assert body["result"]["count"] == 100
    end
  end

  describe "GET /w/:ws/p/:project/v1/data/query/... — the scoped route" do
    test "honours id_prefix identically to the flat route", %{conn: conn, raw_token: raw} do
      body =
        conn
        |> authed(raw)
        |> get("/w/default/p/default/v1/data/query/#{@ds}/#{@type_name}?id_prefix=#{@prefix}")
        |> resp!(200)

      assert ids(body) == Enum.sort(@family)
      assert body["result"]["count"] == 3
    end

    test "a blank id_prefix is the same named 400 on the scoped route", %{
      conn: conn,
      raw_token: raw
    } do
      body =
        conn
        |> authed(raw)
        |> get("/w/default/p/default/v1/data/query/#{@ds}/#{@type_name}?id_prefix=")
        |> resp!(400)

      assert body["error"]["code"] == "invalid_filter"
      assert body["error"]["message"] =~ "id_prefix"
    end
  end

  describe "GET /api/documents/:type — the legacy list door" do
    test "honours id_prefix (it walks 10k rows, so an ignored one is worse here)", %{
      conn: conn,
      raw_token: raw
    } do
      body =
        conn
        |> authed(raw)
        |> get("/api/documents/#{@type_name}?id_prefix=#{@prefix}")
        |> resp!(200)

      assert body["documents"] |> Enum.map(& &1["id"]) |> Enum.sort() == Enum.sort(@family)
      assert body["count"] == 3
    end

    test "without id_prefix it still returns the whole corpus", %{conn: conn, raw_token: raw} do
      body = conn |> authed(raw) |> get("/api/documents/#{@type_name}") |> resp!(200)

      assert body["count"] == length(@family) + @noise,
             "the legacy walk is the fallback this filter must be distinguishable from"
    end

    test "a blank id_prefix is the same named 400 on the legacy door", %{
      conn: conn,
      raw_token: raw
    } do
      body =
        conn |> authed(raw) |> get("/api/documents/#{@type_name}?id_prefix=") |> resp!(400)

      assert body["error"]["code"] == "invalid_filter"
      assert body["error"]["message"] =~ "id_prefix"
    end
  end
end
