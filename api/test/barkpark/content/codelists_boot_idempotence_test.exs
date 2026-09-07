defmodule Barkpark.Content.CodelistsBootIdempotenceTest do
  @moduledoc """
  `register/3` is called by the boot seeders on EVERY application start, with
  the SAME bundled snapshot at the SAME issue, and Barkpark auto-deploys on
  merge. Until this suite, that meant a `DELETE` of the list's values plus a
  full re-INSERT of the tree on every restart — ~28k rows for the local
  registry — for a payload that had not changed a byte.

  The property under test is stated by the task row: a boot whose snapshot
  content and issue are unchanged performs NO delete/insert on
  `codelist_values`, proven by the values' `id`/`inserted_at` being stable
  across two consecutive `register/3` calls.

  A test that only proved the skip would be satisfied by a function that
  always skips, which is the FAR more dangerous failure: a codelist silently
  frozen at a stale snapshot while OnixEdit's Thema field reads it. So the
  second describe block is the load-bearing one — it defeats the skip along
  every axis the writer persists, and the third guarantees the fresh-install
  arm still seeds.

  Synchronous because the statement census attaches node-global telemetry;
  ownership is lineage-scoped through `Barkpark.QueryCounter`, exactly as
  `codelists_bulk_write_test.exs` does.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Codelists
  alias Barkpark.Content.Codelists.Value
  alias Barkpark.QueryCounter

  @plugin "onixedit"

  defp payload do
    [
      %{
        code: "P1",
        position: 1,
        metadata: %{"depth" => 0},
        translations: [
          %{language: "eng", label: "parent one"},
          %{language: "nob", label: "forelder en", description: "beskrivelse"}
        ],
        children: [
          %{code: "C1", position: 10, translations: [%{language: "eng", label: "child one"}]},
          %{code: "C2", position: 11, translations: [%{language: "eng", label: "child two"}]}
        ]
      },
      %{
        code: "P2",
        position: 2,
        translations: [%{language: "eng", label: "parent two"}]
      }
    ]
  end

  defp register(list_id, values) do
    Codelists.register(@plugin, list_id, %{issue: "1", name: "Idempotence", values: values})
  end

  # The DETECTOR. `QueryCounter.sql/1` returns every statement issued inside
  # the block by this test or anything it spawned; the boot seeders' own
  # background writes cannot enter it.
  defp value_writes(fun) do
    {result, sqls} = QueryCounter.sql(fun)

    writes =
      Enum.filter(sqls, fn sql ->
        String.starts_with?(sql, "INSERT INTO \"codelist_value") or
          String.starts_with?(sql, "DELETE FROM \"codelist_value")
      end)

    {result, writes}
  end

  defp fingerprint(codelist_id) do
    Value
    |> where([v], v.codelist_id == ^codelist_id)
    |> select([v], {v.code, v.id, v.inserted_at})
    |> Repo.all()
    |> Enum.sort()
  end

  defp assert_rebuilt(ctx, mutated, axis) do
    {result, writes} = value_writes(fn -> register(ctx.list_id, mutated) end)

    registered? = match?({:ok, _}, result)
    assert registered?, "register/3 failed on the #{axis} mutation: #{inspect(result)}"

    refute writes == [],
           "a snapshot that changed its #{axis} was SKIPPED — the short circuit " <>
             "cannot be defeated, which means a stale codelist can never be repaired"

    refute fingerprint(ctx.codelist.id) == ctx.before,
           "the #{axis} mutation left every value's id and inserted_at untouched"
  end

  describe "an unchanged snapshot at an unchanged issue" do
    setup do
      list_id = "onixedit:idem-unchanged-#{System.unique_integer([:positive])}"
      {:ok, codelist} = register(list_id, payload())
      %{list_id: list_id, codelist: codelist, before: fingerprint(codelist.id)}
    end

    test "issues no DELETE and no INSERT on codelist_values", ctx do
      {result, writes} = value_writes(fn -> register(ctx.list_id, payload()) end)

      registered? = match?({:ok, _}, result)
      assert registered?, "the second register/3 did not succeed: #{inspect(result)}"

      assert writes == [],
             "a re-register of an identical snapshot still wrote to codelist_values: " <>
               inspect(writes)
    end

    test "every value keeps its id and inserted_at", ctx do
      {:ok, _} = register(ctx.list_id, payload())

      assert fingerprint(ctx.codelist.id) == ctx.before
    end

    test "the fingerprint the test compares is not vacuously empty", ctx do
      # A non-vacuity guard on the guard: if `fingerprint/1` returned [] for
      # both boots the previous test would pass while proving nothing.
      assert length(ctx.before) == 4
    end
  end

  # THE ARM THAT MATTERS. A short circuit that always skips passes every test
  # above. Each of these mutates ONE thing the writer persists and demands the
  # rebuild still happens.
  describe "a changed snapshot still rebuilds" do
    setup do
      list_id = "onixedit:idem-changed-#{System.unique_integer([:positive])}"
      {:ok, codelist} = register(list_id, payload())
      %{list_id: list_id, codelist: codelist, before: fingerprint(codelist.id)}
    end

    test "a value is added", ctx do
      mutated = payload() ++ [%{code: "P3", translations: [%{language: "eng", label: "three"}]}]
      assert_rebuilt(ctx, mutated, "value set (addition)")
    end

    test "a value is removed", ctx do
      mutated = Enum.reject(payload(), &(&1.code == "P2"))
      assert_rebuilt(ctx, mutated, "value set (removal)")
    end

    test "a label changes", ctx do
      mutated =
        Enum.map(payload(), fn
          %{code: "P2"} = value ->
            %{value | translations: [%{language: "eng", label: "parent two REVISED"}]}

          value ->
            value
        end)

      assert_rebuilt(ctx, mutated, "translation label")
    end

    test "a translation description changes", ctx do
      mutated =
        Enum.map(payload(), fn
          %{code: "P1"} = value ->
            %{
              value
              | translations: [
                  %{language: "eng", label: "parent one"},
                  %{language: "nob", label: "forelder en", description: "ny beskrivelse"}
                ]
            }

          value ->
            value
        end)

      assert_rebuilt(ctx, mutated, "translation description")
    end

    test "a translation is dropped", ctx do
      mutated =
        Enum.map(payload(), fn
          %{code: "P1"} = value ->
            %{value | translations: [%{language: "eng", label: "parent one"}]}

          value ->
            value
        end)

      assert_rebuilt(ctx, mutated, "translation set")
    end

    test "a position changes", ctx do
      mutated =
        Enum.map(payload(), fn
          %{code: "P2"} = value -> %{value | position: 99}
          value -> value
        end)

      assert_rebuilt(ctx, mutated, "position")
    end

    test "metadata changes", ctx do
      mutated =
        Enum.map(payload(), fn
          %{code: "P1"} = value -> %{value | metadata: %{"depth" => 1}}
          value -> value
        end)

      assert_rebuilt(ctx, mutated, "metadata")
    end

    test "a child is re-parented", ctx do
      [p1, p2] = payload()
      {[c1], p1_children} = Enum.split_with(p1.children, &(&1.code == "C1"))
      mutated = [%{p1 | children: p1_children}, Map.put(p2, :children, [c1])]

      assert_rebuilt(ctx, mutated, "hierarchy")
    end

    test "the DB rows actually reflect the new snapshot, not just new ids", ctx do
      mutated =
        Enum.map(payload(), fn
          %{code: "P2"} = value ->
            %{value | translations: [%{language: "eng", label: "parent two REVISED"}]}

          value ->
            value
        end)

      {:ok, _} = register(ctx.list_id, mutated)

      assert %{value: "P2", label: "parent two REVISED"} =
               Codelists.lookup(@plugin, ctx.list_id, "P2")
    end
  end

  describe "the fresh-install arm" do
    test "a codelist that has never been seeded seeds" do
      list_id = "onixedit:idem-fresh-#{System.unique_integer([:positive])}"

      {result, writes} = value_writes(fn -> register(list_id, payload()) end)

      registered? = match?({:ok, _}, result)
      assert registered?, "a first-ever register/3 failed: #{inspect(result)}"

      refute writes == [], "a first-ever register/3 wrote nothing to codelist_values"

      {:ok, codelist} = result
      assert length(fingerprint(codelist.id)) == 4
    end

    test "a codelist whose values were lost re-seeds on the next boot" do
      # The severity-1 concern in the task row: an established row header with
      # an EMPTY value table (a rolled-back seed, a truncate, a half-restored
      # dump). A digest column would still read "current" here. Reading the
      # rows back cannot.
      list_id = "onixedit:idem-emptied-#{System.unique_integer([:positive])}"
      {:ok, codelist} = register(list_id, payload())

      Repo.delete_all(from(v in Value, where: v.codelist_id == ^codelist.id))
      assert fingerprint(codelist.id) == []

      {result, writes} = value_writes(fn -> register(list_id, payload()) end)

      registered? = match?({:ok, _}, result)
      assert registered?, "the re-seed of an emptied codelist failed: #{inspect(result)}"

      refute writes == [],
             "an EMPTY codelist was reported current and left empty — this is the " <>
               "fresh-install failure the short circuit must never cause"

      assert length(fingerprint(codelist.id)) == 4
    end

    test "a partially lost value set re-seeds" do
      list_id = "onixedit:idem-partial-#{System.unique_integer([:positive])}"
      {:ok, codelist} = register(list_id, payload())

      Repo.delete_all(from(v in Value, where: v.codelist_id == ^codelist.id and v.code == ^"C2"))

      {result, writes} = value_writes(fn -> register(list_id, payload()) end)

      registered? = match?({:ok, _}, result)
      assert registered?, "the re-seed of a partial codelist failed: #{inspect(result)}"

      refute writes == [], "a codelist missing a value was reported current"
      assert length(fingerprint(codelist.id)) == 4
    end
  end

  describe "payloads the comparison refuses to answer for" do
    test "a duplicate code takes the rebuild path and raises as before" do
      list_id = "onixedit:idem-dup-#{System.unique_integer([:positive])}"

      duped = [
        %{code: "D1", translations: [%{language: "eng", label: "one"}]},
        %{code: "D1", translations: [%{language: "eng", label: "one again"}]}
      ]

      raised? =
        try do
          register(list_id, duped)
          false
        rescue
          _ -> true
        end

      assert raised?,
             "a payload repeating a code was accepted — the comparison must refuse " <>
               "to answer for it and let the writer raise, as it did before"
    end

    test "a header rename still lands even when the values are unchanged" do
      list_id = "onixedit:idem-rename-#{System.unique_integer([:positive])}"
      {:ok, codelist} = register(list_id, payload())

      {:ok, _} =
        Codelists.register(@plugin, list_id, %{
          issue: "1",
          name: "Renamed",
          values: payload()
        })

      assert Repo.reload!(codelist).name == "Renamed"
      assert length(fingerprint(codelist.id)) == 4
    end
  end
end
