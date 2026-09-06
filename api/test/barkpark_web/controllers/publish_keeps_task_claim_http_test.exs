defmodule BarkparkWeb.PublishKeepsTaskClaimHttpTest do
  @moduledoc """
  task-9b5e1a6a688d27fc, ARM 2 — the filed sequence driven through the SAME
  HTTP routes the Go CLI calls, not through the context functions.

  `bp doc patch <type> <id> --set k:=v` and `bp doc publish <type> <id>` are
  manifest-driven (`GET /v1/capabilities` declares them with a mutation_op) and
  both POST `/v1/data/mutate/:dataset` — `internal/cli/mutate_perspective.go`
  names `doc patch` in `mutatePerspectiveVerbs` as one of the verbs on "the doc
  mutation path", and `doc publish` as one of the verbs that IS the act moving
  the published lens. `bp task claim <id> <worker>` is
  `POST /v1/tasks/:doc_id/claim` (plugins/tasks.ex:538).

  THE THREE DIFFERENCES from the context-level pins in
  `test/barkpark/content/publish_keeps_task_claim_test.exs`, reproduced here
  verbatim as the lead measured them on guerrilla:

    1. the row carried ZERO acceptance_criteria when it was claimed (a
       zero-criteria `kind:task`, claimed with the sanctioned
       `criteria_unstated_override`);
    2. the patch ADDED a 4-item `acceptance_criteria` list rather than editing
       an existing one;
    3. the patch and the publish were two SEPARATE calls, with the claim
       between the publish-at-birth and the patch.

  IT DOES NOT REPRODUCE, and the row's own revision log says why. Read live off
  guerrilla (which serves this exact commit — `/status.json` → `2fe7ddd3a`):

      bp doc history task task-49b5c183f10ad0fc --limit 60

      2026-09-06T10:27:35Z  draft      update   67c757fb
      … seven more `draft update`s, no publish …
      2026-09-06T09:42:07Z  draft      create   ec25397e
      2026-09-06T09:38:26Z  published  publish  6c49a5e3
      2026-09-06T09:38:25Z  draft      create   7eccfa1f
      2026-09-06T09:28:13Z  published  publish  e3b6e06c
      2026-09-06T09:28:12Z  draft      create   d9d6b193
      2026-09-06T09:27:26Z  published  publish  b4e7801c
      2026-09-06T09:27:25Z  draft      create   87c402e8

  Neither `f2677c9d` nor `33f0a390` — the two revs the filing names for its
  patch and its publish — appears anywhere in the 19 revisions this row has
  held since 2026-08-31. `b4e7801c`, which the filing calls "the read", is a
  PUBLISH at 09:27:26. So the citation does not match the row.

  A `draft create` followed ~1s later by a `publish` IS the pre-#16023
  draft-first shape. But even that shape preserves the claim on this code, and
  the mutation proof says so: forcing `get_patch_base/4` back to draft-first
  (`if false and published_first_patch?(id, type)`, recompiled — 890 files)
  leaves this test GREEN, because `draft_first_patch_base/4` falls back to the
  PUBLISHED row when no twin exists, so the forked draft carries the claim
  verbatim. Losing the claim needs a draft forked BEFORE the claim, and
  `stale_claim?/2` refuses to publish one (pinned in
  `test/barkpark/content/publish_keeps_task_claim_test.exs`).

  WHAT THE ROW ACTUALLY SHOWS, and it is worth the lead's attention:

      published  task-49b5c183f10ad0fc         lifecycle done, claim closed_by
                                               lead-security @09:56:20, epoch 2
      draft      drafts.task-49b5c183f10ad0fc  lifecycle OPEN, claim epoch 2 with
                                               expired_at @10:27:00

  The row is forked RIGHT NOW: a live draft twin, last written at 10:27:35,
  carrying `lifecycle_status: "open"` and a TTL-REAPED claim, sitting beside a
  published row that is closed. The task door wrote that twin — `expired_at` is
  `Tasks.TtlSweeper`'s reap stamp — so the sweeper swept the DRAFT while the
  published row was already `done`. That is the real "two writers, one row"
  disagreement behind the report, and it is a different defect from the one the
  filing describes. Publishing that twin is what would reopen the row; today
  `stale_claim?/2` refuses it, and the fence this PR adds refuses it a second
  time on `close_reason`/`landed`.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, LabelFixtures, Tasks, TenancyFixtures}
  alias Barkpark.Content.DraftId

  @token "barkpark-pkc-http-token"
  @dataset "production"

  setup do
    {:ok, _} = Auth.create_token(@token, "pkc-http", "test", ["read", "write", "admin"])
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mutate(conn, mutations) do
    conn
    |> authed()
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  # The 4-item list the lead's `--set 'acceptance_criteria:=<json>'` carried.
  defp four_criteria do
    for n <- 1..4 do
      %{"criterion" => "criterion #{n} written by the lead", "met" => false, "evidence" => ""}
    end
  end

  test "bp task claim -> bp doc patch -> bp doc publish, over the CLI's own routes",
       %{conn: conn, scope: scope} do
    id = uniq("pkc-http-task")

    # ── `bp task create … --publish`: a ZERO-criteria kind:task, born and
    # published minutes before the claim. Publishing deletes the draft, so no
    # pre-claim draft of the LEAD's making survives — whether the SERVER forks
    # one is the question this test asks.
    birth_resp =
      mutate(conn, [
        %{
          "create" => %{
            "_id" => id,
            "_type" => "task",
            "title" => id,
            "content" =>
              LabelFixtures.with_registered_labels(
                %{"kind" => "task", "lifecycle_status" => "open"},
                @dataset
              )
          }
        },
        %{"publish" => %{"id" => id, "type" => "task"}}
      ])

    assert birth_resp.status == 200, "the birth was refused: #{birth_resp.resp_body}"

    assert {:error, :not_found} =
             Content.get_document(DraftId.draft_id(id), "task", @dataset, scope)

    {:ok, born} = Content.get_document(id, "task", @dataset, scope)
    refute Map.has_key?(born.content, "acceptance_criteria")

    # ── `bp task claim <id> <worker> --yes` on the zero-criteria row.
    claim_resp =
      conn
      |> authed()
      |> post(
        "/v1/tasks/#{id}/claim",
        Jason.encode!(%{
          "worker_id" => "lead-security",
          "criteria_unstated_override" => "writing the criteria onto the row I hold"
        })
      )

    assert claim_resp.status == 200
    claim_payload = Jason.decode!(claim_resp.resp_body)
    assert claim_payload["ok"] == true
    assert claim_payload["doc"]["lifecycle_status"] == "in_progress"
    assert claim_payload["doc"]["claim"]["worker"] == "lead-security"
    assert claim_payload["doc"]["claim"]["epoch"] == 1

    {:ok, claimed} = Content.get_document(id, "task", @dataset, scope)
    claim = claimed.content["claim"]
    assert claim["worker"] == "lead-security"

    # ── CALL 1: `bp doc patch task <id> --set 'acceptance_criteria:=[…]' --yes`
    patch_resp =
      mutate(conn, [
        %{
          "patch" => %{
            "id" => id,
            "type" => "task",
            "set" => %{"acceptance_criteria" => four_criteria()}
          }
        }
      ])

    assert patch_resp.status == 200,
           "the patch itself was refused: #{patch_resp.resp_body}"

    # THE DECISIVE RECEIPT. On this code the patch resolves PUBLISHED-first and
    # `land_patch/5` publishes what it wrote (#16023, 2026-09-04), so the receipt
    # names the BARE id with `_draft: false` — there is no draft left to publish.
    # The filing's step 2 recorded the opposite ("draft written, rev f2677c9d"),
    # which is the PRE-#16023 shape; that divergence is the evidence that the
    # measured run did not execute this code.
    [patch_result] = Jason.decode!(patch_resp.resp_body)["results"]
    assert patch_result["id"] == id
    assert patch_result["document"]["_draft"] == false
    patched_rev = patch_result["document"]["_rev"]

    assert {:error, :not_found} =
             Content.get_document(DraftId.draft_id(id), "task", @dataset, scope),
           "the patch must leave no draft twin behind"

    # ── CALL 2: `bp doc publish task <id> --yes`, a SEPARATE request.
    publish_resp = mutate(conn, [%{"publish" => %{"id" => id, "type" => "task"}}])

    assert publish_resp.status == 200,
           "the publish was refused: #{publish_resp.resp_body}"

    # The publish is a NOOP on the SAME rev — its whole effect is already on the
    # published row. The filing recorded a publish that minted a NEW rev
    # (33f0a390 after the patch's f2677c9d); a publish that writes nothing cannot
    # produce a new rev, so the two revs are a second independent signal that the
    # measured server was not running this code.
    [publish_result] = Jason.decode!(publish_resp.resp_body)["results"]
    assert publish_result["operation"] == "noop"

    assert publish_result["document"]["_rev"] == patched_rev,
           "a NOOP publish must not mint a new rev"

    # ── `bp task get <id>` — the read the lead did, through the task read door.
    get_resp = conn |> authed() |> get("/v1/tasks/#{id}")
    assert get_resp.status == 200
    doc = Jason.decode!(get_resp.resp_body)["doc"]

    assert length(doc["content"]["acceptance_criteria"]) == 4, "the criteria must land"

    assert doc["lifecycle_status"] == "in_progress",
           "THE FILED DEFECT: publish reopened the row — lifecycle_status is " <>
             inspect(doc["lifecycle_status"])

    assert doc["claim"]["worker"] == "lead-security",
           "THE FILED DEFECT: publish dropped the claim — claim is " <>
             inspect(doc["claim"])

    assert doc["claim"]["epoch"] == claim["epoch"],
           "publish moved the epoch: #{inspect(doc["claim"])}"

    # And the stored row agrees with what the read door serves.
    {:ok, stored} = Content.get_document(id, "task", @dataset, scope)
    assert stored.content["lifecycle_status"] == "in_progress"
    assert stored.content["claim"] == claim
  end
end
