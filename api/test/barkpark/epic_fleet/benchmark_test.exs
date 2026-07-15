defmodule Barkpark.EpicFleet.BenchmarkTest do
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.EpicFleet
  alias Barkpark.EpicFleet.{Attempt, Benchmark, Experiment}

  setup do
    {workspace, _project} = ensure_default_scope!()

    attrs = %{
      workspace_id: workspace.id,
      epic_id: "epic-#{System.unique_integer([:positive])}",
      wave_id: "wave-2",
      experiment_id: "concurrency-20260715",
      phase: "legendary",
      protocol_version: 1,
      manifest: manifest()
    }

    %{attrs: attrs}
  end

  describe "canonical JSON" do
    test "is byte-identical across recursive key permutations and has a golden digest" do
      left = %{"b" => [%{"z" => 1, "a" => true}], "a" => "nord"}
      right = %{a: "nord", b: [%{a: true, z: 1}]}

      assert EpicFleet.canonical_json(left) ==
               ~s({"a":"nord","b":[{"a":true,"z":1}]})

      assert EpicFleet.canonical_json(left) == EpicFleet.canonical_json(right)

      assert EpicFleet.canonical_digest(left) ==
               "289df3f385174ac1840b87f3de4738a42efacf6be94f59af683f7d300a1f2a83"
    end

    test "pins cross-runtime manifest, attempts, summary, and ledger digest vectors" do
      experiment = %Experiment{
        id: "00000000-0000-0000-0000-000000000001",
        workspace_id: "00000000-0000-0000-0000-000000000002",
        epic_id: "epic-golden",
        wave_id: "wave-golden",
        experiment_id: "experiment-golden",
        phase: "legendary",
        protocol_version: 1,
        manifest: manifest()
      }

      attempts = [
        %{attempt_attrs() | attempt_id: "attempt-b", ordinal: 2},
        %{attempt_attrs() | attempt_id: "attempt-a", ordinal: 1}
      ]

      document = Benchmark.document(experiment, attempts)

      assert document["manifest_digest"] ==
               "615f47d9bde44b357f54b888dd7a0e9bba5d7a0f6b1baa68c18662839b959f6e"

      assert document["attempts_digest"] ==
               "7265dfbb9bedf5765f750738aebec81fa2766a7287a572e19f4d7593fede196f"

      assert document["summary_digest"] ==
               "5bd7d2914bc4ae184608cb1c6994de16c8c9502ac76ea3803521781f787bc5ec"

      assert document["ledger_digest"] ==
               "11386eec47be11331c18795df6d10484121bc85425fdf4e61dad4b4884b13365"
    end
  end

  describe "append-only experiment attempts" do
    test "represents Legendary attempts with all typed cost states", %{attrs: attrs} do
      assert {:ok, experiment} = EpicFleet.create_benchmark_experiment(attrs)
      assert experiment.phase == "legendary"
      safe_manifest = put_in(manifest(), ["operator", "api_key"], "[REDACTED]")
      assert experiment.manifest_digest == EpicFleet.canonical_digest(safe_manifest)

      assert {:ok, attempt} =
               EpicFleet.record_benchmark_attempt(experiment, attempt_attrs())

      assert MapSet.new(Enum.map(attempt.costs, fn {_metric, value} -> value["state"] end)) ==
               MapSet.new(Attempt.cost_states())

      assert {:ok, replay} = EpicFleet.record_benchmark_attempt(experiment, attempt_attrs())
      assert replay.id == attempt.id

      assert {:error, :attempt_conflict} =
               EpicFleet.record_benchmark_attempt(
                 experiment,
                 put_in(attempt_attrs(), [:payload, "complete"], false)
               )
    end

    test "rejects untyped metrics before persistence", %{attrs: attrs} do
      {:ok, experiment} = EpicFleet.create_benchmark_experiment(attrs)

      assert {:error, changeset} =
               EpicFleet.record_benchmark_attempt(
                 experiment,
                 put_in(attempt_attrs(), [:costs, "wall_seconds"], 3.2)
               )

      assert "must contain typed metric states" in errors_on(changeset).costs
    end

    test "database rejects direct attempt UPDATE and DELETE", %{attrs: attrs} do
      {:ok, experiment} = EpicFleet.create_benchmark_experiment(attrs)
      {:ok, attempt} = EpicFleet.record_benchmark_attempt(experiment, attempt_attrs())

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("UPDATE epic_benchmark_attempts SET status='failed' WHERE id=$1", [
          Ecto.UUID.dump!(attempt.id)
        ])
      end

      assert_raise Postgrex.Error, ~r/append-only/, fn ->
        Repo.query!("DELETE FROM epic_benchmark_attempts WHERE id=$1", [
          Ecto.UUID.dump!(attempt.id)
        ])
      end
    end
  end

  describe "canonical benchmark export/import" do
    test "sorts attempts, emits golden component digests, and redacts secrets", %{attrs: attrs} do
      {:ok, experiment} = EpicFleet.create_benchmark_experiment(attrs)

      {:ok, _} =
        EpicFleet.record_benchmark_attempt(
          experiment,
          %{attempt_attrs() | attempt_id: "attempt-b", ordinal: 2}
        )

      {:ok, _} =
        EpicFleet.record_benchmark_attempt(
          experiment,
          %{attempt_attrs() | attempt_id: "attempt-a", ordinal: 1}
        )

      assert {:ok, document} = EpicFleet.export_benchmark(experiment)
      assert Enum.map(document["attempts"], & &1["attempt_id"]) == ["attempt-a", "attempt-b"]
      assert document["manifest"]["operator"]["api_key"] == "[REDACTED]"
      refute EpicFleet.canonical_json(document) =~ "do-not-export"

      assert document["manifest_digest"] ==
               "615f47d9bde44b357f54b888dd7a0e9bba5d7a0f6b1baa68c18662839b959f6e"

      assert document["attempts_digest"] ==
               "7265dfbb9bedf5765f750738aebec81fa2766a7287a572e19f4d7593fede196f"

      assert document["summary_digest"] ==
               "5bd7d2914bc4ae184608cb1c6994de16c8c9502ac76ea3803521781f787bc5ec"

      assert String.length(document["ledger_digest"]) == 64

      assert {:ok, json} = EpicFleet.export_benchmark_json(experiment)
      assert {:ok, %{experiment: replay, attempts: 2}} = EpicFleet.import_benchmark_json(json)
      assert replay.id == experiment.id
      assert Repo.aggregate(Experiment, :count) == 1
      assert Repo.aggregate(Attempt, :count) == 2
    end

    test "rejects tampered artifacts before any write", %{attrs: attrs} do
      experiment = struct!(Experiment, Map.merge(attrs, %{id: Ecto.UUID.generate()}))
      document = Benchmark.document(experiment, [attempt_attrs()])
      tampered = put_in(document, ["summary", "attempt_count"], 99)

      assert {:error, :summary_mismatch} =
               tampered |> EpicFleet.canonical_json() |> EpicFleet.import_benchmark_json()

      assert Repo.aggregate(Experiment, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end
  end

  test "forward migration installs typed-cost and append-only constraints" do
    version = 20_260_715_000_400

    assert %{rows: [[^version]]} =
             Repo.query!("SELECT version FROM schema_migrations WHERE version=$1", [version])

    assert %{rows: [[definition]]} =
             Repo.query!("""
             SELECT pg_get_constraintdef(oid)
             FROM pg_constraint
             WHERE conname = 'epic_benchmark_attempts_costs'
             """)

    assert definition =~ "barkpark_epic_costs_valid"
  end

  defp manifest do
    %{
      "seed" => 20_260_715,
      "widths" => [1, 2, 3, 6],
      "operator" => %{"name" => "benchmark", "api_key" => "do-not-export"}
    }
  end

  defp attempt_attrs do
    %{
      attempt_id: "attempt-a",
      ordinal: 1,
      treatment: "width-1",
      status: "completed",
      costs: %{
        "wall_seconds" => %{"state" => "observed", "value" => 3.25, "unit" => "seconds"},
        "token_count" => %{"state" => "unsupported", "reason" => "provider omitted usage"},
        "context_bytes" => %{"state" => "missing", "reason" => "sample absent"},
        "cpu_percent" => %{"state" => "invalid", "reason" => "counter reset"}
      },
      provenance: %{"sampler" => "stdlib", "host" => "fixture"},
      payload: %{"complete" => true, "verified_yield" => 6}
    }
  end
end
