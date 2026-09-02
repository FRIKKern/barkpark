defmodule Barkpark.Plugins.GripFactPublishGateTest do
  @moduledoc """
  Locks the Grip plugin's `before_publish` wall on `type:fact` — fired through
  the REAL dispatcher (`Barkpark.Plugins.Hooks`), not by calling the private
  hook, so the test would notice the hook being dropped from
  `lifecycle_hooks/0` as readily as it would notice the rule changing.

  No `DataCase`: `Hooks.fire/2` reads its plugin list from `Application`
  (`:barkpark, :plugins`) and the gate is pure over the payload, so nothing
  here needs Postgres.

  The gate is proven ABLE TO FAIL AND ABLE TO PASS in the same block: an
  honest fact publishes, a level-skipping one is refused with a named reason.
  A gate only ever seen refusing could be a gate that refuses everything.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Bulldocs
  alias Barkpark.Plugins.Grip
  alias Barkpark.Plugins.Hooks
  alias Barkpark.Plugins.Tasks

  setup do
    previous = Application.fetch_env(:barkpark, :plugins)
    Application.put_env(:barkpark, :plugins, [Grip])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:barkpark, :plugins, value)
        :error -> Application.delete_env(:barkpark, :plugins)
      end
    end)

    :ok
  end

  # A fact document shaped the way `Content.Lifecycle.publish_document/5`
  # promotes it. `extra` overrides individual content fields.
  defp fact(extra \\ %{}) do
    %{
      "type" => "fact",
      "doc_id" => "drafts.fact-under-test",
      "content" =>
        Map.merge(
          %{
            "subject" => "api/lib/barkpark/plugins/hooks.ex",
            "quantity" => "before_events count",
            "claim" => "4 before_* lifecycle events are declared",
            "evidence" => "read the attribute in the checkout",
            "rerun" => "grep -n '@before_events' api/lib/barkpark/plugins/hooks.ex",
            "level" => "L3",
            "observed_at" => "2026-09-02T00:00:00Z",
            "deps" => []
          },
          extra
        )
    }
  end

  defp publish(doc) do
    Hooks.fire(:before_publish, %{
      event: :before_publish,
      doc: doc,
      dataset: "grip_fact_publish_gate_test",
      ctx: %{}
    })
  end

  describe "the gate is able to pass" do
    test "an honest fact publishes" do
      assert publish(fact()) == :ok
    end

    test "an honest UNDER-claim publishes — a ceiling only bites upward" do
      assert publish(fact(%{"level" => "L6"})) == :ok
    end

    test "an L1 claim backed by an L1 command publishes" do
      assert publish(
               fact(%{
                 "rerun" => "ssh root@89.167.28.206 'systemctl is-active barkpark'",
                 "level" => "L1"
               })
             ) == :ok
    end

    test "a non-fact document passes untouched" do
      assert publish(%{"type" => "paper", "content" => %{"blocks" => []}}) == :ok
      assert publish(%{"type" => "task", "content" => %{}}) == :ok
    end

    test "a payload with no doc at all passes untouched" do
      assert Hooks.fire(:before_publish, %{event: :before_publish, ctx: %{}}) == :ok
    end
  end

  describe "the gate is able to fail" do
    test "a level-skipping fact is refused, and the reason NAMES both levels" do
      # The command reads the local checkout. The claim says it observed a
      # running system. That is the level-skip this epic exists to abolish.
      assert {:halt, reason} = publish(fact(%{"level" => "L1"}))
      assert reason =~ "LEVEL-SKIP"
      assert reason =~ "claimed L1"
      assert reason =~ "derived L3"
    end

    test "a two-rung skip (L1 claimed on an L3 local test run) is refused" do
      assert {:halt, reason} =
               publish(fact(%{"rerun" => "CC=clang mix test test/x_test.exs", "level" => "L1"}))

      assert reason =~ "LEVEL-SKIP"
    end

    test "an L2 claim on a LOOPBACK curl is refused — it read the local dev server" do
      assert {:halt, reason} =
               publish(
                 fact(%{"rerun" => "curl -s http://localhost:4000/api/schemas", "level" => "L2"})
               )

      assert reason =~ "LEVEL-SKIP"
      assert reason =~ "derived L3"
    end

    test "a fact with no rerun command cannot publish" do
      assert {:halt, reason} = publish(fact(%{"rerun" => ""}))
      assert reason =~ "NO-RERUN"

      assert {:halt, dropped} = publish(%{"type" => "fact", "content" => %{"level" => "L3"}})
      assert dropped =~ "NO-RERUN"
    end

    test "a fact whose rerun is prose cannot publish" do
      assert {:halt, reason} =
               publish(fact(%{"rerun" => "git show origin/main:<the file in question>"}))

      assert reason =~ "NOT-A-COMMAND"
    end

    test "a fact whose rerun is not on the read allowlist cannot publish" do
      assert {:halt, reason} = publish(fact(%{"rerun" => "frobnicate --all"}))
      assert reason =~ "NOT-ALLOWLISTED"
    end

    test "a level that is not on the ladder cannot publish" do
      assert {:halt, reason} = publish(fact(%{"level" => "L0"}))
      assert reason =~ "UNKNOWN-LEVEL"

      assert {:halt, missing} = publish(fact(%{"level" => nil}))
      assert missing =~ "UNKNOWN-LEVEL"
    end
  end

  describe "evidence is L6 by construction" do
    test "no wording in the narrative fields can raise the ceiling" do
      # Every narrative field screams L1. The command reads the local checkout.
      # The gate must side with the invocation.
      loud = %{
        "claim" => "verified against the running prod box over ssh root@89.167.28.206",
        "evidence" =>
          "ssh root@89.167.28.206 systemctl is-active barkpark && " <>
            "curl -s https://api.barkpark.cloud/api/schemas — both confirmed live",
        "subject" => "ssh://root@89.167.28.206/opt/barkpark",
        "level" => "L1"
      }

      assert {:halt, reason} = publish(fact(loud))
      assert reason =~ "LEVEL-SKIP"
      assert reason =~ "derived L3"
    end
  end

  describe "it follows the two shipped exemplars, not a new halt convention" do
    test "one before_publish hook, arity 1, registered the way tasks/bulldocs register theirs" do
      %{before_publish: [hook]} = Grip.lifecycle_hooks()
      assert is_function(hook, 1)

      %{before_publish: [tasks_hook]} = Tasks.lifecycle_hooks()
      %{before_publish: [bulldocs_hook]} = Bulldocs.lifecycle_hooks()
      assert is_function(tasks_hook, 1)
      assert is_function(bulldocs_hook, 1)
    end

    test "it halts with `{:halt, binary}` — the only refusal the dispatcher honours" do
      # `Hooks.fire/2` logs-and-continues on any other return shape, so a hook
      # that invented its own error tuple would fail OPEN and publish the fact.
      assert {:halt, reason} = publish(fact(%{"level" => "L1"}))
      assert is_binary(reason)
    end

    test "it walls PUBLISH only — no before_save hook, so draft authoring stays free" do
      # Both exemplars leave the draft path open (Bulldocs' before_save gates
      # are about template shape, not about the publish rule). A fact is
      # drafted before it is measured; gating the save would make the honest
      # path the expensive one.
      refute Map.has_key?(Grip.lifecycle_hooks(), :before_save)

      assert Hooks.fire(:before_save, %{event: :before_save, doc: fact(%{"level" => "L1"})}) ==
               :ok
    end
  end

  describe "the schema the gate protects" do
    test "register_schemas/1 declares the `fact` type with the ledger's own fields" do
      assert [schema] = Grip.register_schemas([])
      assert schema.name == "fact"
      # Fails CLOSED: the evidence ledger is not anonymously readable.
      assert schema.visibility == "private"

      names = Enum.map(schema.fields, &Map.get(&1, "name"))

      for field <- ~w(subject quantity claim evidence rerun level observed_at deps) do
        assert field in names, "the `fact` schema must declare #{field}"
      end
    end
  end
end
