defmodule BarkparkWeb.Contract.FilterOpsTest do
  @moduledoc """
  Black-box HTTP contract for the filter operators — real router, real DB.

  ## The mutation proof lives HERE, and why it moved

  `test/barkpark_web/controllers/query_controller_filter_test.exs` was the file
  the fail-closed filter guard was nominally pinned by, and it is VACUOUS as a
  mutation target: it is a white-box `use ExUnit.Case` file calling
  `QueryController.invalid_filter_op_for_test/1` directly, so deleting the guard
  makes it fail to COMPILE rather than fail an assertion — a compile error proves
  nothing about what a caller receives. Every mutation proof for this behaviour is
  measured against THIS file instead (ConnCase, real requests).

  Three runs of `mix test` on THIS file, measured on the
  gfr-w1-filter-chokepoint-strict branch:

    | query.ex        | query_controller.ex:51 guard | result                |
    |-----------------|------------------------------|-----------------------|
    | strict (shipped)| intact (shipped)             | 22 tests, 0 failures  |
    | strict (shipped)| guard arm DELETED            | 22 tests, 4 failures  |
    | origin/main's   | guard arm DELETED            | 22 tests, 6 failures  |

  Row 3 is what the guard alone was worth, and it is the defect this slice closes:
  with the door removed and the builder still permissive, `?filter[title][bogus]=`
  came back `left: 200, right: 400` — a 200 OK carrying EVERY row, from a filter
  that never ran.

  Row 2 is the relocation. The four failures are all the SAME shape:
  `** (Barkpark.Content.InvalidFilterError)` raised out of
  `Content.Query.apply_filter_map/2` — never a 200, never a 500. The request is
  still refused with a 400 `invalid_filter` envelope (Phoenix's RenderErrors
  renders and SENDS it before re-raising; `Phoenix.ConnTest` then re-raises into
  the test, which is why a `get/2`-style assertion reds rather than reading the
  body). The last describe below pins that sent envelope directly with
  `assert_error_sent/2`.

  The `in`-with-a-map case in the last describe needs no mutation at all: that
  shape walked past the door's guard on unpatched main — the guard checks an ops
  map's KEYS, plus the values of `is`/`hasStrong`/the range ops, but never the
  value of `in`/`nin` — and was silently unfiltered.
  """

  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "fops_http"
    )

    for {id, title} <- [{"f1", "Alpha"}, {"f2", "Beta"}, {"f3", "Gamma"}] do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => title}, "fops_http")
      {:ok, _} = Content.publish_document(id, "post", "fops_http")
    end

    :ok
  end

  test "filter[title][eq]=Alpha matches one", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Beq%5D=Alpha")
      |> json_response(200)

    assert body["count"] == 1
    assert hd(body["documents"])["title"] == "Alpha"
  end

  test "filter[title][in]=Alpha,Gamma matches two", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bin%5D=Alpha,Gamma")
      |> json_response(200)

    assert body["count"] == 2
    titles = Enum.map(body["documents"], & &1["title"]) |> Enum.sort()
    assert titles == ["Alpha", "Gamma"]
  end

  test "filter[title][contains]=a is case-insensitive", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bcontains%5D=a")
      |> json_response(200)

    assert body["count"] == 3
  end

  test "bare filter[title]=Alpha still works (sugar for eq)", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D=Alpha")
      |> json_response(200)

    assert body["count"] == 1
  end

  test "scalar `field is null` / `is not null` filter (CLI/raw-API form)", %{conn: conn} do
    # f1/f2/f3 have no `category`; f4 does.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "f4", "title" => "Delta", "category" => "x"},
        "fops_http"
      )

    {:ok, _} = Content.publish_document("f4", "post", "fops_http")

    is_null =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("category is null")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(is_null["documents"], & &1["title"]) |> Enum.sort() ==
             ["Alpha", "Beta", "Gamma"]

    is_not_null =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("category is not null")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(is_not_null["documents"], & &1["title"]) == ["Delta"]
  end

  test "scalar `^=` (startsWith) / `$=` (endsWith) shorthands", %{conn: conn} do
    # f1 Alpha, f2 Beta, f3 Gamma
    starts =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title^=Al")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(starts["documents"], & &1["title"]) == ["Alpha"]

    ends =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title$=ma")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(ends["documents"], & &1["title"]) == ["Gamma"]
  end

  test "scalar `*=` (contains) shorthand — substring, case-insensitive", %{conn: conn} do
    # f1 Alpha, f2 Beta, f3 Gamma all contain "a" (case-insensitive)
    all_a =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title*=A")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(all_a["documents"], & &1["title"]) |> Enum.sort() == [
             "Alpha",
             "Beta",
             "Gamma"
           ]

    # "et" is a mid-string substring of only Beta
    et =
      conn
      |> get("/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title*=et")}")
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(et["documents"], & &1["title"]) == ["Beta"]
  end

  test "scalar `in` / `not in` membership (comma list)", %{conn: conn} do
    in_ =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title in Alpha,Gamma")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(in_["documents"], & &1["title"]) |> Enum.sort() == ["Alpha", "Gamma"]

    not_in =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title not in Alpha,Gamma")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(not_in["documents"], & &1["title"]) == ["Beta"]
  end

  test "an operator value containing ` in ` is NOT misread as an `in` filter", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "f9", "title" => "logged in user"},
        "fops_http"
      )

    {:ok, _} = Content.publish_document("f9", "post", "fops_http")

    # `title=logged in user` → eq on the whole value (operator wins over the ` in ` keyword)
    body =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("title=logged in user")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    assert Enum.map(body["documents"], & &1["title"]) == ["logged in user"]
  end

  test "?fields= projects to the named content fields (plus system fields)", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "proj1", "title" => "Projected", "body" => "secret body", "slug" => "proj-1"},
        "fops_http"
      )

    {:ok, _} = Content.publish_document("proj1", "post", "fops_http")

    doc =
      conn
      |> get(
        "/v1/data/query/fops_http/post" <>
          "?filter=#{URI.encode_www_form("title=Projected")}&fields=title,slug"
      )
      |> json_response(200)
      |> Map.fetch!("result")
      |> Map.fetch!("documents")
      |> hd()

    # selected content fields present
    assert doc["title"] == "Projected"
    assert doc["slug"] == "proj-1"
    # unselected content field dropped
    refute Map.has_key?(doc, "body")
    # system fields always kept
    assert doc["_id"]
    assert doc["_type"] == "post"
  end

  test "?fields= with a dotted path keeps the top-level parent object (no silent drop)", %{
    conn: conn
  } do
    {:ok, _} =
      Content.create_document(
        "post",
        %{
          "_id" => "nest1",
          "title" => "Nested",
          "meta" => %{"seo" => "s", "other" => "o"},
          "body" => "b"
        },
        "fops_http"
      )

    {:ok, _} = Content.publish_document("nest1", "post", "fops_http")

    doc =
      conn
      |> get(
        "/v1/data/query/fops_http/post" <>
          "?filter=#{URI.encode_www_form("title=Nested")}&fields=meta.seo"
      )
      |> json_response(200)
      |> Map.fetch!("result")
      |> Map.fetch!("documents")
      |> hd()

    # the dotted select keeps the whole `meta` parent rather than dropping it
    assert doc["meta"] == %{"seo" => "s", "other" => "o"}
    # other unselected top-level fields still dropped
    refute Map.has_key?(doc, "body")
    refute Map.has_key?(doc, "title")
    assert doc["_id"]
  end

  test "GET /doc with ?fields= projects the single document too", %{conn: conn} do
    {:ok, _} =
      Content.create_document(
        "post",
        %{"_id" => "sdoc", "title" => "Single", "body" => "b", "slug" => "s"},
        "fops_http"
      )

    {:ok, _} = Content.publish_document("sdoc", "post", "fops_http")

    %{"result" => doc} =
      conn
      |> get("/v1/data/doc/fops_http/post/sdoc?fields=title")
      |> json_response(200)

    assert doc["title"] == "Single"
    refute Map.has_key?(doc, "body")
    refute Map.has_key?(doc, "slug")
    assert doc["_id"]
    assert doc["_type"] == "post"
  end

  test "multi-field order — comma-separated specs sort by primary then secondary", %{conn: conn} do
    for {id, rank, title} <- [{"m1", 1, "Zeta"}, {"m2", 1, "Alpha"}, {"m3", 2, "Mid"}] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => id, "title" => title, "rank" => rank},
          "fops_http"
        )

      {:ok, _} = Content.publish_document(id, "post", "fops_http")
    end

    # `rank is not null` scopes to m1/m2/m3 (Alpha/Beta/Gamma have no rank).
    body =
      conn
      |> get(
        "/v1/data/query/fops_http/post" <>
          "?filter=#{URI.encode_www_form("rank is not null")}" <>
          "&order=#{URI.encode_www_form("rank:asc,title:asc")}"
      )
      |> json_response(200)
      |> Map.fetch!("result")

    # rank 1 (Alpha < Zeta by title), then rank 2 (Mid). Without the title
    # tiebreak the Alpha/Zeta order within rank 1 would be undefined.
    assert Enum.map(body["documents"], & &1["title"]) == ["Alpha", "Zeta", "Mid"]
  end

  test "an unknown filter operator is REJECTED (400), not silently ignored", %{conn: conn} do
    # Regression: apply_field_op/4's catch-all used to return the query unchanged
    # for an unrecognized op, so a typo'd operator silently returned EVERY row.
    # It must fail closed with a canonical error instead.
    resp = get(conn, "/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bbogus%5D=Alpha")

    assert resp.status == 400
    error = json_response(resp, 400)["error"]
    assert error["code"] == "invalid_filter"
    assert error["details"]["field"] == "title"
    assert error["details"]["op"] == "bogus"
    # The message names the bad op + field and lists the valid ones; hint too.
    assert error["message"] =~ "bogus"
    assert error["message"] =~ "startsWith"
    assert is_binary(error["hint"]) and error["hint"] != ""
  end

  test "a range op with a non-scalar (array-bracket) value is a 4xx envelope, not a 500",
       %{conn: conn} do
    # Regression: `?filter[x][gt][]=1` delivers a LIST value; parse_number/1 can't
    # read it and Postgrex can't bind a list into a scalar SQL compare → a bare
    # 500. It must be caught up front and routed through the invalid_filter path.
    resp = get(conn, "/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bgt%5D%5B%5D=1")

    assert resp.status == 400
    error = json_response(resp, 400)["error"]
    assert error["code"] == "invalid_filter"
    assert error["details"]["field"] == "title"
    assert error["details"]["op"] == "gt"
  end

  test "a valid operator still returns 200 (the fail-closed check didn't over-reject)",
       %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5BstartsWith%5D=Al")
      |> json_response(200)

    assert Enum.map(body["documents"], & &1["title"]) == ["Alpha"]
  end

  test "filter[tags][hasStrong]=tag:min filters on weighted strength; malformed value 400s",
       %{conn: conn} do
    # E3 runs for every type at publish, so the weighted names are registered.
    content =
      Barkpark.LabelFixtures.with_named_labels(
        %{},
        "fops_http",
        [{"wired", 80}, {"wiredx", 10}]
      )

    {:ok, _} =
      Content.create_document(
        "post",
        Map.merge(%{"_id" => "hs1", "title" => "Wired Strong"}, content),
        "fops_http"
      )

    {:ok, _} = Content.publish_document("hs1", "post", "fops_http")

    %{"result" => hit} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btags%5D%5BhasStrong%5D=wired:50")
      |> json_response(200)

    assert hit["count"] == 1
    assert hd(hit["documents"])["_id"] == "hs1"

    # Below the stored strength -> no match (and flat-tagged f1..f3 never match).
    %{"result" => miss} =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btags%5D%5BhasStrong%5D=wired:90")
      |> json_response(200)

    assert miss["count"] == 0

    # A floor-less value fails CLOSED (invalid_filter), never a silent no-op.
    error =
      conn
      |> get("/v1/data/query/fops_http/post?filter%5Btags%5D%5BhasStrong%5D=wired")
      |> json_response(400)
      |> Map.fetch!("error")

    assert error["code"] == "invalid_filter"
    assert error["details"]["field"] == "tags"
    assert error["details"]["op"] == "hasStrong"
  end

  test "flat filter 'tags hasStrong tag:min' filters end to end (CLI --filter form, D75)",
       %{conn: conn} do
    content =
      Barkpark.LabelFixtures.with_named_labels(%{}, "fops_http", [{"wired", 80}])

    {:ok, _} =
      Content.create_document(
        "post",
        Map.merge(%{"_id" => "hs2", "title" => "Flat Wired"}, content),
        "fops_http"
      )

    {:ok, _} = Content.publish_document("hs2", "post", "fops_http")

    # Mutation-proof: drop parse_scalar_has_strong from the keyword chain and
    # the string becomes an invalid_flat_filter 400 — json_response(200) reds.
    %{"result" => hit} =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("tags hasStrong wired:50")}"
      )
      |> json_response(200)

    assert hit["count"] == 1
    assert hd(hit["documents"])["_id"] == "hs2"

    # Above the stored strength -> no match — proves the filter APPLIED
    # (before D75 this exact shape silently returned the unfiltered set).
    %{"result" => miss} =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("tags hasStrong wired:90")}"
      )
      |> json_response(200)

    assert miss["count"] == 0

    # A malformed hasStrong VALUE routes through the shared fail-closed guard.
    error =
      conn
      |> get(
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("tags hasStrong wired")}"
      )
      |> json_response(400)
      |> Map.fetch!("error")

    assert error["code"] == "invalid_filter"
    assert error["details"]["field"] == "tags"
    assert error["details"]["op"] == "hasStrong"
  end

  test "an unparseable flat filter is a 400 naming the grammar — NEVER the unfiltered set (D75)",
       %{conn: conn} do
    # Mutation-proof: re-open the passthrough (normalize_filter_map falling
    # back to %{}) and this request is a 200 carrying every fixture row — the
    # 400 assertion reds. A refusal beats a silent passthrough.
    resp =
      get(
        conn,
        "/v1/data/query/fops_http/post?filter=#{URI.encode_www_form("epic weighted nonsense")}"
      )

    assert resp.status == 400
    error = json_response(resp, 400)["error"]
    assert error["code"] == "invalid_filter"
    assert error["details"]["filter"] == "epic weighted nonsense"
    # The message names the accepted flat grammar, hasStrong included.
    assert error["message"] =~ "hasStrong <tag>:<min>"
    assert is_binary(error["hint"]) and error["hint"] != ""
  end

  # ── the refusal moved to the query builder (gfr-w1-filter-chokepoint-strict) ─
  #
  # Everything above this line was refused by ONE door: `QueryController`'s
  # `invalid_filter_op/1` guard. `Content.Query` itself fell open — an op with no
  # clause hit `apply_field_op/4`'s catch-all, which returned the query UNCHANGED
  # and handed the caller the UNFILTERED set. The refusal lives at the builder's
  # chokepoint now (`apply_filter_map/2`), so a door that forgets to guard — the
  # Studio desk, a plugin filter, a door written next year — inherits it.
  describe "the builder is the chokepoint, not the controller door" do
    test "an `in` filter whose value is a MAP is refused, not silently unfiltered",
         %{conn: conn} do
      # The controller guard checks the KEYS of an ops map, plus the values of
      # `is`, `hasStrong`, and the range ops — but never the value of `in`/`nin`.
      # `?filter[title][in][x]=Alpha` therefore walked straight past it, missed
      # `apply_field_op(_, _, "in", vs) when is_list(vs)`, and landed in the
      # catch-all: 200 OK carrying EVERY row, from a filter that never ran. That
      # is the field report's #2b shape, reachable over plain HTTP.
      #
      # It is refused at the builder now, so the answer is a 400 — and the
      # envelope is the SAME `invalid_filter` code the door emits, because the
      # typed refusal carries its own status (Plug.Exception) and its own
      # envelope (Content.Errors + ErrorJSON) to every door at once.
      # `assert_error_sent/2` because the refusal ESCAPES the controller: Phoenix's
      # RenderErrors renders and sends the response (the client gets the envelope
      # below), then re-raises so the fault is visible in logs and in tests. That
      # is the backstop path every unguarded door takes.
      {400, _headers, body} =
        assert_error_sent(400, fn ->
          get(conn, "/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bin%5D%5Bx%5D=Alpha")
        end)

      error = Jason.decode!(body)["error"]
      assert error["code"] == "invalid_filter"
      assert error["details"]["op"] == "in"
      assert error["message"] =~ "in"
      assert is_binary(error["hint"]) and error["hint"] != ""
    end

    test "the builder-raised refusal does not echo the FIELD name", %{conn: conn} do
      # `forbidden_query_field/4` — the field-visibility gate — runs BEFORE the
      # query is built, and at non-HTTP doors it never runs at all. A refusal
      # raised from INSIDE the builder does not inherit that ordering, so it
      # names the OP (what the caller must fix) and the accepted vocabulary, and
      # never the field. See `Barkpark.Content.InvalidFilterError`'s moduledoc.
      {400, _headers, body} =
        assert_error_sent(400, fn ->
          get(conn, "/v1/data/query/fops_http/post?filter%5BsecretField%5D%5Bin%5D%5Bx%5D=Alpha")
        end)

      error = Jason.decode!(body)["error"]
      assert error["code"] == "invalid_filter"
      refute error["message"] =~ "secretField"
      refute Map.has_key?(error["details"], "field")
    end

    test "a legitimate `in` list is untouched by the new refusal", %{conn: conn} do
      # The fail-closed check must not over-reject the shape the SDK actually
      # sends (a comma string the door splits into a list).
      %{"result" => body} =
        conn
        |> get("/v1/data/query/fops_http/post?filter%5Btitle%5D%5Bin%5D=Alpha,Gamma")
        |> json_response(200)

      assert body["count"] == 2
    end
  end
end
