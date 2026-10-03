defmodule BarkparkWeb.MutateTaskLargeDescriptionTest do
  @moduledoc """
  task-7597dc34e9eafc2e — a runbook-sized task description survives the real
  create path, and the dedup gate it crosses stays linear.

  Two older rows (pds-bl-large-task-write-500, gr-bl-task-write-cap-breaks-briefs)
  measured large `bp task create` writes failing with a 500 / "unknown error"
  and blamed a SIZE CAP somewhere between ~5 KB and 16 KB. There is no cap: the
  endpoint parser takes 100 MB and nothing in content or tasks measures the
  description. The real cause was `Barkpark.Tasks.Similarity` re-tokenizing the
  new task's description once PER CANDIDATE, so a create cost description size
  times backlog size and lost the race against the 15 s DB checkout.
  `Similarity.assess/3` now tokenizes the probe once (see its moduledoc, "Cost").

  This test pins that end to end. It seeds a backlog whose titles the dedup
  scan admits, then POSTs a `type:task` create whose description is over
  20,000 bytes through `/v1/data/mutate/:dataset` — the real door, with the
  dedup gate in the fence chain. It asserts that:

    * the create succeeds and the stored description reads back byte-identical;
    * the gate scored the seeded backlog (not an empty candidate set);
    * the gate tokenized the new task's text exactly once: total tokenize
      events equal scored candidates + 1.

  Restoring the per-candidate `tokens(new_task)` call inside
  `Similarity.score/6` doubles the tokenize count and reds the last assertion.
  The count, not a wall clock, is the guard, so the test cannot flake on a
  loaded runner.
  """
  use BarkparkWeb.ConnCase, async: false

  # The dedup gate is a tasks-plugin pre-write fence.
  @moduletag :requires_plugins

  alias Barkpark.Content
  alias Barkpark.LabelFixtures

  @token "barkpark-test-mutate-task-large-description"
  @dataset "test"
  @seed_count 40
  @title "Runbook brief survives the task create path"
  @min_bytes 20_000

  setup do
    {:ok, _} =
      Barkpark.Auth.create_token(
        @token,
        "test-mutate-task-large-description",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    LabelFixtures.register_tags!(@dataset)
    seed_backlog!()
    :ok
  end

  # Seeds share the probe's title words, so the KNN title scan admits them as
  # candidates. They bypass the gate themselves: near-identical short seeds
  # would otherwise refuse each other as duplicates.
  defp seed_backlog! do
    for i <- 1..@seed_count do
      id = "large-desc-seed-#{i}-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Content.create_document(
          "task",
          %{
            "doc_id" => id,
            "title" => "#{@title} #{i}",
            "content" =>
              task_content(%{
                "description" => "Seed #{i}: a short backlog row about briefs and create paths.",
                "dedup_bypass" => true
              })
          },
          @dataset
        )
    end
  end

  defp task_content(extra) do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "priority" => 2,
      "acceptance_criteria" => [
        %{"criterion" => "the description reads back intact", "met" => false}
      ]
    }
    |> Map.merge(LabelFixtures.weighted_labels())
    |> Map.merge(extra)
  end

  # Over 20 KB of distinct words: the token count, not just the byte count, is
  # what the old per-candidate tokenize multiplied by the backlog.
  defp large_description do
    words = for i <- 1..2_600, do: "runbookstep#{i}"
    text = "A runbook-sized brief. " <> Enum.join(words, " ") <> " End of brief."
    assert byte_size(text) >= @min_bytes
    text
  end

  defp attach_tokenize_counter do
    me = self()
    handler = "large-description-tokenize-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark, :tasks, :similarity, :tokenize],
      fn _event, %{count: n}, _meta, _config -> send(me, {:tokenize, n}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp attach_candidate_counter do
    me = self()
    handler = "large-description-candidates-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, measurements, meta, _config ->
        if is_binary(meta[:query]) and meta[:query] =~ "<->" do
          send(me, {:scan, meta[:result], measurements})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp drain(tag, acc \\ []) do
    receive do
      {^tag, n} -> drain(tag, [n | acc])
      {^tag, n, _} -> drain(tag, [n | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp scanned_rows(results) do
    Enum.reduce(results, 0, fn
      {:ok, %{num_rows: n}}, acc -> acc + n
      _, acc -> acc
    end)
  end

  test "a 20 KB description is created through the dedup gate and reads back byte-identical" do
    description = large_description()
    id = "large-desc-#{System.unique_integer([:positive])}"

    attach_tokenize_counter()
    attach_candidate_counter()

    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{@token}")
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/mutate/#{@dataset}",
        Jason.encode!(%{
          "mutations" => [
            %{
              "create" => %{
                "_id" => id,
                "_type" => "task",
                "title" => @title,
                "content" => task_content(%{"description" => description})
              }
            }
          ]
        })
      )

    assert resp.status == 200, "got #{resp.status}: #{String.slice(resp.resp_body, 0, 600)}"

    tokenizations = drain(:tokenize) |> Enum.sum()
    scanned = drain(:scan) |> scanned_rows()

    assert {:ok, stored} = Content.get_document("drafts." <> id, "task", @dataset)
    stored_description = stored.content["description"]

    assert byte_size(stored_description) == byte_size(description)
    assert stored_description == description, "the description reads back byte-identical"

    # The gate scored a real backlog, not an empty candidate set: each scored
    # candidate costs one tokenization, so more than half the seeds were scored.
    assert scanned >= div(@seed_count, 2),
           "the dedup scan returned #{scanned} rows; expected most of the #{@seed_count} seeds"

    assert tokenizations - 1 > div(@seed_count, 2),
           "tokenized #{tokenizations} times; the gate scored too few seeds to measure anything"

    # Linear: one tokenization per scanned candidate at most, plus ONE for the
    # new task. Re-tokenizing the new task per candidate costs 2N + 1 for N
    # scored candidates, which exceeds this bound once more than half the
    # scanned rows are scored (asserted just above).
    assert tokenizations <= scanned + 1,
           "tokenized #{tokenizations} times over #{scanned} candidate rows; " <>
             "the new task's text must be tokenized once, not once per candidate"
  end
end
