defmodule BarkparkWeb.Contract.QueryTest do
  use BarkparkWeb.ConnCase, async: false
  alias Barkpark.Content

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    for i <- 1..5 do
      {:ok, _} = Content.create_document("post", %{"_id" => "q#{i}", "title" => "T#{i}"}, "test")
      {:ok, _} = Content.publish_document("q#{i}", "post", "test")
    end

    :ok
  end

  test "limit caps page size", %{conn: conn} do
    %{"result" => body} = conn |> get("/v1/data/query/test/post?limit=2") |> json_response(200)
    assert length(body["documents"]) == 2
    assert body["count"] == 2
    assert body["limit"] == 2
  end

  test "order=title:desc / :asc sorts by the promoted title column", %{conn: conn} do
    %{"result" => desc} =
      conn |> get("/v1/data/query/test/post?order=title:desc") |> json_response(200)

    assert Enum.map(desc["documents"], & &1["title"]) == ["T5", "T4", "T3", "T2", "T1"]

    %{"result" => asc} =
      conn |> get("/v1/data/query/test/post?order=title:asc") |> json_response(200)

    assert Enum.map(asc["documents"], & &1["title"]) == ["T1", "T2", "T3", "T4", "T5"]
  end

  test "order=<contentField>:asc sorts by a JSONB content field", %{conn: conn} do
    for {id, rank} <- [{"r1", "30"}, {"r2", "10"}, {"r3", "20"}] do
      {:ok, _} =
        Content.create_document("post", %{"_id" => id, "title" => "R", "rank" => rank}, "test")

      {:ok, _} = Content.publish_document(id, "post", "test")
    end

    %{"result" => body} =
      conn
      |> get("/v1/data/query/test/post?filter[title]=R&order=rank:asc")
      |> json_response(200)

    assert Enum.map(body["documents"], & &1["rank"]) == ["10", "20", "30"]
  end

  test "order=<nested.path>:asc sorts by a nested JSONB content field", %{conn: conn} do
    for {id, rank} <- [{"n1", "30"}, {"n2", "10"}, {"n3", "20"}] do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => id, "title" => "N", "meta" => %{"rank" => rank}},
          "test"
        )

      {:ok, _} = Content.publish_document(id, "post", "test")
    end

    # The dot-path must survive parse_order (it used to fail the regex and fall
    # back to :updated_at_desc — insertion order ["30","10","20"], not sorted).
    %{"result" => body} =
      conn
      |> get("/v1/data/query/test/post?filter[title]=N&order=meta.rank:asc")
      |> json_response(200)

    assert Enum.map(body["documents"], &get_in(&1, ["meta", "rank"])) == ["10", "20", "30"]
  end

  test "offset paginates", %{conn: conn} do
    %{"result" => b1} =
      conn |> get("/v1/data/query/test/post?limit=2&offset=0") |> json_response(200)

    %{"result" => b2} =
      conn |> get("/v1/data/query/test/post?limit=2&offset=2") |> json_response(200)

    ids1 = Enum.map(b1["documents"], & &1["_id"]) |> MapSet.new()
    ids2 = Enum.map(b2["documents"], & &1["_id"]) |> MapSet.new()
    assert MapSet.disjoint?(ids1, ids2)
  end

  test "filter[title]=T3 works", %{conn: conn} do
    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?filter[title]=T3") |> json_response(200)

    assert length(body["documents"]) == 1
    assert hd(body["documents"])["title"] == "T3"
  end

  # BUG 1 regression: scalar ?filter=field=value must NOT be silently ignored.
  # Both `field=value` and `field==value` forms are accepted so the CLI flag
  # (--filter 'title=T2') and the TUI apiclient (params.Set("filter", "title==T2"))
  # both filter instead of returning all documents.
  test "scalar filter=title=T2 filters documents (field=value form)", %{conn: conn} do
    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?filter=title%3DT2") |> json_response(200)

    assert body["count"] == 1
    assert hd(body["documents"])["title"] == "T2"
  end

  test "scalar filter=title==T4 filters documents (field==value form)", %{conn: conn} do
    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?filter=title%3D%3DT4") |> json_response(200)

    assert body["count"] == 1
    assert hd(body["documents"])["title"] == "T4"
  end

  test "scalar filter supports comparison operators (!= and >)", %{conn: conn} do
    # title != T3  →  excludes T3
    %{"result" => neq} =
      conn |> get("/v1/data/query/test/post?filter=title!%3DT3") |> json_response(200)

    assert Enum.map(neq["documents"], & &1["title"]) |> Enum.sort() == ["T1", "T2", "T4", "T5"]

    # title > T3  →  T4, T5 (string comparison on the promoted title column)
    %{"result" => gt} =
      conn |> get("/v1/data/query/test/post?filter=title%3ET3") |> json_response(200)

    assert Enum.map(gt["documents"], & &1["title"]) |> Enum.sort() == ["T4", "T5"]
  end

  test "scalar filter splits on the leftmost operator — values keep operator chars", %{conn: conn} do
    {:ok, _} =
      Content.create_document("post", %{"_id" => "nq", "title" => "NQ", "notes" => "a>b"}, "test")

    {:ok, _} = Content.publish_document("nq", "post", "test")

    # `notes=a>b` → eq on `notes` with value "a>b" (the `=` is leftmost, not the `>`)
    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?filter=notes%3Da%3Eb") |> json_response(200)

    assert Enum.map(body["documents"], & &1["_id"]) == ["nq"]
  end

  test "scalar filter with no match returns empty result, not all documents", %{conn: conn} do
    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?filter=title%3Dnonexistent") |> json_response(200)

    assert body["count"] == 0
    assert body["documents"] == []
  end

  # TUI wire form (authoritative): apiclient's Client.Query sends
  # params.Set("filter", `title == "T3"`) — spaces around `==`, value wrapped
  # in ONE pair of double-quotes. The quotes must be stripped and only the
  # matching document returned.
  test ~s(TUI wire form: filter=title == "T3" filters to the single match), %{conn: conn} do
    query = URI.encode_query(%{"filter" => ~s(title == "T3")})

    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?" <> query) |> json_response(200)

    assert body["count"] == 1
    assert hd(body["documents"])["title"] == "T3"
  end

  test "value with inner quotes keeps them; only ONE surrounding pair is stripped", %{
    conn: conn
  } do
    # A document whose title literally contains double-quotes. The wire string
    # `title == "say "hi""` must strip ONLY the outer pair, leaving the
    # inner-quoted literal `say "hi"` to match this doc — a positive match
    # proves the stripping is exactly one pair, not greedy.
    {:ok, _} =
      Content.create_document("post", %{"_id" => "qq", "title" => ~s(say "hi")}, "test")

    {:ok, _} = Content.publish_document("qq", "post", "test")

    query = URI.encode_query(%{"filter" => ~s(title == "say "hi"")})

    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?" <> query) |> json_response(200)

    assert body["count"] == 1
    assert hd(body["documents"])["title"] == ~s(say "hi")
  end

  test "order=_createdAt:asc reverses default", %{conn: conn} do
    %{"result" => desc} = conn |> get("/v1/data/query/test/post") |> json_response(200)

    %{"result" => asc} =
      conn |> get("/v1/data/query/test/post?order=_createdAt:asc") |> json_response(200)

    assert Enum.map(desc["documents"], & &1["_id"]) ==
             Enum.reverse(Enum.map(asc["documents"], & &1["_id"]))
  end

  test "envelope carries result + syncTags + ms + etag + schemaHash", %{conn: conn} do
    resp = get(conn, "/v1/data/query/test/post")
    body = json_response(resp, 200)

    for key <- ~w(result syncTags ms etag schemaHash) do
      assert Map.has_key?(body, key), "envelope missing key: #{key}"
    end

    assert is_map(body["result"])
    assert is_list(body["syncTags"])
    assert is_integer(body["ms"])
    assert is_binary(body["etag"])
    assert is_binary(body["schemaHash"])

    # The header and the body carry DIFFERENT tokens on purpose
    # (task-496f010fa8f4d9dc). The body's `etag` is the SDK's document change
    # token — `js/packages/core/src/doc.ts` hands it back as `ifMatch`, which
    # `Content.Mutations.if_rev/1` compares to the stored rev. The `ETag` header
    # is a CACHE VALIDATOR and additionally folds the dataset schema hash,
    # because `Envelope.render/3` picks the visible field set out of the schema
    # and a schema edit moves no `_rev`. This used to assert the two were equal;
    # that identity is what let a newly-private field be served out of a 304.
    [header_etag | _] = Plug.Conn.get_resp_header(resp, "etag")
    assert is_binary(header_etag)
    refute header_etag == ~s("#{body["etag"]}")

    type_tag = "bp:ds:test:type:post"
    assert type_tag in body["syncTags"]
  end

  test "If-None-Match matching etag returns 304", %{conn: conn} do
    resp1 = get(conn, "/v1/data/query/test/post")
    body1 = json_response(resp1, 200)
    [etag_header | _] = Plug.Conn.get_resp_header(resp1, "etag")

    resp2 =
      conn
      |> put_req_header("if-none-match", etag_header)
      |> get("/v1/data/query/test/post")

    assert resp2.status == 304
    assert resp2.resp_body == ""
    assert is_binary(body1["etag"])
  end

  test "in-place edit (same id, new rev) changes the etag — no spurious 304", %{conn: conn} do
    resp1 = get(conn, "/v1/data/query/test/post")
    body1 = json_response(resp1, 200)
    [etag_header | _] = Plug.Conn.get_resp_header(resp1, "etag")

    # Mutate a doc in place: same _id, new content → publish mints a new rev.
    {:ok, _} = Content.create_document("post", %{"_id" => "q1", "title" => "T1-edited"}, "test")
    {:ok, _} = Content.publish_document("q1", "post", "test")

    resp2 = get(conn, "/v1/data/query/test/post")
    body2 = json_response(resp2, 200)

    # The id set is unchanged, but the edited doc's rev changed → etag must too.
    assert body1["etag"] != body2["etag"]

    # A conditional GET carrying the STALE etag must NOT 304 (would serve stale).
    resp3 =
      conn
      |> put_req_header("if-none-match", etag_header)
      |> get("/v1/data/query/test/post")

    assert resp3.status == 200
  end

  test "reordering the same doc set changes the etag", %{conn: conn} do
    %{"etag" => asc_etag} =
      conn |> get("/v1/data/query/test/post?order=title:asc") |> json_response(200)

    %{"etag" => desc_etag} =
      conn |> get("/v1/data/query/test/post?order=title:desc") |> json_response(200)

    # Same id set, opposite order — the etag folds list order, so they differ.
    assert asc_etag != desc_etag
  end

  test "filter[title][neq] excludes matching docs", %{conn: conn} do
    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?filter[title][neq]=T3") |> json_response(200)

    assert Enum.map(body["documents"], & &1["title"]) |> Enum.sort() == ["T1", "T2", "T4", "T5"]
  end

  test "neq on a content field uses strict != — NULL/absent rows are excluded", %{conn: conn} do
    for {id, kind} <- [{"k1", "a"}, {"k2", "b"}] do
      {:ok, _} =
        Content.create_document("post", %{"_id" => id, "title" => "K", "kind" => kind}, "test")

      {:ok, _} = Content.publish_document(id, "post", "test")
    end

    # a doc with NO `kind` field at all
    {:ok, _} = Content.create_document("post", %{"_id" => "k3", "title" => "K"}, "test")
    {:ok, _} = Content.publish_document("k3", "post", "test")

    %{"result" => body} =
      conn
      |> get("/v1/data/query/test/post?filter[title]=K&filter[kind][neq]=a")
      |> json_response(200)

    # k2 (kind=b) matches; k1 (kind=a) excluded; k3 (no kind) excluded — strict !=
    assert Enum.map(body["documents"], & &1["_id"]) == ["k2"]
  end

  test "filter[title][nin] excludes the listed values", %{conn: conn} do
    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?filter[title][nin]=T2,T3") |> json_response(200)

    assert Enum.map(body["documents"], & &1["title"]) |> Enum.sort() == ["T1", "T4", "T5"]
  end

  test "count=true returns the total matching count, independent of the page", %{conn: conn} do
    %{"result" => body} =
      conn |> get("/v1/data/query/test/post?limit=2&count=true") |> json_response(200)

    assert length(body["documents"]) == 2
    assert body["count"] == 2
    # 5 docs match; the page is capped at 2 but total reflects the whole set
    assert body["total"] == 5
  end

  test "count=true reflects the filter", %{conn: conn} do
    %{"result" => body} =
      conn
      |> get("/v1/data/query/test/post?filter[title][neq]=T3&count=true")
      |> json_response(200)

    assert body["total"] == 4
  end

  test "total is omitted unless ?count=true", %{conn: conn} do
    %{"result" => body} = conn |> get("/v1/data/query/test/post") |> json_response(200)
    refute Map.has_key?(body, "total")
  end

  test "filter[field][has] matches array membership — {_ref} objects and plain strings", %{
    conn: conn
  } do
    docs = [
      {"h1", [%{"_ref" => "tag-a"}, %{"_ref" => "tag-b"}]},
      {"h2", [%{"_ref" => "tag-c"}]},
      {"h3", ["tag-a", "x"]},
      # h4: no tags field — the CASE guard must no-match, not error
      {"h4", nil}
    ]

    for {id, tags} <- docs do
      content =
        if tags,
          do: %{"_id" => id, "title" => "H", "tags" => tags},
          else: %{"_id" => id, "title" => "H"}

      {:ok, _} = Content.create_document("post", content, "test")
      {:ok, _} = Content.publish_document(id, "post", "test")
    end

    %{"result" => body} =
      conn
      |> get("/v1/data/query/test/post?filter[title]=H&filter[tags][has]=tag-a")
      |> json_response(200)

    # h1 ({_ref: tag-a}) and h3 ("tag-a") match; h2 and h4 do not
    assert Enum.map(body["documents"], & &1["_id"]) |> Enum.sort() == ["h1", "h3"]
  end

  test "filter[field][has] matches number and boolean array elements, not just strings/_refs",
       %{conn: conn} do
    for {id, extra} <- [
          {"n1", %{"years" => [2020, 2021], "active" => [true]}},
          {"n2", %{"years" => [2019], "active" => [false]}}
        ] do
      {:ok, _} =
        Content.create_document("post", Map.merge(%{"_id" => id, "title" => "N"}, extra), "test")

      {:ok, _} = Content.publish_document(id, "post", "test")
    end

    # number element: only n1's [2020, 2021] contains 2021. Before the text-form
    # match, the value "2021" only matched a JSON *string*, never the number → 0.
    %{"result" => y} =
      conn
      |> get("/v1/data/query/test/post?filter[title]=N&filter[years][has]=2021")
      |> json_response(200)

    assert Enum.map(y["documents"], & &1["_id"]) == ["n1"]

    # boolean element: only n1 has active [true]
    %{"result" => b} =
      conn
      |> get("/v1/data/query/test/post?filter[title]=N&filter[active][has]=true")
      |> json_response(200)

    assert Enum.map(b["documents"], & &1["_id"]) == ["n1"]
  end

  describe "If-None-Match is the shared RFC 9110 §13.1.2 matcher (D11)" do
    # The header this route emits is the QUOTED entity-tag `"<validator>"`.
    # The old private matcher compared `strip_etag(candidate)` (W/ AND the
    # quotes stripped) against the UNQUOTED validator, and read only the FIRST
    # header line. Both are fixed by delegating to BarkparkWeb.Http.IfNoneMatch.

    # POSITIVE CONTROL — a client that echoes our ETag byte-for-byte must 304.
    # Green before AND after; it is what proves the two pins below are not
    # simply switching 304 off.
    test "the exact emitted entity-tag still 304s", %{conn: conn} do
      [etag | _] =
        conn |> get("/v1/data/query/test/post") |> Plug.Conn.get_resp_header("etag")

      resp =
        conn |> put_req_header("if-none-match", etag) |> get("/v1/data/query/test/post")

      assert resp.status == 304
    end

    # DECIDED CHANGE — an unquoted bare validator is NOT an entity-tag we ever
    # put on the wire. The old strip_etag/1 accepted it (over-lenient, the row's
    # words). PIN: reds on the pre-delegation matcher (it answered 304).
    test "an UNQUOTED bare validator no longer 304s", %{conn: conn} do
      [etag | _] =
        conn |> get("/v1/data/query/test/post") |> Plug.Conn.get_resp_header("etag")

      bare = String.trim(etag, ~s("))
      refute bare == etag, "fixture is vacuous: the emitted etag carries no quotes"

      resp =
        conn |> put_req_header("if-none-match", bare) |> get("/v1/data/query/test/post")

      assert resp.status == 200
    end

    # The weak form of our own strong tag DOES select it (§13.1.2 weak compare).
    test "the weak form of the emitted tag 304s", %{conn: conn} do
      [etag | _] =
        conn |> get("/v1/data/query/test/post") |> Plug.Conn.get_resp_header("etag")

      resp =
        conn
        |> put_req_header("if-none-match", "W/" <> etag)
        |> get("/v1/data/query/test/post")

      assert resp.status == 304
    end

    # MULTI-LINE FOLDING — the old matcher took `[hv | _]`, so a match on any
    # line but the first was invisible. PIN: reds on the pre-delegation matcher.
    test "a match on the SECOND If-None-Match line 304s", %{conn: conn} do
      [etag | _] =
        conn |> get("/v1/data/query/test/post") |> Plug.Conn.get_resp_header("etag")

      resp =
        conn
        |> then(fn c ->
          %{c | req_headers: c.req_headers ++ [{"if-none-match", ~s("nope")}, {"if-none-match", etag}]}
        end)
        |> get("/v1/data/query/test/post")

      assert resp.status == 304
    end

    # NEGATIVE CONTROL — a validator we never emitted gets the body.
    test "a foreign validator gets 200", %{conn: conn} do
      resp =
        conn
        |> put_req_header("if-none-match", ~s("not-a-validator-we-ever-sent"))
        |> get("/v1/data/query/test/post")

      assert resp.status == 200
    end

    # The wildcard still short-circuits.
    test "the * wildcard 304s", %{conn: conn} do
      resp =
        conn |> put_req_header("if-none-match", "*") |> get("/v1/data/query/test/post")

      assert resp.status == 304
    end
  end
end
