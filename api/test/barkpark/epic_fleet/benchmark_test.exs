defmodule Barkpark.EpicFleet.BenchmarkTest do
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.EpicFleet
  alias Barkpark.EpicFleet.{Attempt, Benchmark, Experiment}
  alias Barkpark.Tenancy

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
               "1815ca312f91132a18732fb585c7339025f0a2bc5920fc02c1459be04a9c3100"

      assert document["summary_digest"] ==
               "5bd7d2914bc4ae184608cb1c6994de16c8c9502ac76ea3803521781f787bc5ec"

      assert document["ledger_digest"] ==
               "0db779ba31f0f71a1faf92610fcdda3633b9b22ac98621aa694164c5b1b16dce"
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

    test "rejects dangling replacement ancestry", %{attrs: attrs} do
      {:ok, experiment} = EpicFleet.create_benchmark_experiment(attrs)

      assert {:error, :replacement_attempt_not_found} =
               EpicFleet.record_benchmark_attempt(experiment, %{
                 attempt_attrs()
                 | attempt_id: "attempt-retry",
                   replaces_attempt_id: "attempt-missing",
                   ordinal: 2
               })

      assert EpicFleet.list_benchmark_attempts(experiment) == []
    end

    test "requires a replacement attempt to advance the predecessor ordinal", %{attrs: attrs} do
      {:ok, experiment} = EpicFleet.create_benchmark_experiment(attrs)
      {:ok, _original} = EpicFleet.record_benchmark_attempt(experiment, attempt_attrs())

      assert {:error, :replacement_ordinal_invalid} =
               EpicFleet.record_benchmark_attempt(experiment, %{
                 attempt_attrs()
                 | attempt_id: "attempt-retry",
                   replaces_attempt_id: "attempt-a",
                   ordinal: 1
               })

      assert Enum.map(EpicFleet.list_benchmark_attempts(experiment), & &1.attempt_id) == [
               "attempt-a"
             ]
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

    test "workspace teardown cascades experiments and replacement attempts", %{attrs: attrs} do
      workspace = create_workspace!()

      {:ok, experiment} =
        EpicFleet.create_benchmark_experiment(%{attrs | workspace_id: workspace.id})

      {:ok, _original} = EpicFleet.record_benchmark_attempt(experiment, attempt_attrs())

      {:ok, _replacement} =
        EpicFleet.record_benchmark_attempt(experiment, %{
          attempt_attrs()
          | attempt_id: "attempt-retry",
            replaces_attempt_id: "attempt-a",
            ordinal: 2
        })

      assert {:ok, _workspace} = Tenancy.delete_workspace(workspace)
      assert is_nil(Repo.get(Experiment, experiment.id))
      assert Repo.aggregate(Attempt, :count) == 0
    end
  end

  describe "canonical benchmark export/import" do
    test "sorts attempts, emits golden component digests, and redacts secrets", %{attrs: attrs} do
      {:ok, experiment} = EpicFleet.create_benchmark_experiment(attrs)

      {:ok, _} =
        EpicFleet.record_benchmark_attempt(
          experiment,
          %{attempt_attrs() | attempt_id: "attempt-a", ordinal: 1}
        )

      {:ok, _} =
        EpicFleet.record_benchmark_attempt(
          experiment,
          %{
            attempt_attrs()
            | attempt_id: "attempt-b",
              replaces_attempt_id: "attempt-a",
              ordinal: 2
          }
        )

      assert {:ok, document} = EpicFleet.export_benchmark(experiment)
      assert Enum.map(document["attempts"], & &1["attempt_id"]) == ["attempt-a", "attempt-b"]
      assert Enum.at(document["attempts"], 1)["replaces_attempt_id"] == "attempt-a"
      assert document["manifest"]["operator"]["api_key"] == "[REDACTED]"
      refute EpicFleet.canonical_json(document) =~ "do-not-export"

      assert document["manifest_digest"] == EpicFleet.canonical_digest(document["manifest"])
      assert document["attempts_digest"] == EpicFleet.canonical_digest(document["attempts"])
      assert document["summary_digest"] == EpicFleet.canonical_digest(document["summary"])
      assert String.length(document["ledger_digest"]) == 64

      assert {:ok, json} = EpicFleet.export_benchmark_json(experiment)
      assert {:ok, %{experiment: replay, attempts: 2}} = EpicFleet.import_benchmark_json(json)
      assert replay.id == experiment.id
      assert Repo.aggregate(Experiment, :count) == 1
      assert Repo.aggregate(Attempt, :count) == 2
    end

    test "redacts normalized and suffixed secret-key variants", %{attrs: attrs} do
      manifest = %{
        "api-key" => "api-secret",
        "runner_credentials" => "credential-secret",
        "nested" => %{"webhook_secret" => "hook-secret"}
      }

      {:ok, experiment} =
        EpicFleet.create_benchmark_experiment(%{attrs | manifest: manifest})

      assert experiment.manifest == %{
               "api-key" => "[REDACTED]",
               "runner_credentials" => "[REDACTED]",
               "nested" => %{"webhook_secret" => "[REDACTED]"}
             }

      {:ok, json} = EpicFleet.export_benchmark_json(experiment)
      refute json =~ "api-secret"
      refute json =~ "credential-secret"
      refute json =~ "hook-secret"
    end

    test "rejects non-canonical bytes and shape-changing fields before any write", %{attrs: attrs} do
      experiment = struct!(Experiment, Map.merge(attrs, %{id: Ecto.UUID.generate()}))
      document = Benchmark.document(experiment, [attempt_attrs()])
      canonical = EpicFleet.canonical_json(document)

      assert {:error, :non_canonical_json} = EpicFleet.import_benchmark_json(canonical <> "\n")

      with_extra_field = document |> Map.put("ignored", true) |> resign_document()

      assert {:error, :invalid_document_shape} =
               with_extra_field |> EpicFleet.canonical_json() |> EpicFleet.import_benchmark_json()

      assert Repo.aggregate(Experiment, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "rejects signed but non-canonical attempt ordering and unredacted secrets", %{
      attrs: attrs
    } do
      experiment = struct!(Experiment, Map.merge(attrs, %{id: Ecto.UUID.generate()}))

      document =
        Benchmark.document(experiment, [
          attempt_attrs(),
          %{attempt_attrs() | attempt_id: "attempt-b", ordinal: 2}
        ])

      unsorted =
        document
        |> Map.update!("attempts", &Enum.reverse/1)
        |> resign_document()

      assert {:error, :attempts_not_canonical} =
               unsorted |> EpicFleet.canonical_json() |> EpicFleet.import_benchmark_json()

      unredacted =
        document
        |> put_in(["manifest", "operator", "secret_key"], "must-not-cross-boundary")
        |> resign_document()

      assert {:error, :secrets_not_redacted} =
               unredacted |> EpicFleet.canonical_json() |> EpicFleet.import_benchmark_json()

      assert Repo.aggregate(Experiment, :count) == 0
      assert Repo.aggregate(Attempt, :count) == 0
    end

    test "rolls back earlier attempt inserts when a later replay conflicts", %{attrs: attrs} do
      {:ok, experiment} = EpicFleet.create_benchmark_experiment(attrs)

      existing = %{attempt_attrs() | attempt_id: "attempt-b", ordinal: 2}
      {:ok, _attempt} = EpicFleet.record_benchmark_attempt(experiment, existing)

      conflicting = put_in(existing, [:payload, "complete"], false)

      document =
        Benchmark.document(experiment, [
          attempt_attrs(),
          conflicting
        ])

      assert {:error, :attempt_conflict} =
               document |> EpicFleet.canonical_json() |> EpicFleet.import_benchmark_json()

      refute Repo.get_by(Attempt, experiment_id: experiment.id, attempt_id: "attempt-a")
      assert Repo.aggregate(Attempt, :count) == 1
    end

    test "atomically replaces artifact files with exact canonical bytes" do
      path =
        Path.join(
          System.tmp_dir!(),
          "barkpark-epic-fleet-#{System.unique_integer([:positive, :monotonic])}.json"
        )

      on_exit(fn -> File.rm(path) end)
      File.write!(path, "stale")

      json = EpicFleet.canonical_json(%{"benchmark" => true})
      assert :ok = EpicFleet.write_benchmark_json_file(path, json)
      assert File.read!(path) == json
      assert Path.wildcard(Path.join(Path.dirname(path), ".#{Path.basename(path)}.tmp-*")) == []
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

    assert %{rows: [[true]]} =
             Repo.query!("""
             SELECT EXISTS (
               SELECT 1
               FROM pg_trigger
               WHERE tgname = 'epic_benchmark_attempts_replacement_ordinal'
                 AND NOT tgisinternal
             )
             """)
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
      replaces_attempt_id: nil,
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

  defp resign_document(document) do
    manifest = document["manifest"]
    attempts = document["attempts"]
    summary = Benchmark.summary(attempts)

    base =
      document
      |> Map.delete("ledger_digest")
      |> Map.put("manifest_digest", EpicFleet.canonical_digest(manifest))
      |> Map.put("attempts_digest", EpicFleet.canonical_digest(attempts))
      |> Map.put("summary", summary)
      |> Map.put("summary_digest", EpicFleet.canonical_digest(summary))

    Map.put(base, "ledger_digest", EpicFleet.canonical_digest(base))
  end
end
