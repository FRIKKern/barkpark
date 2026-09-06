defmodule BarkparkWeb.WallRefusalKeepsClaimedDraftTest do
  @moduledoc """
  A REFUSAL MUST NOT DESTROY A LIVE CLAIM (task-8e9005bee4d20ed5).

  The sibling file `wall_refusal_leaves_no_draft_test.exs` pins the rule this
  one carves the exception out of: a `duplicate_of` refusal discards the draft
  it refused, because an unreachable `drafts.<id>` is what the 2026-09-04
  census counted 409 of.

  But a `type:task` draft can carry `content.claim` — the map `Tasks.Claim`
  writes and `Tasks.Close` CAS's on. Observed 2026-09-06 (request_id
  GNK2icDy2EdMC2EAACHB): a draft-only task was created, CLAIMED, then published
  into a near-duplicate refusal — and afterwards the bare id, the `drafts.` id
  and `bp task ls` all answered 404/empty. The refusal deleted a live lease,
  with no row left to pulse, to close, or to read, and no event saying where
  the work went.

  Same ruling as the publish SUCCESS arm (task-9b5e1a6a688d27fc,
  `Lifecycle.task_door_field_fence/2`): the DOCUMENT door yields. A publish
  naming no task-door field has no authorial intent about the claim, so it may
  neither silently rewrite it nor destroy it. One contract across both arms.

  Measured through the real `POST /v1/data/mutate` door for the same reason the
  sibling is: a Repo-level assertion cannot see the rollback the mutate
  transaction performs, and `Mutations.compensating_discard/4` re-runs the
  delete AFTER that rollback — so the batch door is where a half-fix shows.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.LabelFixtures
  alias Barkpark.Repo

  @dataset "test"

  # Long and distinctive: `DedupWall` scores Jaccard over title + tag NAME
  # tokens and needs >= 3 shared tokens before it may refuse at all.
  @title "Backfill the denormalized main tag column onto every published document row"

  @claim %{
    "worker" => "cli-w14-probe",
    "epoch" => 1,
    "ts_iso" => "2026-09-06T13:58:07.248072Z"
  }

  setup do
    Barkpark.Auth.create_token("barkpark-dev-token", "dev", @dataset, ["read", "write", "admin"])
    register_task_schemas!()
    LabelFixtures.register_tags!(@dataset)
    :ok
  end

  test "a duplicate_of refusal KEEPS a draft that carries a live claim, and says so", %{
    conn: conn
  } do
    publish_incumbent!("task-incumbent-claimed", @title)
    create_draft!("task-claimed-near-dup", @title, content: task_content(%{"claim" => @claim}))

    # Precondition, asserted rather than assumed: without it the survival
    # assertion below could pass on a draft that was never there.
    assert draft_row("drafts.task-claimed-near-dup"),
           "fixture draft must exist before the publish"

    resp = mutate(conn, [%{"publish" => %{"id" => "task-claimed-near-dup", "type" => "task"}}])

    # The refusal itself is unchanged: still 409 duplicate_of, still naming the
    # incumbent. This fix does not make a refused publish succeed.
    assert resp.status == 409
    body = Jason.decode!(resp.resp_body)
    assert body["error"]["code"] == "duplicate_of"
    assert body["error"]["details"]["duplicate_of"] == "task-incumbent-claimed"

    # THE ASSERTION A REGRESSION REDS ON: the claimed draft — and the lease on
    # it — survived the refusal.
    assert draft_row("drafts.task-claimed-near-dup"),
           "the refusal destroyed a CLAIMED draft, taking its live lease with it"

    # And the claim itself is intact, not merely the row.
    assert {:ok, %Document{content: content}} =
             Content.get_document("drafts.task-claimed-near-dup", "task", @dataset)

    assert content["claim"]["worker"] == "cli-w14-probe"
    assert content["claim"]["epoch"] == 1

    # The message must not keep asserting the discard that did not happen, and
    # must name the verb that owns the claim.
    message = body["error"]["message"]
    assert message =~ "cli-w14-probe"
    assert message =~ "bp task release"
    refute message =~ "left nothing behind"
  end

  test "an UNCLAIMED draft is still discarded by the same refusal", %{conn: conn} do
    # The exception is keyed on the claim, not widened into a general amnesty:
    # this is the sibling file's rule, re-run here so a fix that simply stopped
    # discarding cannot pass this file.
    publish_incumbent!("task-incumbent-unclaimed", @title)
    create_draft!("task-unclaimed-near-dup", @title, [])

    assert draft_row("drafts.task-unclaimed-near-dup")

    resp = mutate(conn, [%{"publish" => %{"id" => "task-unclaimed-near-dup", "type" => "task"}}])

    assert resp.status == 409
    refute draft_row("drafts.task-unclaimed-near-dup")
    assert Jason.decode!(resp.resp_body)["error"]["message"] =~ "discarded"
  end

  test "a claim map with no worker is not a lease — that draft is discarded", %{conn: conn} do
    # `Tasks.Release` / `TtlSweeper` can leave a claim map behind without a
    # holder. Keying on the map's mere PRESENCE would strand those drafts
    # forever; the fence reads `claim.worker`.
    publish_incumbent!("task-incumbent-workerless", @title)

    create_draft!("task-workerless-near-dup", @title,
      content: task_content(%{"claim" => %{"epoch" => 2, "worker" => ""}})
    )

    resp = mutate(conn, [%{"publish" => %{"id" => "task-workerless-near-dup", "type" => "task"}}])

    assert resp.status == 409
    refute draft_row("drafts.task-workerless-near-dup")
  end

  # ── fixtures ────────────────────────────────────────────────────────────────

  defp mutate(conn, mutations) do
    conn
    |> put_req_header("authorization", "Bearer barkpark-dev-token")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/data/mutate/#{@dataset}", Jason.encode!(%{"mutations" => mutations}))
  end

  defp task_content(extra) do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "priority" => 1,
      "acceptance_criteria" => [%{"criterion" => "the fixture is closeable", "met" => true}]
    }
    |> Map.merge(LabelFixtures.weighted_labels())
    |> Map.merge(extra)
  end

  # Born through the same `POST /v1/data/mutate` door the subject uses: a raw
  # `Repo.insert!` row (workspace_id NULL) is invisible to the workspace-scoped
  # read the publish performs, and every assertion would measure a 404.
  defp publish_incumbent!(id, title) do
    create_draft!(id, title, [])
    resp = mutate(scoped_conn_authed(), [%{"publish" => %{"id" => id, "type" => "task"}}])
    assert resp.status == 200, "incumbent fixture failed to publish: #{resp.resp_body}"
    :ok
  end

  # A SEPARATE request on purpose: the point is a draft already durable when
  # the publish is refused, which a single-batch create+publish (rolled back as
  # one) can never reproduce.
  defp create_draft!(id, title, opts) do
    content = Keyword.get_lazy(opts, :content, fn -> task_content(%{}) end)

    resp =
      mutate(scoped_conn_authed(), [
        %{"create" => %{"_id" => id, "_type" => "task", "title" => title, "content" => content}}
      ])

    assert resp.status == 200, "draft fixture #{id} failed to create: #{resp.resp_body}"
    :ok
  end

  defp scoped_conn_authed, do: BarkparkWeb.ConnCase.scoped_conn()

  defp draft_row(doc_id) do
    Repo.one(
      from(d in Document,
        where: d.doc_id == ^doc_id and d.type == "task" and d.dataset == ^@dataset,
        select: d.doc_id
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
