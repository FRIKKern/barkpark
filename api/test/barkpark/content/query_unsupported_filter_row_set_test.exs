defmodule Barkpark.Content.QueryUnsupportedFilterRowSetTest do
  @moduledoc """
  task-19b7ca7ff92fb710 (#2b), criterion 5 — the ROW-SET assertion.

  THE ROW'S PREMISE IS ALREADY CLOSED ON MAIN, so the fail-first test its
  criterion 1 asks for cannot be written honestly: `apply_field_op/4`'s
  catch-all no longer reads `do: query`, it raises `InvalidFilterError`
  (content/query.ex), and `apply_filter_map/2` validates the whole map before
  a single clause is built. What criterion 5 asks for IS still available, and
  this file is it.

  WHY A ROW-SET ASSERTION AND NOT A STATUS ASSERTION. The defect was never
  "the wrong status code". A dropped clause returned the UNFILTERED set: a
  caller filtering to one tenant's rows silently received everybody's. A test
  that asserts only `assert_raise` (or only a 400) stays GREEN against an
  implementation that answers 200 with too many rows — which is precisely the
  bug. So this test refuses to be satisfied by a raise alone: it names the row
  the filter EXCLUDED and fails on its presence, with the returned id list in
  the message.

  It is written as an outcome match rather than `assert_raise` for exactly that
  reason. `assert_raise` cannot express "and if you did NOT raise, here is what
  you were not allowed to return".

  MUTATION PROOF (pasted into the row's evidence). TWO mutations, because the
  refusal is doubled and only one of them is the clause the row names:

    * catch-all ALONE restored to `do: query` — this test stays GREEN. That is
      not a hole in the test, it is the second guard doing its job: the
      `validate_filter_map/1` pre-pass in `apply_filter_map/2` refuses the map
      before any clause is built, so the catch-all is unreachable. Worth
      knowing before someone "simplifies" one of the two away.
    * BOTH restored (catch-all to `do: query` AND the pre-pass raise removed) —
      the historical silence, exactly. This test REDS on the row set:
      `filter[title][bogus]` returns both documents, including the one the
      clause excluded.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.InvalidFilterError
  alias Barkpark.Content.Query

  setup do
    # Unique per run: this database is shared with every other agent's suite.
    dataset = "s2_rowset_#{System.unique_integer([:positive])}"
    type = "s2rowsetpost"

    Content.upsert_schema(
      %{"name" => type, "title" => "S2 RowSet Post", "visibility" => "public", "fields" => []},
      dataset
    )

    %{dataset: dataset, type: type}
  end

  defp doc!(ctx, id, title) do
    {:ok, _} = Content.create_document(ctx.type, %{"_id" => id, "title" => title}, ctx.dataset)
    {:ok, doc} = Content.publish_document(id, ctx.type, ctx.dataset)
    doc
  end

  defp ids(rows), do: rows |> Enum.map(& &1.doc_id) |> Enum.sort()

  defp list(ctx, filter_map) do
    Query.list_documents(ctx.type, ctx.dataset, perspective: :raw, filter_map: filter_map)
  end

  # Either the read was REFUSED (the contract) or it RETURNED rows (the defect).
  # Returning the outcome instead of asserting on it is what lets the caller
  # assert on the rows in the second case.
  defp outcome(ctx, filter_map) do
    {:returned, list(ctx, filter_map)}
  rescue
    e in InvalidFilterError -> {:refused, e}
  end

  defp assert_never_over_returns(ctx, filter_map, excluded_id, expected_op) do
    case outcome(ctx, filter_map) do
      {:refused, e} ->
        assert e.op == expected_op

      {:returned, rows} ->
        returned = ids(rows)

        refute excluded_id in returned,
               "OVER-RETURN on #{inspect(filter_map)}: the clause was dropped and the read " <>
                 "returned #{inspect(returned)} — including #{inspect(excluded_id)}, the row " <>
                 "the filter excluded. A caller filtering to one tenant's rows just received " <>
                 "everybody's."

        flunk(
          "an unsupported filter clause was neither refused nor applied; it returned " <>
            "#{inspect(returned)}"
        )
    end
  end

  describe "an unsupported filter clause never yields the rows it excluded" do
    test "an unknown OP does not return the excluded row", ctx do
      doc!(ctx, "kept", "Alpha")
      doc!(ctx, "excluded", "Beta")

      # CONTROL — the same read with a SUPPORTED op really does exclude
      # "excluded". Without this, a full row set below could be explained by a
      # fixture that never filtered anything, and the assertion would be vacuous.
      assert ids(list(ctx, %{"title" => %{"eq" => "Alpha"}})) == ["kept"]

      assert_never_over_returns(ctx, %{"title" => %{"bogus" => "Alpha"}}, "excluded", "bogus")
    end

    test "an unknown FIELD narrows to nothing — it never widens to everything", ctx do
      doc!(ctx, "kept", "Alpha")
      doc!(ctx, "excluded", "Beta")

      # An unknown field name is NOT refused, and should not be: every filter
      # key that is not a Document column is looked up under `content`, and a
      # content key the corpus happens not to carry yet is a legitimate query,
      # not a typo the builder can distinguish. So the contract here is the
      # weaker one — it may return nothing, it may never return the row the
      # clause excluded.
      case outcome(ctx, %{"no_such_column" => %{"eq" => "Alpha"}}) do
        {:refused, e} ->
          assert e.op == "eq"

        {:returned, rows} ->
          returned = ids(rows)

          refute "excluded" in returned,
                 "OVER-RETURN on an unknown field: returned #{inspect(returned)}, which " <>
                   "includes the row the clause excluded"
      end
    end

    test "a value-matched op with an out-of-vocabulary VALUE does not match everything", ctx do
      doc!(ctx, "kept", "Alpha")
      doc!(ctx, "excluded", "Beta")

      # `is` has SQL arms for "null"/"notnull" only. `is=published` is a
      # plausible equality typo whose clause used to fall through the catch-all
      # and match every row in the dataset.
      assert_never_over_returns(ctx, %{"status" => %{"is" => "published"}}, "excluded", "is")
    end

    test "a field-restricted op used on the wrong field does not return the excluded row", ctx do
      doc!(ctx, "kept", "Alpha")
      doc!(ctx, "excluded", "Beta")

      # `starts_with` has a clause on the id column ONLY.
      assert_never_over_returns(
        ctx,
        %{"title" => %{"starts_with" => "Alph"}},
        "excluded",
        "starts_with"
      )
    end

    test "a count cannot over-report either — the same clause, the same refusal", ctx do
      doc!(ctx, "kept", "Alpha")
      doc!(ctx, "excluded", "Beta")

      filtered =
        Query.count_documents(ctx.type, ctx.dataset,
          perspective: :raw,
          filter_map: %{"title" => %{"eq" => "Alpha"}}
        )

      assert filtered == 1

      counted =
        try do
          {:returned,
           Query.count_documents(ctx.type, ctx.dataset,
             perspective: :raw,
             filter_map: %{"title" => %{"bogus" => "Alpha"}}
           )}
        rescue
          e in InvalidFilterError -> {:refused, e}
        end

      case counted do
        {:refused, e} ->
          assert e.op == "bogus"

        {:returned, n} ->
          flunk(
            "OVER-COUNT: an unsupported clause counted #{n} rows where the equivalent " <>
              "supported filter counts #{filtered}"
          )
      end
    end
  end

  describe "NEGATIVE ARM — supported filters are unchanged" do
    test "every documented op still filters, and none of them raise", ctx do
      doc!(ctx, "kept", "Alpha")
      doc!(ctx, "excluded", "Beta")

      assert ids(list(ctx, %{"title" => %{"eq" => "Alpha"}})) == ["kept"]
      assert ids(list(ctx, %{"title" => "Alpha"})) == ["kept"]
      assert ids(list(ctx, %{"title" => %{"in" => ["Alpha"]}})) == ["kept"]
      assert ids(list(ctx, %{"title" => %{"contains" => "lph"}})) == ["kept"]
      assert ids(list(ctx, %{"doc_id" => %{"starts_with" => "kep"}})) == ["kept"]
      assert ids(list(ctx, %{})) == ["excluded", "kept"]
    end
  end
end
