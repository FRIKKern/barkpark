defmodule Barkpark.Workers.FindabilityPosttestTest do
  @moduledoc """
  E5 post-publish findability self-test (authoring-excellence D9/D29).

  Covers:
    * enqueue off the `fire_after` seam — walled-type PUBLISH enqueues the job;
      the publish returns `{:ok, _}` regardless (unaffected), and a non-walled
      type never enqueues;
    * the REAL `Content.search_documents` facade: a well-labeled paper
      self-retrieves (HIT) → no finding;
    * a self-MISS emits `Logger.warning` + `[:barkpark, :authoring,
      :findability_miss]` telemetry with rank diagnostics;
    * deleted/unreadable-before-run → clean `{:cancel, :doc_gone}` no-op, NO
      finding, NO retry (cancel is terminal);
    * top-N is configurable + defaulted;
    * a raising worker is isolated from the publish (async, Oban-owned).

  `config/test.exs` is `testing: :manual`, so jobs are asserted/performed
  explicitly and never auto-run.
  """
  use Barkpark.DataCase, async: true
  use Oban.Testing, repo: Barkpark.Repo

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Workers.FindabilityPosttest

  @dataset "findability_posttest_test"

  # ── Test seams (string-named in job args, resolved via to_existing_atom) ──

  # Fake search facade that returns an empty result — forces a self-miss.
  defmodule EmptySearch do
    @moduledoc false
    def search_documents(_q, _dataset, _opts), do: {[], 0, %{}}
  end

  # Fake content facade: the doc still exists and is readable.
  defmodule PresentContent do
    @moduledoc false
    def get_document(id, type, dataset, _opts),
      do: {:ok, %{doc_id: id, type: type, dataset: dataset}}
  end

  # Fake content facade: the doc was deleted / is not readable.
  defmodule GoneContent do
    @moduledoc false
    def get_document(_id, _type, _dataset, _opts), do: {:error, :not_found}
  end

  # A search seam that raises — models a worker that blows up at run time.
  defmodule RaisingSearch do
    @moduledoc false
    def search_documents(_q, _dataset, _opts), do: raise("boom in the self-test worker")
  end

  setup do
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Paper", "visibility" => "public", "fields" => []},
      @dataset
    )

    Content.upsert_schema(
      %{"name" => "note", "title" => "Note", "visibility" => "public", "fields" => []},
      @dataset
    )

    :ok
  end

  # A wall-compliant paper content map with an EXPLICIT distinctive main tag so
  # the self-query has a unique token to retrieve on. The strongest tag becomes
  # the denormalized main_tag (charter D7).
  defp labeled_content(main_tag, extra \\ %{}) do
    Barkpark.LabelFixtures.register_tags!(@dataset, [main_tag, "secondary-axis"])

    Map.merge(
      %{
        "description" => "A non-trivial description for the findability self-test wall.",
        "tags" => [
          %{
            "tag" => main_tag,
            "strength" => 90,
            "rationale" => "The primary axis — becomes the denormalized main_tag."
          },
          %{
            "tag" => "secondary-axis",
            "strength" => 40,
            "rationale" => "A secondary axis so the tag count sits inside the norm."
          }
        ]
      },
      extra
    )
  end

  defp publish_paper!(id, main_tag, title) do
    {:ok, _} =
      Content.create_document(
        "paper",
        %{"_id" => id, "title" => title, "content" => labeled_content(main_tag)},
        @dataset
      )

    Content.publish_document(id, "paper", @dataset)
  end

  # Attach a telemetry handler that forwards findability_miss events to this pid.
  defp attach_miss_handler do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      FindabilityPosttest.telemetry_event(),
      fn event, measurements, metadata, _cfg ->
        send(test_pid, {:findability_miss, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  describe "enqueue off the fire_after seam" do
    test "a walled-type PUBLISH enqueues the self-test; publish is unaffected" do
      assert {:ok, published} = publish_paper!("fp-enq", "zorpfindable", "Zorptastic Probe")
      assert published.status == "published"

      assert_enqueued(
        worker: FindabilityPosttest,
        args: %{"doc_id" => "fp-enq", "type" => "paper", "dataset" => @dataset}
      )

      # The seed carries the main_tag + leading title tokens.
      [job] = all_enqueued(worker: FindabilityPosttest)
      assert job.args["query"] =~ "zorpfindable"
      assert job.args["query"] =~ "Zorptastic"
      assert job.args["top_n"] == FindabilityPosttest.default_top_n()
    end

    test "a NON-walled type publish never enqueues the self-test" do
      Content.upsert_schema(
        %{"name" => "note", "title" => "Note", "visibility" => "public", "fields" => []},
        @dataset
      )

      {:ok, _} = Content.create_document("note", %{"_id" => "fp-note", "title" => "N"}, @dataset)
      assert {:ok, _} = Content.publish_document("fp-note", "note", @dataset)

      assert [] = all_enqueued(worker: FindabilityPosttest)
    end

    test "enqueue_after is a no-op for non-publish events and returns :ok" do
      doc = %Document{doc_id: "x", type: "paper", dataset: @dataset, content: %{}}
      assert :ok = FindabilityPosttest.enqueue_after(%{event: :after_save, doc: doc})
      assert :ok = FindabilityPosttest.enqueue_after(%{event: :after_delete, doc: doc})
      assert [] = all_enqueued(worker: FindabilityPosttest)
    end

    test "top_n is configurable via the :top_n option" do
      doc = %Document{
        doc_id: "fp-topn",
        type: "paper",
        dataset: @dataset,
        title: "Topn Probe",
        content: %{"main_tag" => "topntag"}
      }

      assert :ok = FindabilityPosttest.enqueue_after(%{event: :after_publish, doc: doc}, top_n: 3)

      assert_enqueued(worker: FindabilityPosttest, args: %{"doc_id" => "fp-topn", "top_n" => 3})
    end
  end

  describe "perform/1 — real search facade (HIT)" do
    test "a well-labeled paper self-retrieves through Content.search_documents — no finding" do
      attach_miss_handler()

      assert {:ok, _} = publish_paper!("fp-hit", "quixotropic", "Quixotropic Signal Marker")

      # Run the REAL facade (no seam override) against the sandboxed corpus.
      assert :ok =
               perform_job(FindabilityPosttest, %{
                 "doc_id" => "fp-hit",
                 "type" => "paper",
                 "dataset" => @dataset,
                 "query" => "quixotropic Quixotropic Signal Marker",
                 "top_n" => 10
               })

      refute_receive {:findability_miss, _, _, _}, 200
    end
  end

  describe "perform/1 — self-miss (finding emitted)" do
    test "a miss on a still-present doc emits warning + telemetry with rank diagnostics" do
      attach_miss_handler()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   perform_job(FindabilityPosttest, %{
                     "doc_id" => "fp-miss",
                     "type" => "paper",
                     "dataset" => @dataset,
                     "query" => "unretrievable token",
                     "top_n" => 10,
                     "search" => inspect(EmptySearch),
                     "content" => inspect(PresentContent)
                   })
        end)

      assert log =~ "authoring.findability_miss"
      assert log =~ "fp-miss"

      assert_receive {:findability_miss, [:barkpark, :authoring, :findability_miss], %{count: 1},
                      metadata}

      assert metadata.doc_id == "fp-miss"
      assert metadata.type == "paper"
      assert metadata.dataset == @dataset
      assert metadata.query == "unretrievable token"
      assert %{ranked: [], top_n: 10, total: 0} = metadata.rank_diagnostics
    end

    test "a miss where the doc was deleted/unreadable no-ops cleanly (cancel, NO finding)" do
      attach_miss_handler()

      assert {:cancel, :doc_gone} =
               perform_job(FindabilityPosttest, %{
                 "doc_id" => "fp-gone",
                 "type" => "paper",
                 "dataset" => @dataset,
                 "query" => "unretrievable token",
                 "top_n" => 10,
                 "search" => inspect(EmptySearch),
                 "content" => inspect(GoneContent)
               })

      refute_receive {:findability_miss, _, _, _}, 200
    end
  end

  describe "perform/1 — defensive no-ops (no crash, no retry storm)" do
    test "a blank query no-ops (:ok) — nothing to search for" do
      assert :ok =
               perform_job(FindabilityPosttest, %{
                 "doc_id" => "fp-blank",
                 "type" => "paper",
                 "dataset" => @dataset,
                 "query" => "",
                 "top_n" => 10
               })
    end

    test "missing doc_id / dataset cancel terminally (no retry)" do
      assert {:cancel, :missing_doc_id} =
               perform_job(FindabilityPosttest, %{"dataset" => @dataset, "query" => "q"})

      assert {:cancel, :missing_dataset} =
               perform_job(FindabilityPosttest, %{"doc_id" => "x", "query" => "q"})
    end
  end

  describe "publish decoupling — a raising worker never fails the publish" do
    test "publish returns {:ok} before the async job runs; a raising perform is isolated" do
      # The publish commits and returns synchronously; the self-test is only
      # ENQUEUED at that point, never run inline — so the publish outcome is
      # structurally independent of the worker.
      assert {:ok, published} = publish_paper!("fp-decouple", "decoupletag", "Decouple Probe")
      assert published.status == "published"
      assert_enqueued(worker: FindabilityPosttest, args: %{"doc_id" => "fp-decouple"})

      # And when the worker itself raises, the failure is contained to the job
      # (max_attempts: 1 → discarded by Oban, never retry-stormed) — it cannot
      # reach back into the already-returned publish.
      assert_raise RuntimeError, ~r/boom in the self-test worker/, fn ->
        perform_job(FindabilityPosttest, %{
          "doc_id" => "fp-decouple",
          "type" => "paper",
          "dataset" => @dataset,
          "query" => "decoupletag Decouple Probe",
          "top_n" => 10,
          "search" => inspect(RaisingSearch)
        })
      end
    end
  end
end
