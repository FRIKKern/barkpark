defmodule Barkpark.Media.Delivery.RetrieverTest do
  # DataCase because build_text_filter internally calls
  # Barkpark.Content.resolve_read_dataset_id, which may touch the DB to look up
  # the Default project when no workspace_id is in scope.  We keep async: false
  # to be safe (same pattern as asset_metadata_tenancy_test.exs which also
  # exercises the tenancy/scope path).
  use Barkpark.DataCase, async: false

  import Ecto.Query
  alias Barkpark.Media.Delivery.Retriever
  alias Barkpark.Media.Storage.MediaFile

  @dataset "production"
  @config %{}

  # ── build_text_filter ──────────────────────────────────────────────────────

  test "returns nil when parsed is empty (no terms, no excludes)" do
    assert Retriever.build_text_filter(@dataset, %{}, @config) == nil
  end

  test "returns nil when all term lists are explicitly empty and no excludes" do
    parsed = %{terms: [], phrases: [], prefixes: [], raw: ""}
    assert Retriever.build_text_filter(@dataset, parsed, @config) == nil
  end

  test "returns an Ecto.Query struct when parsed includes non-empty terms" do
    # raw: "" prevents Synonyms.search_terms DB call; terms list alone drives the filter.
    parsed = %{terms: ["cat"], phrases: [], prefixes: [], raw: ""}
    result = Retriever.build_text_filter(@dataset, parsed, @config)

    assert %Ecto.Query{} = result
    # The from clause is MediaFile (aliased :media in the query)
    assert result.from.source == {MediaFile.__schema__(:source), MediaFile}
  end

  test "returns an Ecto.Query struct when only excludes are present" do
    parsed = %{excludes: ["dog"], raw: ""}
    result = Retriever.build_text_filter(@dataset, parsed, @config)

    assert %Ecto.Query{} = result
  end

  test "strict vs relaxed opts produce structurally distinct queries" do
    parsed = %{terms: ["landscape"], raw: ""}
    strict = Retriever.build_text_filter(@dataset, parsed, @config, relaxed: false)
    relaxed = Retriever.build_text_filter(@dataset, parsed, @config, relaxed: true)

    assert %Ecto.Query{} = strict
    assert %Ecto.Query{} = relaxed
    # The embedded similarity threshold literal (0.25 vs 0.15) makes them differ
    refute inspect(strict) == inspect(relaxed)
  end

  # ── apply_to_query ─────────────────────────────────────────────────────────

  test "apply_to_query returns the original query unchanged when parsed is empty" do
    base = from(m in MediaFile, select: m.id)
    result = Retriever.apply_to_query(base, @dataset, %{}, @config)

    assert inspect(result) == inspect(base)
  end

  test "apply_to_query wraps query with a subquery where clause when terms present" do
    base = from(m in MediaFile, select: m.id)
    parsed = %{terms: ["sunset"], raw: ""}
    result = Retriever.apply_to_query(base, @dataset, parsed, @config)

    assert %Ecto.Query{} = result
    # A subquery-based where clause was appended — inspect diverges from base
    refute inspect(result) == inspect(base)
    assert inspect(result) =~ "in subquery"
  end
end
