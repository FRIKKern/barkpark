defmodule Barkpark.Search.RecoveryCostTest do
  @moduledoc """
  task-722697f4650b2a21 — the recovery passes of the default search path.

    * A pass that matches nothing runs no ranking statement. The zero-hit
      chain (strict, widened, any word) used to evaluate every empty match
      twice: once to count it, once to rank an empty page.
    * The whole-title typo arm (`%`) reads the GiST trigram index of
      migration 20261015170000, the only index on its expression, and still
      finds a near-miss title.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Search.{DocumentsRetriever, QueryParser}

  @ds "recovery-cost-test"

  setup do
    ws = create_workspace!()
    proj = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "post", "visibility" => "public"},
        @ds,
        scope
      )

    {:ok, scope: scope}
  end

  defp seed!(scope, title) do
    doc_id = "rc-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document("post", %{"doc_id" => doc_id, "title" => title}, @ds, scope)

    {:ok, _} = Content.publish_document(doc_id, "post", @ds, scope)
    doc_id
  end

  # Every SQL statement this process sends while `fun` runs.
  defp statements(fun) do
    test_pid = self()
    handler = "recovery-cost-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measurements, meta, _ ->
        if self() == test_pid, do: send(test_pid, {:sql, meta.query})
      end,
      nil
    )

    try do
      result = fun.()
      {result, collect([])}
    after
      :telemetry.detach(handler)
    end
  end

  defp collect(acc) do
    receive do
      {:sql, sql} -> collect([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ranking?(sql), do: sql =~ "ORDER BY" and sql =~ ~s("doc_id")

  test "a search that matches nothing in any pass runs no ranking statement", %{scope: scope} do
    seed!(scope, "Fjellvandring om sommeren")

    {{docs, total, meta}, sql} =
      statements(fn ->
        Content.search_documents("qzxwv plokjm", @ds, [type: "post"] ++ scope)
      end)

    assert docs == []
    assert total == 0
    assert meta.recovery == nil

    # The strict, widened and any-word passes each counted their match.
    assert Enum.count(sql, &(&1 =~ "GROUPING SETS")) >= 3
    assert Enum.filter(sql, &ranking?/1) == []
  end

  test "a pass that finds documents still ranks them", %{scope: scope} do
    id = seed!(scope, "Fjellvandring om sommeren")

    {{docs, total, _meta}, sql} =
      statements(fn ->
        Content.search_documents("fjellvandring", @ds, [type: "post"] ++ scope)
      end)

    assert total == 1
    assert Enum.map(docs, & &1.doc_id) == [id]
    # One hit is a thin result, so the widened pass runs and ranks too.
    assert Enum.count(sql, &ranking?/1) >= 1
  end

  test "the widened pass finds a near-miss title through the whole-title typo arm",
       %{scope: scope} do
    id = seed!(scope, "Basis")
    _other = seed!(scope, "Fjellvandring om sommeren")

    parsed = QueryParser.parse("basus")

    {docs, total, _} =
      DocumentsRetriever.search(@ds, parsed, %{}, [type: "post", relaxed: true] ++ scope)

    assert total == 1
    assert Enum.map(docs, & &1.doc_id) == [id]
  end

  test "the GiST index covers exactly the expression of the whole-title typo arm" do
    %{rows: [[indexdef]]} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE indexname = 'documents_search_label_trgm_gist_idx'"
      )

    assert indexdef =~ "USING gist"
    assert indexdef =~ "gist_trgm_ops"

    # The planner matches an index by expression. Build the arm the way the
    # retriever does and ask the planner for its plan.
    {:ok, plan} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL enable_seqscan = off")
        Repo.query!("SET LOCAL pg_trgm.similarity_threshold = 0.15")

        %{rows: rows} =
          Repo.query!(
            "EXPLAIN SELECT id FROM documents d " <>
              "WHERE coalesce(d.search_title, nullif(d.title, ''), '') % $1",
            ["basis"]
          )

        rows |> List.flatten() |> Enum.join("\n")
      end)

    assert plan =~ "documents_search_label_trgm_gist_idx"
  end

  test "the retriever's typo arm uses the indexed expression", %{scope: scope} do
    seed!(scope, "Basis")

    {_result, sql} =
      statements(fn ->
        DocumentsRetriever.search(
          @ds,
          QueryParser.parse("basus"),
          %{},
          [type: "post", relaxed: true] ++ scope
        )
      end)

    assert Enum.any?(
             sql,
             &(&1 =~ ~s|coalesce(d0."search_title", nullif(d0."title", ''), '') %|)
           ),
           "expected the % arm on the GiST expression in:\n#{Enum.join(sql, "\n")}"
  end
end
