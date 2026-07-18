defmodule BarkparkWeb.Contract.SearchTest do
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content

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
end
