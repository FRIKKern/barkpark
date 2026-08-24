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

  describe "_type reads the type COLUMN (task-20c081f70cb8d85e)" do
    test "filtering on the type every row has stops answering zero", %{conn: conn} do
      # THE DEFECT, in one line: on /query/:ds/post, `filter[_type][eq]=post`
      # returned 0 of 3. `_type` is a promoted column (documents.type, NOT NULL)
      # that the API echoes in every document it returns, so this reads like the
      # most ordinary query there is — and it read `content->>'_type'`, a key no
      # document carries. A board audit reading that zero writes down "absent"
      # for a type that is fully present.
      assert length(rows(conn, "?filter[_type][eq]=post")) == 3
      assert length(rows(conn, "?filter[_type][in]=post,article")) == 3
    end

    test "a NON-matching _type is still an honest empty — the fix is not a rubber stamp",
         %{conn: conn} do
      # The negative arm. Making a silently-empty filter return rows is only a
      # fix if it still returns NOTHING when it should: a clause that ignored
      # its value would pass the test above and be just as wrong.
      assert rows(conn, "?filter[_type][eq]=article") == []
      assert rows(conn, "?filter[_type][neq]=post") == []
      assert rows(conn, "?filter[_type][startsWith]=zz") == []
      assert length(rows(conn, "?filter[_type][nin]=article")) == 3
    end

    test "promoting the BARE `type` spelling cannot break a content filter, because a " <>
           "`type` content key is impossible",
         %{conn: conn} do
      # The safety argument for aliasing bare `type` to the column, asserted
      # rather than assumed — the first draft of this fix assumed the opposite
      # (that `type` was a plausible content key, e.g. a `place` with
      # "type": "park") and left the bare spelling silently broken to protect
      # callers who cannot exist.
      #
      # `type` is on Writer's @reserved_in (writer.ex:1291) and Map.drop-ped
      # from content on every write (writer.ex:1310), so a document CANNOT
      # carry it in content. Write one that tries:
      {:ok, _} =
        Content.create_document(
          "post",
          %{"_id" => "t1", "title" => "Eps", "type" => "park", "mood" => "rainy"},
          @ds
        )

      {:ok, _} = Content.publish_document("t1", "post", @ds)

      # The unreserved key survived; the reserved one did not.
      assert rows(conn, "?filter[mood][eq]=rainy") |> Enum.map(& &1["_id"]) == ["t1"]
      # "park" was dropped, so there was never a JSONB match to preserve.
      assert rows(conn, "?filter[type][eq]=park") == []
      # And the column value is what both spellings now answer.
      assert length(rows(conn, "?filter[type][eq]=post")) == 4
      assert length(rows(conn, "?filter[_type][eq]=post")) == 4
    end

    test "the op table refuses what a type name cannot answer", %{conn: conn} do
      # Comparison ops are a category error on a type name, and `is` could only
      # ever mean "no rows" on a NOT NULL column — so both are REFUSED, not
      # silently widened. Same shape as doc_id/_id.
      #
      # The refusal is RAISED from the chokepoint (Query.apply_filter_map/2), not
      # returned by the controller: `invalid_filter_op/1` only checks the GLOBAL
      # op vocabulary, and `gt` is in it. `InvalidFilterError` implements
      # Plug.Exception with status 400, so the wire answer is a 400 — which is
      # what `assert_error_sent` pins. A plain `json_response(400)` would red
      # here even though production behaviour is correct.
      for field <- ~w(type _type), op <- ~w(gt gte lt lte is) do
        refute op in Query.supported_ops_for(field),
               "#{field}/#{op} must not be a declared op"
      end

      # The comparison ops reach the chokepoint and RAISE.
      for field <- ~w(type _type), op <- ~w(gt gte lt lte) do
        assert_error_sent(400, fn ->
          get(conn, "/v1/data/query/#{@ds}/post?filter[#{field}][#{op}]=x")
        end)
      end

      # `is` never gets that far: the controller's own VALUE guard fires first
      # ("takes \"null\" or \"notnull\"") and returns a normal 400 body. Two
      # routes to the same status, and the test says which is which rather than
      # papering over the difference — `assert_error_sent` reds on a clean 400,
      # and `json_response` reds on a raise, so neither spelling covers both.
      for field <- ~w(type _type) do
        assert conn
               |> get("/v1/data/query/#{@ds}/post?filter[#{field}][is]=x")
               |> json_response(400)
      end
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
        {"_id", "contains", "f", 3},
        # task-20c081f70cb8d85e — the last member of the class. Every one of
        # these returned 0 before the `_type` column clauses existed, on a route
        # where all 3 rows match.
        {"type", "eq", "post", 3},
        {"_type", "eq", "post", 3},
        {"_type", "contains", "os", 3},
        {"_type", "startsWith", "po", 3},
        {"_type", "endsWith", "ost", 3}
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
