defmodule BarkparkWeb.Contract.PerFieldOpTableTest do
  @moduledoc """
  `gfr-w1-per-field-op-table` — a valid filter op on a COLUMN-BACKED field
  stops silently returning zero rows.

  ## The defect this pins

  `apply_field_op/4`'s promoted-column clauses were PARTIAL. An op with no
  clause for that column fell through to the generic arm and read
  `content->>'<name>'` — a key that does not exist on a column-backed field —
  so the query ran happily and returned 0 rows at 200 OK. Measured on the
  unpatched tree against this 3-document corpus:

      filter[status][contains]=publi   -> 0 rows   (should be 3)
      filter[status][startsWith]=pub   -> 0 rows   (should be 3)
      filter[doc_id][startsWith]=f     -> 0 rows   (should be 3)
      filter[doc_id][contains]=1       -> 0 rows   (should be 1)
      filter[_id][contains]=f          -> 0 rows   (should be 3)
      filter[title][contains]=lph      -> 1 row    (control: title always worked)

  Strictness could never catch these: the op IS documented, a legitimate generic
  clause DOES exist, and nothing raises.

  ## Widened vs refused

  Widened where the op is meaningful on the column (the customer's actual ask);
  refused where it is a category error — string ops on a timestamp, comparison
  ops on `status`, `is` on the NOT NULL `doc_id`. A refusal is honest; a silent
  0 was not.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Query

  @ds "pfot_http"

  setup do
    Content.upsert_schema(
      %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
      @ds
    )

    for {id, title} <- [{"f1", "Alpha"}, {"f2", "Beta"}, {"f3", "Gamma"}] do
      {:ok, _} = Content.create_document("post", %{"_id" => id, "title" => title}, @ds)
      {:ok, _} = Content.publish_document(id, "post", @ds)
    end

    :ok
  end

  defp rows(conn, qs) do
    %{"result" => body} =
      conn |> get("/v1/data/query/#{@ds}/post" <> qs) |> json_response(200)

    body["documents"]
  end

  describe "column-backed fields answer their documented string ops" do
    test "status contains / startsWith / endsWith read the COLUMN, not JSONB", %{conn: conn} do
      assert length(rows(conn, "?filter[status][contains]=publi")) == 3
      assert length(rows(conn, "?filter[status][startsWith]=pub")) == 3
      assert length(rows(conn, "?filter[status][endsWith]=shed")) == 3
      # A value that matches nothing must still be an HONEST zero.
      assert rows(conn, "?filter[status][contains]=zzzz") == []
    end

    test "doc_id PREFIX filtering is reachable — it was unreachable by any spelling",
         %{conn: conn} do
      ids = rows(conn, "?filter[doc_id][startsWith]=f") |> Enum.map(& &1["_id"]) |> Enum.sort()
      assert ids == ["f1", "f2", "f3"]

      assert rows(conn, "?filter[doc_id][contains]=1") |> Enum.map(& &1["_id"]) == ["f1"]
      assert rows(conn, "?filter[doc_id][endsWith]=3") |> Enum.map(& &1["_id"]) == ["f3"]
    end

    test "_id inherits doc_id's table through the alias", %{conn: conn} do
      assert length(rows(conn, "?filter[_id][contains]=f")) == 3
    end

    test "title — the control — was never broken and still is not", %{conn: conn} do
      assert rows(conn, "?filter[title][contains]=lph") |> Enum.map(& &1["title"]) == ["Alpha"]
    end
  end

  describe "an op with no clause for THIS column is refused, not silently empty" do
    test "a string op on a timestamp column refuses instead of returning 0 rows", %{conn: conn} do
      assert_error_sent(400, fn ->
        get(conn, "/v1/data/query/#{@ds}/post?filter[_createdAt][contains]=20")
      end)
    end

    test "a comparison op on status refuses instead of returning 0 rows", %{conn: conn} do
      assert_error_sent(400, fn ->
        get(conn, "/v1/data/query/#{@ds}/post?filter[status][gt]=a")
      end)
    end

    test "the refusal NEVER names the field — the table decides, the message stays blind" do
      e =
        assert_raise Barkpark.Content.InvalidFilterError, fn ->
          Query.list_documents("post", @ds,
            perspective: :raw,
            filter_map: %{"_createdAt" => %{"contains" => "20"}}
          )
        end

      # The row asked the message to enumerate this field's ops. It must not:
      # naming the field tells an unauthorised caller the field EXISTS, and
      # `query_test.exs` + charter D13 Tier B pin that. The TABLE refuses; the
      # MESSAGE keeps printing the documented global set.
      refute e.message =~ "_createdAt"
      assert e.message =~ "contains"
      assert e.message =~ Enum.join(Query.valid_filter_ops(), ", ")
    end
  end

  describe "the schemaless boundary holds" do
    test "an arbitrary content field still filters through the generic arm", %{conn: conn} do
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "f4", "title" => "Delta", "mood" => "sunny"},
          @ds
        )

      {:ok, _} = Content.publish_document("f4", "post", @ds)

      assert rows(conn, "?filter[mood][eq]=sunny") |> Enum.map(& &1["_id"]) == ["f4"]
      assert length(rows(conn, "?filter[mood][contains]=unn")) == 1
      # An unknown content field is NOT an error — it is an honest empty match.
      assert rows(conn, "?filter[not_a_field][eq]=x") == []
    end
  end

  describe "the table and the clauses are pinned to each other" do
    test "EVERY declared (field, op) pair reaches its column — none silently reads JSONB",
         %{conn: conn} do
      # A declared pair must be able to MATCH. If a pair is in the table with no
      # clause behind it, it falls to the generic arm and can only ever return
      # 0 — which is exactly the defect. Each probe below is chosen to match.
      probes = [
        {"title", "eq", "Alpha", 1},
        {"title", "contains", "lph", 1},
        {"title", "startsWith", "Al", 1},
        {"title", "endsWith", "pha", 1},
        {"status", "eq", "published", 3},
        {"status", "contains", "publi", 3},
        {"status", "startsWith", "pub", 3},
        {"status", "endsWith", "shed", 3},
        {"doc_id", "eq", "f1", 1},
        {"doc_id", "contains", "1", 1},
        {"doc_id", "startsWith", "f", 3},
        {"doc_id", "endsWith", "3", 1},
        {"_id", "contains", "f", 3}
      ]

      for {field, op, value, expected} <- probes do
        assert op in Query.supported_ops_for(field),
               "#{field}/#{op} is probed but not declared in the capability table"

        got = length(rows(conn, "?filter[#{field}][#{op}]=#{value}"))

        assert got == expected,
               "#{field}[#{op}]=#{value} returned #{got}, expected #{expected} — " <>
                 "a declared pair that returns 0 is reading the wrong column"
      end
    end
  end
end
