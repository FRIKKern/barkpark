defmodule Barkpark.Search.SurfaceConfigRefusesDeadKnobsTest do
  @moduledoc """
  The search surface config used to accept knobs it could not honour, store
  them, and echo them back on the next GET — the caller's only feedback saying
  their setting had taken.

  Three shapes, all silent before this change:

    * `zero_hit_strategy` outside the three names `QueryPipeline` implements.
      `try_drop_tokens/5` and `try_typo_widen/5` both guard on the literal
      names, so `"aggressive"` was stored, read back as `"aggressive"`, and
      behaved like `"none"` — every recovery pass quietly off.
    * a `typo_policy` key nothing reads. `min_len_2typo` shipped in BOTH
      defaults from the day the block was introduced and no retriever ever
      consulted it; an admin tuning it changed nothing at all.
    * a well-formed `typo_policy` with a wrong-typed value: `"enabled" => "yes"`
      is a string, and the reader compares against `false`, so a caller who
      believed they had turned typo tolerance off still had it on.

  Each test asserts a REFUSAL, and the round-trip test pins the invariant that
  makes refusal safe: the config the server itself hands out must be a config
  the server accepts back.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Search.SurfaceConfigs

  @scope "production"

  setup do
    on_exit(fn -> SurfaceConfigs.__reset_cache_for_test__() end)
    SurfaceConfigs.seed_defaults!()
    SurfaceConfigs.__reset_cache_for_test__()
    {:ok, ws: create_workspace!()}
  end

  defp errors(changeset), do: Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)

  describe "zero_hit_strategy" do
    test "a strategy the pipeline cannot run is refused, not stored", %{ws: ws} do
      assert {:error, changeset} =
               SurfaceConfigs.upsert(
                 "documents",
                 @scope,
                 %{"zeroHitStrategy" => "aggressive"},
                 ws.id
               )

      assert %{zero_hit_strategy: [message]} = errors(changeset)
      assert message =~ "none, drop_tokens, typo_widen"

      # And the refusal did not write: the caller's config is still the default.
      assert SurfaceConfigs.get("documents", @scope, ws.id)["zero_hit_strategy"] ==
               "drop_tokens"
    end

    for strategy <- ~w(none drop_tokens typo_widen) do
      test "#{strategy} is accepted", %{ws: ws} do
        assert {:ok, echo} =
                 SurfaceConfigs.upsert(
                   "documents",
                   @scope,
                   %{"zeroHitStrategy" => unquote(strategy)},
                   ws.id
                 )

        assert echo["zero_hit_strategy"] == unquote(strategy)
      end
    end
  end

  describe "typo_policy" do
    test "a key with no reader is refused and named", %{ws: ws} do
      assert {:error, changeset} =
               SurfaceConfigs.upsert(
                 "documents",
                 @scope,
                 %{"typoPolicy" => %{"enabled" => true, "min_len_2typo" => 9}},
                 ws.id
               )

      assert %{typo_policy: [message]} = errors(changeset)
      assert message =~ "min_len_2typo"
      assert message =~ "accepted keys:"
    end

    test "a wrong-typed value is refused rather than read as its falsy neighbour", %{ws: ws} do
      assert {:error, changeset} =
               SurfaceConfigs.upsert(
                 "documents",
                 @scope,
                 %{"typoPolicy" => %{"enabled" => "yes"}},
                 ws.id
               )

      assert %{typo_policy: [message]} = errors(changeset)
      assert message =~ "enabled must be a boolean"
    end

    test "an out-of-range threshold is refused", %{ws: ws} do
      assert {:error, changeset} =
               SurfaceConfigs.upsert(
                 "documents",
                 @scope,
                 %{"typoPolicy" => %{"similarity_threshold" => 12}},
                 ws.id
               )

      assert %{typo_policy: [message]} = errors(changeset)
      assert message =~ "between 0 and 1"
    end

    test "a non-positive min_len_1typo is refused", %{ws: ws} do
      assert {:error, changeset} =
               SurfaceConfigs.upsert(
                 "documents",
                 @scope,
                 %{"typoPolicy" => %{"min_len_1typo" => 0}},
                 ws.id
               )

      assert %{typo_policy: [message]} = errors(changeset)
      assert message =~ "positive integer"
    end

    test "every key the readers consult is still accepted", %{ws: ws} do
      policy = %{
        "enabled" => false,
        "min_len_1typo" => 6,
        "similarity_threshold" => 0.4,
        "similarity_threshold_relaxed" => 0.2
      }

      assert {:ok, echo} =
               SurfaceConfigs.upsert("documents", @scope, %{"typoPolicy" => policy}, ws.id)

      assert echo["typo_policy"] == policy
    end
  end

  describe "the round trip that makes refusal safe" do
    for surface <- ~w(documents media) do
      test "#{surface}: the config the server hands out is a config it accepts back", %{ws: ws} do
        surface = unquote(surface)
        served = SurfaceConfigs.get(surface, @scope, ws.id)

        assert {:ok, _echo} =
                 SurfaceConfigs.upsert(
                   surface,
                   @scope,
                   %{
                     "searchableFields" => served["searchable_fields"],
                     "typoPolicy" => served["typo_policy"],
                     "zeroHitStrategy" => served["zero_hit_strategy"],
                     "highlightFields" => served["highlight_fields"]
                   },
                   ws.id
                 ),
               "GET → PUT must round-trip: a default carrying a key the PUT " <>
                 "refuses would 422 an admin on their first save"
      end
    end
  end
end
