defmodule BarkparkWeb.TaskCreatePublishDuplicateLeavesNoRowTest do
  @moduledoc """
  A `duplicate_of` REFUSAL FROM `bp task create --publish` LEAVES NO ROW UNDER
  ANY doc_id (task-f4bce37848f42477).

  The filing (2026-09-21) reported a refused create that was nevertheless
  published under a FRESH id, plus a JSON envelope carrying
  `residue: discard_failed` / "the follow-up discard was refused: document not
  found". `WallRefusalLeavesNoDraftTest` already pins the draft discard, but it
  drives a DIFFERENT shape than bp: an explicit `_id`, nested `content`, and a
  lookup BY THE NAMED ID — which cannot see a row that landed under another id.

  This file drives the exact three calls `internal/cli/tasks_create_cmd.go`
  `runTaskCreate` sends, each a `POST /v1/data/mutate/<dataset>` with its own
  per-leg `Idempotency-Key`:

    1. `create`      — `{_type: "task", …flat fields}`, NO `_id` (server mints it)
    2. `publish`     — `{id: <bare id>, type: "task"}`
    3. `discardDraft` — `{id: <bare id>, type: "task"}`, only after a 4xx on 2
       (`discardCreatedTaskDraftQuiet`)

  and measures the TABLE: every `type:task` row in the dataset, counted before
  and after, so a ghost under any id reds it.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo

  @dataset "test"

  # DedupWall scores Jaccard over title + tag NAME tokens and needs >= 3 shared
  # tokens; the near-duplicate differs from the incumbent by one trailing word.
  @incumbent_title "Reconcile the orphaned openModal scenario gaps in the console drive harness"
  @near_dup_title "Reconcile the orphaned openModal scenario gaps in the console drive harness again"

  setup do
    Barkpark.Auth.create_token(
      "barkpark-dev-token",
      "dev",
      @dataset,
      ["read", "write", "admin"],
      Barkpark.TenancyFixtures.default_workspace_id!()
    )

    register_task_schemas!()
    LabelFixtures.register_tags!(@dataset)
    :ok
  end

  test "a near-duplicate refused as duplicate_of leaves the task row count unchanged" do
    incumbent = bp_create_publish!(@incumbent_title)
    before = task_rows()

    # Leg 1 — the create. Precondition, asserted: the draft IS a new row, so the
    # "count unchanged" verdict below cannot pass on a create that never landed.
    new_invocation()
    create = bp_leg(:create, create_op(@near_dup_title))
    assert create.status == 200, "create leg failed: #{create.resp_body}"
    draft_id = first_result_id(create)
    assert String.starts_with?(draft_id, "drafts.")
    bare_id = String.replace_prefix(draft_id, "drafts.", "")
    assert length(task_rows()) == length(before) + 1

    # Leg 2 — the publish, refused.
    publish = bp_leg(:publish, %{"publish" => %{"id" => bare_id, "type" => "task"}})
    assert publish.status == 409
    body = Jason.decode!(publish.resp_body)
    assert body["error"]["code"] == "duplicate_of"
    assert body["error"]["details"]["duplicate_of"] == incumbent
    assert body["error"]["message"] =~ "was discarded"

    # THE GHOST CHECK: no new row under ANY doc_id, draft or published.
    after_refusal = task_rows()

    assert after_refusal == before,
           "the refused publish left rows behind: #{inspect(after_refusal -- before)}"

    refute Enum.any?(after_refusal, fn {_id, title, _status} -> title == @near_dup_title end)

    # Leg 3 — the CLI's follow-up discard. The server ALREADY removed the draft
    # in leg 2 (Lifecycle.discard_refused_duplicate_draft/5, re-run after the
    # batch rollback by Mutations.compensating_discard/4), so this answers 404.
    # That 404 is what `discardCreatedTaskDraftQuiet` renders as
    # "the follow-up discard was refused: document not found" + residue
    # discard_failed — a CLI misreading of a success, not a leftover row.
    discard = bp_leg(:discard, %{"discardDraft" => %{"id" => bare_id, "type" => "task"}})
    assert discard.status == 404
    assert Jason.decode!(discard.resp_body)["error"]["code"] == "not_found"
    assert task_rows() == before
  end

  test "positive control: a non-duplicate through the same path creates exactly one row" do
    _incumbent = bp_create_publish!(@incumbent_title)
    before = task_rows()

    title = "Rotate the Postfix DKIM relay sidecar keys before the quarterly audit window"
    published = bp_create_publish!(title)

    after_publish = task_rows()
    new_rows = after_publish -- before

    assert [{^published, ^title, "published"}] = new_rows
    assert length(after_publish) == length(before) + 1
  end

  # ── the bp call sequence ────────────────────────────────────────────────────

  # create → publish, both 2xx; returns the published bare id.
  defp bp_create_publish!(title) do
    new_invocation()
    create = bp_leg(:create, create_op(title))
    assert create.status == 200, "create leg failed: #{create.resp_body}"
    bare_id = create |> first_result_id() |> String.replace_prefix("drafts.", "")

    publish = bp_leg(:publish, %{"publish" => %{"id" => bare_id, "type" => "task"}})
    assert publish.status == 200, "publish leg failed: #{publish.resp_body}"
    assert first_result_id(publish) == bare_id
    bare_id
  end

  # The flat create body `runTaskCreate` builds: `_type` plus the task fields at
  # top level (never nested under content), and no `_id`.
  defp create_op(title) do
    labels = LabelFixtures.weighted_labels()

    %{
      "create" => %{
        "_type" => "task",
        "title" => title,
        "description" => labels["description"],
        "tags" => labels["tags"],
        "kind" => "task",
        "lifecycle_status" => "open",
        "priority" => 2,
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => false}]
      }
    }
  end

  defp bp_leg(leg, mutation) do
    BarkparkWeb.ConnCase.scoped_conn()
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("idempotency-key", "#{idem_base()}-#{leg}")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => [mutation]}))
  end

  # ONE key base per bp invocation, split per leg (`newIdempotencyKey` +
  # `legKey`). The plug hashes (key, token, method, path) and not the body, so a
  # base shared across two invocations would REPLAY the first create's response
  # to the second — a distinct row the CLI never shares a base with.
  defp new_invocation, do: Process.put(:idem_base, "bpidem#{System.unique_integer([:positive])}")

  defp idem_base, do: Process.get(:idem_base) || raise("bp_leg outside an invocation")

  defp first_result_id(resp) do
    [%{"id" => id} | _] = Jason.decode!(resp.resp_body)["results"]
    id
  end

  # Every type:task row in the dataset, drafts and published alike, sorted.
  defp task_rows do
    Repo.all(
      from(d in Document,
        where: d.type == "task" and d.dataset == ^@dataset,
        select: {d.doc_id, d.title, d.status},
        order_by: d.doc_id
      )
    )
  end

  defp register_task_schemas! do
    for schema_def <- Barkpark.Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset)
    end

    :ok
  end
end
