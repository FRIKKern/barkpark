defmodule Barkpark.Content.FilterOpsFixtureParityTest do
  @moduledoc """
  The ELIXIR half of the filter-operator lock.

  `Barkpark.Content.Query.valid_filter_ops/0` is the source of truth for the
  PUBLIC filter vocabulary: `QueryController` derives its door from it at
  compile time, so that list IS the wire form. The JS SDK cannot call it, so it
  keeps a mirror — `FILTER_OPS` in `js/packages/core/src/types.ts`, with
  `FilterOp` derived from that array rather than spelled beside it.

  `api/test/fixtures/filter_ops.json` is the ONE shared artifact both sides
  read. This file asserts the fixture equals `valid_filter_ops/0`;
  `js/packages/core/tests/filter-op-parity.test.ts` asserts `FILTER_OPS` equals
  the same fixture. So an op added to `@valid_filter_ops` without regenerating
  reds HERE, in the required Elixir gate, and an op deleted from the TS array
  reds THERE — neither list can move on its own.

  WHY THE FIXTURE AND NOT A DIRECT SOURCE READ. `sheets_parity_test.exs` greps
  the .ts source because its mirror is a literal `Set` in shipped code. Here the
  mirror is a checked-in JSON file the JS suite already reads at runtime, so
  comparing against it needs no TypeScript extractor — and an extractor that
  silently yields `[]` after a reformat is exactly the vacuous-pass shape this
  lock exists to avoid. The fixture path stays INSIDE `api/`, so this adds no
  repo-root read for `scripts/elixir-path-escape-check.sh` to cover.

  THIS IS THE DEFECT THE LOCK WAS BUILT FOR: `is` was in `@valid_filter_ops` and
  absent from the TS union, so a typed SDK caller could not express a filter the
  API accepts and validates. Both sides were tested; nothing compared them.

  Regenerating after a deliberate `@valid_filter_ops` change (from `api/`):

      REGEN_FILTER_OPS_FIXTURE=1 mix test \
        test/barkpark/content/filter_ops_fixture_parity_test.exs

  Regenerating is the ELIXIR-side half of the change only. The TS array still
  has to learn the op, or the JS parity test reds — which is the point.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.Query

  # `mix test` runs with cwd = api/, but a bare relative path breaks the moment
  # anything runs the suite from elsewhere. Anchored on __DIR__ instead, and
  # spelled as ONE literal (a path assembled from a module attribute is a shape
  # elixir-path-escape-check.sh cannot resolve).
  @fixture Path.expand("../../fixtures/filter_ops.json", __DIR__)

  setup_all do
    if System.get_env("REGEN_FILTER_OPS_FIXTURE") == "1" do
      File.write!(@fixture, Jason.encode!(Query.valid_filter_ops(), pretty: true) <> "\n")
    end

    :ok
  end

  defp fixture_ops do
    # A missing/renamed/empty fixture must RED here rather than leave the
    # equality below comparing against nothing.
    assert File.exists?(@fixture),
           "the shared filter-op fixture is missing at #{@fixture} — the JS parity " <>
             "test reads the same path, so both halves of the lock are dead"

    ops = @fixture |> File.read!() |> Jason.decode!()

    assert is_list(ops) and ops != [] and Enum.all?(ops, &is_binary/1),
           "the shared filter-op fixture must be a non-empty JSON array of strings, got: " <>
             inspect(ops)

    ops
  end

  describe "the shared filter-op fixture" do
    test "equals Barkpark.Content.Query.valid_filter_ops/0 exactly, in order" do
      ops = fixture_ops()
      canonical = Query.valid_filter_ops()

      assert ops == canonical,
             """
             api/test/fixtures/filter_ops.json drifted from Query.valid_filter_ops/0.
               only in the fixture: #{inspect(ops -- canonical)}
               only in @valid_filter_ops: #{inspect(canonical -- ops)}

             @valid_filter_ops is the source of truth. Regenerate the fixture:
               REGEN_FILTER_OPS_FIXTURE=1 mix test test/barkpark/content/filter_ops_fixture_parity_test.exs

             Then teach FILTER_OPS in js/packages/core/src/types.ts the same op, or
             js/packages/core/tests/filter-op-parity.test.ts reds against this fixture.
             Do NOT make this green by trimming @valid_filter_ops or this assertion.
             """
    end

    test "carries `is`, the operator the SDK union was missing" do
      # The row's own defect, pinned as a case: a regression that dropped `is`
      # from either side would otherwise only show up as an order/length diff.
      assert "is" in fixture_ops()
      assert "is" in Query.valid_filter_ops()
    end

    test "carries NO builder-only spelling — the fixture is the WIRE vocabulary" do
      # `@doc_id_only_ops` (starts_with / not_starts_with) have clauses on the
      # doc_id/_id column only and no public wire form; QueryController's door
      # refuses them, pinned by filter_ops_test.exs "the door stays narrower
      # than the builder". The SDK's public union must not type-bless a filter
      # every HTTP caller gets a 400 for, so they must never reach the fixture.
      ops = fixture_ops()

      for builder_only <- ~w(starts_with not_starts_with) do
        refute builder_only in ops,
               "#{builder_only} is a builder-only spelling with no wire form — it must " <>
                 "not enter the SDK's public FilterOp union via this fixture"
      end
    end
  end
end
