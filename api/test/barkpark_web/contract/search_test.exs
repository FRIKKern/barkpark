defmodule BarkparkWeb.Contract.SearchTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Search.HitEnvelope

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "test", ["read", "write", "admin"])

    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      "test"
    )

    Content.upsert_schema(
      %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
      "test"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.s1", "title" => "Elixir Phoenix Guide"},
      "test"
    )

    Content.create_document(
      "post",
      %{"doc_id" => "drafts.s2", "title" => "React Tutorial"},
      "test"
    )

    Content.create_document(
      "author",
      %{"doc_id" => "drafts.s3", "title" => "Phoenix Wright"},
      "test"
    )

    Content.publish_document("s1", "post", "test")
    Content.publish_document("s2", "post", "test")
    Content.publish_document("s3", "author", "test")
    :ok
  end

  test "searches by title across types", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix"})
    assert resp.status == 200
    body = Jason.decode!(resp.resp_body)
    assert length(body["documents"]) == 2
    titles = Enum.map(body["documents"], & &1["title"])
    assert "Elixir Phoenix Guide" in titles
    assert "Phoenix Wright" in titles
  end

  test "filters search by type", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix", "type" => "post"})
    body = Jason.decode!(resp.resp_body)
    assert length(body["documents"]) == 1
    assert hd(body["documents"])["_type"] == "post"
  end

  test "returns empty list for no matches", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "zzzznoexist"})
    body = Jason.decode!(resp.resp_body)
    assert body["documents"] == []
    assert body["count"] == 0
  end

  test "requires q parameter", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test")
    assert resp.status == 400
  end

  test "respects perspective (defaults to published)", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "Elixir"})
    body = Jason.decode!(resp.resp_body)
    docs = body["documents"]
    assert Enum.all?(docs, &(&1["_draft"] == false))
  end

  test "limits results", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix", "limit" => "1"})
    body = Jason.decode!(resp.resp_body)
    assert length(body["documents"]) == 1
  end

  test "exclude token removes matching documents", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix -wright"})
    body = Jason.decode!(resp.resp_body)
    titles = Enum.map(body["documents"], & &1["title"])
    assert "Elixir Phoenix Guide" in titles
    refute "Phoenix Wright" in titles
    assert body["count"] == 1
    assert is_map(body["parsedQuery"])
  end

  test "returns enrichment fields", %{conn: conn} do
    resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix"})
    body = Jason.decode!(resp.resp_body)
    assert Map.has_key?(body, "highlights")
    assert Map.has_key?(body, "parsedQuery")
  end

  # AXI R3: ?view=brief returns brief hit cards through the ONE shared
  # HitEnvelope builder. The server default stays FULL (every test above runs
  # without the param and pins the full shape).
  describe "?view=brief (AXI R3 brief hit cards)" do
    test "returns brief cards — id/type/title/slug/snippet/highlights, never full documents",
         %{conn: conn} do
      resp = get(conn, "/v1/data/search/test", %{"q" => "phoenix", "view" => "brief"})
      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)

      assert length(body["documents"]) == 2

      for card <- body["documents"] do
        assert Enum.sort(Map.keys(card)) == ~w(highlights id slug snippet title type)
      end

      card = Enum.find(body["documents"], &(&1["title"] == "Elixir Phoenix Guide"))
      assert card["id"] == "s1"
      assert card["type"] == "post"
      assert card["snippet"] =~ "Phoenix"
      assert is_map(card["highlights"])

      # The envelope key set is identical to the full view — shape-destructuring
      # clients (find-shape.ts) never branch on the view.
      for k <-
            ~w(documents count query parsedQuery highlights recovery correctedTo facets truncation ms) do
        assert Map.has_key?(body, k), "missing envelope key #{k}"
      end
    end

    test "a schema-private field never leaks into a brief card, snippet, or highlight",
         %{conn: conn} do
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "description", "type" => "string", "private" => true}
          ]
        },
        "test"
      )

      Content.create_document(
        "post",
        %{
          "doc_id" => "drafts.sbrief",
          "title" => "Cardleak Phoenix Post",
          "description" => "cardleak SSN-BRIEF-777 must never surface"
        },
        "test"
      )

      Content.publish_document("sbrief", "post", "test")

      resp = get(conn, "/v1/data/search/test", %{"q" => "cardleak", "view" => "brief"})
      body = Jason.decode!(resp.resp_body)

      card = Enum.find(body["documents"], &(&1["id"] == "sbrief"))
      assert card, "expected the published post in the brief hits"
      # The snippet comes from a READABLE field (title), not the private one.
      assert card["snippet"] =~ "Cardleak"
      refute resp.resp_body =~ "SSN-BRIEF-777"
    end

    test "brief is at least 20x smaller than full on heavyweight fixtures (byte evidence)",
         %{conn: conn} do
      big = String.duplicate("ballast corpus paragraph text for byte evidence ", 500)

      for i <- 1..3 do
        Content.create_document(
          "post",
          %{"doc_id" => "drafts.big#{i}", "title" => "Bytebeacon #{i}", "description" => big},
          "test"
        )

        Content.publish_document("big#{i}", "post", "test")
      end

      full = get(conn, "/v1/data/search/test", %{"q" => "bytebeacon"}).resp_body

      brief =
        get(conn, "/v1/data/search/test", %{"q" => "bytebeacon", "view" => "brief"}).resp_body

      ratio = Float.round(byte_size(full) / byte_size(brief), 1)

      IO.puts(
        "axi-s5 byte evidence (wc -c equivalent): full=#{byte_size(full)}B brief=#{byte_size(brief)}B ratio=#{ratio}x"
      )

      assert byte_size(full) >= 20 * byte_size(brief),
             "expected ≥20x reduction, got #{ratio}x (full=#{byte_size(full)}B brief=#{byte_size(brief)}B)"
    end

    # AXI b3: highlightFields is schema-configurable, so a heavyweight content
    # field (content.body / content.description) configured into it would echo
    # the whole marked field per brief hit. clamp_brief_highlights bounds it.
    test "a heavyweight highlightFields config can never re-inflate a brief page (b3)",
         %{conn: conn} do
      # Highlight a big content field on the documents surface for this scope.
      Barkpark.Search.SurfaceConfigs.upsert(
        "documents",
        "test",
        %{"highlightFields" => ["title", "content.description"]}
      )

      # Declare `description` PUBLIC so it is readable — and thus highlightable —
      # by the anonymous caller (the re-inflation vector being bounded).
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "description", "type" => "string"}
          ]
        },
        "test"
      )

      ballast = String.duplicate("zephyrbeacon padding words here ", 2000)

      for i <- 1..52 do
        Content.create_document(
          "post",
          %{"doc_id" => "drafts.hb#{i}", "title" => "Heftybeacon #{i}", "description" => ballast},
          "test"
        )

        Content.publish_document("hb#{i}", "post", "test")
      end

      body =
        get(conn, "/v1/data/search/test", %{"q" => "zephyrbeacon", "view" => "brief"}).resp_body

      cards = Jason.decode!(body)["documents"]

      # Default page is 50 hits.
      assert length(cards) == 50

      # The whole 50-hit brief page stays small — the unbounded markup would be
      # multiple megabytes (each description is ~62 KB, highlighted throughout).
      assert byte_size(body) <= 45_000,
             "expected 50-hit brief page <= 45 KB, got #{byte_size(body)} B"

      for card <- cards do
        snippet = card["snippet"] || ""

        assert byte_size(snippet) <= 256,
               "snippet #{byte_size(snippet)} B exceeds the 256 B budget"

        hl = card["highlights"]["content.description"]
        assert is_binary(hl), "expected a bounded content.description highlight"
        assert hl =~ "<mark>"

        assert byte_size(hl) <= 512,
               "content.description highlight #{byte_size(hl)} B is not bounded"
      end

      # The full ballast text can never appear whole in a brief card.
      refute body =~ ballast
    end

    test "an unknown view value falls back to the full shape (tolerant reader)", %{conn: conn} do
      body =
        Jason.decode!(
          get(conn, "/v1/data/search/test", %{"q" => "phoenix", "view" => "bogus"}).resp_body
        )

      [doc | _] = body["documents"]
      assert Map.has_key?(doc, "_id")
      assert Map.has_key?(doc, "_type")
    end
  end

  # wb-api-search-hasmore-echo: the envelope now echoes whether another page
  # exists (derived from the corpus-total `count` already on the wire), so a
  # paging client stops guessing from `length(documents) == limit`.
  describe "hasMore pagination echo" do
    setup do
      for i <- 1..5 do
        Content.create_document(
          "post",
          %{"doc_id" => "drafts.hm#{i}", "title" => "Hasmoreitem Alpha #{i}"},
          "test"
        )

        Content.publish_document("hm#{i}", "post", "test")
      end

      :ok
    end

    test "REST /v1/data/search: true on page 1, false on the last page", %{conn: conn} do
      page1 =
        get(conn, "/v1/data/search/test", %{
          "q" => "hasmoreitem",
          "limit" => "2",
          "offset" => "0"
        })

      body1 = Jason.decode!(page1.resp_body)
      assert body1["count"] == 5
      assert length(body1["documents"]) == 2
      assert body1["hasMore"] == true

      last_page =
        get(conn, "/v1/data/search/test", %{
          "q" => "hasmoreitem",
          "limit" => "2",
          "offset" => "4"
        })

      body_last = Jason.decode!(last_page.resp_body)
      assert body_last["count"] == 5
      assert length(body_last["documents"]) == 1
      assert body_last["hasMore"] == false
    end

    test "loopback /v1/data/local/search: true on page 1, false on the last page", %{conn: conn} do
      page1 =
        get(conn, "/v1/data/local/search/test", %{
          "q" => "hasmoreitem",
          "limit" => "2",
          "offset" => "0"
        })

      body1 = Jason.decode!(page1.resp_body)
      assert body1["count"] == 5
      assert length(body1["documents"]) == 2
      assert body1["hasMore"] == true

      last_page =
        get(conn, "/v1/data/local/search/test", %{
          "q" => "hasmoreitem",
          "limit" => "2",
          "offset" => "4"
        })

      body_last = Jason.decode!(last_page.resp_body)
      assert body_last["count"] == 5
      assert length(body_last["documents"]) == 1
      assert body_last["hasMore"] == false
    end

    test "build/5 defaults offset to 0 when the opt is absent, so an existing caller that never passes :offset keeps working" do
      envelope =
        HitEnvelope.build([], 5, "hasmoreitem", %{},
          caller_context: nil,
          schema_resolver: fn _type -> nil end
        )

      assert envelope.count == 5
      assert envelope.hasMore == true
    end
  end
end
