defmodule BarkparkWeb.SearchBodyCharsBoundTest do
  @moduledoc """
  `GET /v1/data/search/:dataset?fields=…,blocks&bodyChars=<n>` — the server-side
  bound on per-hit prose.

  ## The defect this pins

  Measured against https://guerrilla.barkpark.cloud on 2026-09-19, the
  search-starter's SSR browse seed —

      ?q=%20&engine=pg&types=post,paper,…&perspective=published&limit=100
      &fields=title,name,slug,excerpt,…,body,…,blocks

  — answered **14,648,762 bytes**. Its only consumer, `find.ts deriveBody/1`,
  flattens the block tree and caps it at 1000 characters per hit: at limit=100
  the app can use ~100 KB of the 14.65 MB it paid for. `?fields=` could not fix
  it — the projection is top-level-only, and `blocks` is one key.

  ## What is asserted here, and what is NOT

  ASSERTED: the bound is real (a bounded browse is ORDERS OF MAGNITUDE smaller
  than the same unbounded browse over the same corpus), it is a whole-block
  document prefix, it is announced (`_bodyTruncated`), it is opt-in (no param ⇒
  byte-identical to before), and a malformed cap is REFUSED rather than served
  unbounded.

  NOT ASSERTED: wall-clock latency. This suite shares a Postgres with every
  other partition on the box, so a timing assertion here would measure load.
  The live numbers live in the PR body, taken against guerrilla with curl.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.Content

  @ds "search-bodychars-bound-test"
  @hits 12
  # ~200 blocks x ~400 prose chars = ~80 KB of prose per hit before the bound.
  @blocks_per_doc 200
  @chars_per_block 400

  defp block(i),
    do: %{
      "_type" => "paragraph",
      "_key" => "k#{i}",
      "children" => [%{"_type" => "span", "value" => String.duplicate("z", @chars_per_block)}]
    }

  setup do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "post", "visibility" => "public"},
        @ds
      )

    for i <- 1..@hits do
      id = "bodychars-doc-#{i}"

      {:ok, _} =
        Content.create_document(
          "post",
          %{
            "doc_id" => id,
            "title" => "Bodycharsuniq Doc #{i}",
            "excerpt" => "short excerpt",
            "blocks" => Enum.map(1..@blocks_per_doc, &block/1)
          },
          @ds,
          []
        )

      {:ok, _} = Content.publish_document(id, "post", @ds, [])
    end

    :ok
  end

  defp browse(conn, extra) do
    params =
      Keyword.merge(
        [
          q: " ",
          types: "post",
          perspective: "published",
          limit: "100",
          fields: "title,excerpt,blocks"
        ],
        extra
      )

    get(conn, "/v1/data/search/#{@ds}", params)
  end

  test "a bounded browse is orders of magnitude smaller than the same unbounded browse",
       %{conn: conn} do
    unbounded = browse(conn, [])
    bounded = browse(scoped_conn(), bodyChars: "1000")

    assert unbounded.status == 200
    assert bounded.status == 200

    big = byte_size(unbounded.resp_body)
    small = byte_size(bounded.resp_body)

    # DISCRIMINATION CONTROL: the unbounded browse really is the heavy one —
    # without this the ratio below could be two small responses agreeing.
    assert big > 500_000, "expected an unbounded browse to be heavy, got #{big} bytes"
    assert small < big / 10, "bodyChars=1000 must cut the payload by >10x: #{small} vs #{big}"

    # Both answered the SAME corpus — the bound cut payload, not hits.
    assert length(Jason.decode!(unbounded.resp_body)["documents"]) ==
             length(Jason.decode!(bounded.resp_body)["documents"])
  end

  test "the bounded tree is a whole-block document prefix, and says it was cut",
       %{conn: conn} do
    unbounded = Jason.decode!(browse(conn, []).resp_body)["documents"]
    bounded = Jason.decode!(browse(scoped_conn(), bodyChars: "1000").resp_body)["documents"]

    by_id = Map.new(unbounded, &{&1["_id"], &1})

    for hit <- bounded do
      whole = Map.fetch!(by_id, hit["_id"])
      kept = hit["blocks"]
      full = whole["blocks"]

      assert length(full) == @blocks_per_doc
      assert length(kept) < length(full)
      # A PREFIX, in document order — every kept block is byte-identical to the
      # block that stood in that position before the bound.
      assert kept == Enum.take(full, length(kept))
      # 400 prose chars/block ⇒ 3 blocks is the smallest prefix reaching 1000.
      assert length(kept) == 3
      assert hit["_bodyTruncated"] == true
      # The bound touches prose only; the projected scalars are untouched.
      assert hit["title"] == whole["title"]
      assert hit["excerpt"] == whole["excerpt"]
    end
  end

  test "no ?bodyChars= is byte-identical to before — the bound is opt-in", %{conn: conn} do
    a = browse(conn, [])
    b = browse(scoped_conn(), bodyChars: "")

    assert a.resp_body |> Jason.decode!() |> Map.drop(["ms", "searchEventId"]) ==
             b.resp_body |> Jason.decode!() |> Map.drop(["ms", "searchEventId"])

    for hit <- Jason.decode!(a.resp_body)["documents"] do
      refute Map.has_key?(hit, "_bodyTruncated")
      assert length(hit["blocks"]) == @blocks_per_doc
    end
  end

  test "a cap large enough for the whole document leaves it whole and unflagged",
       %{conn: conn} do
    resp = browse(conn, bodyChars: "1000000")

    for hit <- Jason.decode!(resp.resp_body)["documents"] do
      assert length(hit["blocks"]) == @blocks_per_doc
      refute Map.has_key?(hit, "_bodyTruncated")
    end
  end

  test "a malformed ?bodyChars= is a 400, never an unbounded 200", %{conn: conn} do
    for bad <- ["abc", "-1", "1.5", "1_000"] do
      resp = browse(scoped_conn(), bodyChars: bad)

      assert resp.status == 400, "expected 400 for bodyChars=#{bad}, got #{resp.status}"
      body = Jason.decode!(resp.resp_body)
      # The §9 envelope, not a bare string: same shape an unsupported
      # ?perspective already answers with, so one parser reads both.
      assert body["error"]["code"] == "malformed"
      # The refusal names the grammar, so the caller can fix the typo.
      assert body["error"]["message"] =~ "non-negative integer"
      assert body["error"]["details"]["parameter"] == "bodyChars"
      assert body["error"]["details"]["received"] == bad
      # request_id is what a bare-string body used to drop on the floor.
      assert is_binary(body["error"]["request_id"])
    end

    # CONTROL: the same request with a well-formed cap is served — the 400s
    # above are about the VALUE, not about the parameter being unroutable.
    assert browse(conn, bodyChars: "1000").status == 200
  end

  test "bodyChars=0 ships no prose at all", %{conn: conn} do
    resp = browse(conn, bodyChars: "0")

    for hit <- Jason.decode!(resp.resp_body)["documents"] do
      assert hit["blocks"] == []
      assert hit["_bodyTruncated"] == true
      assert hit["title"] =~ "Bodycharsuniq"
    end
  end
end
