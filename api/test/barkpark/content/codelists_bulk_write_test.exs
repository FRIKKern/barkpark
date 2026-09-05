defmodule Barkpark.Content.CodelistsBulkWriteTest do
  @moduledoc """
  `register/3` runs its whole value payload inside ONE `Repo.transaction`,
  so the number of statements it issues is a correctness property, not a
  performance nicety: the bundled Thema snapshot carries 9187 codes with a
  label each, and a per-row writer turns that into ~18,400 round trips
  under a single connection deadline. A loaded host overran that deadline
  on 2026-08-19 and Postgres cancelled the statement mid-write
  (`ERROR 57014 (query_canceled)`), rolling the whole seed back while the
  server carried on serving 200s.

  Synchronous: the statement counter attaches to the node-global
  `[:barkpark, :repo, :query]` telemetry event, and several `async: true`
  suites write `codelist_values` of their own. `async: false` alone was never
  enough — it fences sibling TEST processes, not the application's own
  supervision tree — so the count is lineage-scoped through
  `Barkpark.QueryCounter`.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.QueryCounter

  alias Barkpark.Content.Codelists
  alias Barkpark.Content.Codelists.{Translation, Value}

  # 300 parents x 1 child, one label each => 600 values + 600 translations.
  # The per-row writer issued 1200 INSERTs for this payload.
  @parents 300

  defp payload do
    for i <- 1..@parents do
      %{
        code: "P#{i}",
        position: i,
        metadata: %{"depth" => 0},
        translations: [
          %{language: "eng", label: "parent #{i}"},
          %{language: "nob", label: "forelder #{i}"}
        ],
        children: [
          %{
            code: "C#{i}",
            translations: [%{language: "eng", label: "child #{i}"}]
          }
        ]
      }
    end
  end

  # LINEAGE-SCOPED, via the shared `Barkpark.QueryCounter`. The SQL prefix is
  # the only thing that made the old node-global handler look safe — any
  # process in the VM issuing an `INSERT INTO "codelist_value…"` inside the
  # window would have entered this count. Ownership is now decided by process
  # lineage (this test and anything it spawned), so a background writer cannot.
  defp count_inserts(fun) do
    {result, sqls} = QueryCounter.sql(fun)

    inserts =
      Enum.count(sqls, &String.starts_with?(&1, "INSERT INTO \"codelist_value"))

    {result, inserts}
  end

  describe "register/3 — statement count" do
    test "a 1200-row payload writes in a bounded number of INSERT statements" do
      {result, inserts} =
        count_inserts(fn ->
          Codelists.register("onixedit", "onixedit:bulk-shape", %{
            issue: "1",
            name: "Bulk shape",
            values: payload()
          })
        end)

      assert {:ok, _} = result

      assert inserts <= 10,
             "register/3 issued #{inserts} INSERT statements for 600 values + 900 " <>
               "translations; a per-row writer cannot hold the boot-seed deadline"
    end
  end

  describe "register/3 — the batched writer preserves the per-row writer's output" do
    setup do
      {:ok, codelist} =
        Codelists.register("onixedit", "onixedit:bulk-fidelity", %{
          issue: "1",
          name: "Bulk fidelity",
          values: payload()
        })

      %{codelist: codelist}
    end

    test "every value and translation lands", %{codelist: codelist} do
      assert Repo.aggregate(
               from(v in Value, where: v.codelist_id == ^codelist.id),
               :count
             ) == @parents * 2

      assert Repo.aggregate(
               from(t in Translation,
                 join: v in Value,
                 on: v.id == t.codelist_value_id,
                 where: v.codelist_id == ^codelist.id
               ),
               :count
             ) == @parents * 3
    end

    test "children keep their parent_id self-reference", %{codelist: codelist} do
      parent = Repo.get_by!(Value, codelist_id: codelist.id, code: "P7")
      child = Repo.get_by!(Value, codelist_id: codelist.id, code: "C7")

      assert child.parent_id == parent.id
      assert is_nil(parent.parent_id)
    end

    test "position and metadata survive the batch", %{codelist: codelist} do
      parent = Repo.get_by!(Value, codelist_id: codelist.id, code: "P42")

      assert parent.position == 42
      assert parent.metadata == %{"depth" => 0}
    end

    test "timestamps are populated", %{codelist: codelist} do
      value = Repo.get_by!(Value, codelist_id: codelist.id, code: "P1")

      refute is_nil(value.inserted_at)
      refute is_nil(value.updated_at)
    end

    test "lookup/3 still resolves labels through the language chain", %{codelist: _} do
      assert %{value: "P3", label: "forelder 3"} =
               Codelists.lookup("onixedit", "onixedit:bulk-fidelity", "P3")

      assert %{value: "C3", label: "child 3"} =
               Codelists.lookup("onixedit", "onixedit:bulk-fidelity", "C3")
    end

    test "re-registering replaces rather than duplicates", %{codelist: codelist} do
      # Same header row (the upsert only bumps `updated_at`), values replaced.
      {:ok, %{id: same_id}} =
        Codelists.register("onixedit", "onixedit:bulk-fidelity", %{
          issue: "1",
          name: "Bulk fidelity",
          values: payload()
        })

      assert same_id == codelist.id

      assert Repo.aggregate(
               from(v in Value, where: v.codelist_id == ^codelist.id),
               :count
             ) == @parents * 2
    end
  end
end
