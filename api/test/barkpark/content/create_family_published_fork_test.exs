defmodule Barkpark.Content.CreateFamilyPublishedForkTest do
  @moduledoc """
  The create family's published-first fence (task-f0de48637a21d3dc).

  `patch` on a bare `type:task` id has been published-first and transactional
  since task-b9c618482e688500. The CREATE family never was: `create`,
  `createOrReplace` and `createIfNotExists` resolve `existing` from
  `DraftId.draft_id(id)` alone while `Writer.create_document/4` always
  draft-prefixes its write target, so naming an id that already has a PUBLISHED
  task row minted a `drafts.<id>` twin carrying `claim: null` /
  `lifecycle_status: "open"` beside a claimed, in-progress published row — and
  every task birth guard (`ensure_claim_not_dropped`,
  `ensure_task_close_is_cas`, `ensure_disposition_via_verb`,
  `ensure_adoption_adjudicated`) was structurally exempt, because each has an
  explicit `nil`-existing head. The receipt said rc=0. Measured on guerrilla
  2026-09-10: 354 of 8625 published task rows carry that twin, 218 disagreeing
  with their published row on `lifecycle_status` and 244 on `claim`.

  The ruling this file pins, split on whether anybody holds the row RIGHT NOW:

    * LIVE claim → REFUSED, 422 `invalid_task_content` naming the published id,
      the `drafts.<id>` it would have minted, and the sanctioned verbs.
    * no live claim → lands exactly as before, plus a `create.forked_published`
      advisory on the `Warnings` channel the patch door uses for
      `patch.forked_published`.

  "Live" is not re-derived here: it is `Tasks.QueueGate.execution_class/2` with
  a nil worker, which is live in three parts (non-blank worker, no close stamp,
  lease not lapsed against `:task_lease_ttl_seconds`). The lapsed-lease case
  below is what proves the TTL leg is actually consulted rather than "has a
  claim map".

  Negative arms that must stay UNCHANGED: a birth on a fresh id, and a
  `source: :sync` write (the replica mirrors upstream rows with
  `createOrReplace` + the full remote document; a refusal there rolls the whole
  batch back with no operator recourse).
  """
  # sync: swaps node-global Application env (`:barkpark, :task_lease_ttl_seconds`) — one value for the whole node
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.Warnings

  @dataset "production"
  @token "barkpark-test-create-fork-fence-token"
  @code "create.forked_published"

  setup do
    {:ok, _} = Auth.create_token(@token, "test-create-fork", "test", ["read", "write", "admin"])
    Barkpark.LabelFixtures.register_tags!(@dataset)
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

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp task_content(extra) do
    %{
      "kind" => "task",
      "lifecycle_status" => "open",
      "description" => "create-fork fixture #{System.unique_integer([:positive])}",
      "acceptance_criteria" => [%{"criterion" => "the fixture publishes", "met" => false}]
    }
    |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
    |> Map.merge(extra)
  end

  # A PUBLISHED task row at the bare id, no draft twin left behind.
  defp publish_task!(doc_id, scope, extra \\ %{}) do
    {:ok, _draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => "Create fork fixture #{doc_id}",
          "content" => task_content(extra)
        },
        @dataset,
        scope
      )

    {:ok, pub} = Content.publish_document(doc_id, "task", @dataset, scope)

    assert {:error, :not_found} =
             Content.get_document("drafts." <> doc_id, "task", @dataset, scope)

    pub
  end

  defp claim!(doc_id, scope, worker) do
    assert {:ok, claimed} = Tasks.claim_by_id(doc_id, worker, scope)
    assert claimed.content["lifecycle_status"] == "in_progress"
    assert claimed.content["claim"]["worker"] == worker
    claimed
  end

  defp attrs_for(doc_id),
    do: %{
      "_id" => doc_id,
      "_type" => "task",
      "title" => "FORKED by the create family",
      "content" => task_content(%{})
    }

  defp mutate(ops, scope, extra \\ []) do
    Content.apply_mutations(ops, @dataset, Keyword.merge([source: :api] ++ scope, extra))
  end

  defp twin?(doc_id, scope) do
    match?({:ok, _}, Content.get_document("drafts." <> doc_id, "task", @dataset, scope))
  end

  # ── the refusal: a LIVE claim on the published row ────────────────────────

  for {label, verb} <- [
        {"createOrReplace", "createOrReplace"},
        {"create", "create"},
        {"createIfNotExists", "createIfNotExists"}
      ] do
    test "#{label} naming a published task with a LIVE claim is REFUSED and mints no twin", %{
      scope: scope
    } do
      id = uniq("cf-live")
      publish_task!(id, scope)
      claim!(id, scope, "cf-worker-a")

      assert {:error, {:invalid_task_content, %{"_id" => [message]}}} =
               mutate([%{unquote(verb) => attrs_for(id)}], scope)

      # The refusal NAMES all three things the row demands.
      assert message =~ "`#{id}`", message
      assert message =~ "drafts.#{id}", message
      assert message =~ "bp task release #{id}", message
      assert message =~ "bp task close #{id}", message
      assert message =~ "bp doc patch task #{id}", message
      assert message =~ "cf-worker-a", message

      refute twin?(id, scope),
             "the refusal must be transactional — no drafts.#{id} may survive it"

      # The published row is untouched: still claimed, still in progress.
      assert {:ok, pub} = Content.get_document(id, "task", @dataset, scope)
      assert pub.content["claim"]["worker"] == "cf-worker-a"
      assert pub.content["lifecycle_status"] == "in_progress"
    end
  end

  test "the legacy POST /api/documents/task door is fenced by the same predicate", %{
    conn: conn,
    scope: scope
  } do
    id = uniq("cf-legacy")
    publish_task!(id, scope)
    claim!(id, scope, "cf-worker-legacy")

    resp =
      conn
      |> put_req_header("authorization", "Bearer #{@token}")
      |> post("/api/documents/task?id=#{id}", %{"title" => "FORKED through the legacy door"})
      |> json_response(422)

    assert resp["code"] == "validation_failed" or resp["error"]["code"] == "validation_failed",
           inspect(resp)

    assert inspect(resp) =~ "drafts.#{id}"
    refute twin?(id, scope)
  end

  # ── the negative arms: what must NOT change ───────────────────────────────

  test "a birth on a FRESH id is untouched", %{scope: scope} do
    id = uniq("cf-fresh")

    assert {:ok, {_tx, [%{id: written}]}} =
             mutate([%{"create" => attrs_for(id)}], scope)

    assert written == "drafts." <> id
    assert twin?(id, scope)
  end

  test "a source: :sync write onto a LIVE-claimed published row is exempt", %{scope: scope} do
    id = uniq("cf-sync")
    publish_task!(id, scope)
    claim!(id, scope, "cf-worker-sync")

    assert {:ok, {_tx, [_result]}} =
             mutate([%{"createOrReplace" => attrs_for(id)}], scope, source: :sync)

    assert twin?(id, scope), "replication must still land its mirror write"
  end

  test "a caller who names drafts.<id> explicitly is not fenced", %{scope: scope} do
    id = uniq("cf-explicit")
    publish_task!(id, scope)
    claim!(id, scope, "cf-worker-explicit")

    attrs = Map.put(attrs_for(id), "_id", "drafts." <> id)
    assert {:ok, {_tx, [_result]}} = mutate([%{"createOrReplace" => attrs}], scope)
    assert twin?(id, scope)
  end

  # ── the advisory: a published row with NO live claim ──────────────────────

  defp warned_mutate(ops, scope) do
    Warnings.reset()
    result = mutate(ops, scope)
    {result, Warnings.drain()}
  end

  test "an UNCLAIMED published row still lands, and the receipt carries the fork warning", %{
    scope: scope
  } do
    id = uniq("cf-unclaimed")
    publish_task!(id, scope)

    {result, warnings} = warned_mutate([%{"createOrReplace" => attrs_for(id)}], scope)

    assert {:ok, {_tx, [_r]}} = result
    assert twin?(id, scope), "no live claim — the write must land exactly as before"

    entry = Enum.find(warnings, &(&1.code == @code))
    assert entry, "expected a #{@code} advisory, got: #{inspect(warnings)}"
    assert entry.severity == "warning"
    assert entry.message =~ "drafts.#{id}"
    assert entry.message =~ "published-first" or entry.message =~ "keeps serving it"
    assert entry.message =~ "bp doc publish task #{id}"
  end

  test "a LAPSED lease is not a live claim — the TTL leg of the predicate is consulted", %{
    scope: scope
  } do
    id = uniq("cf-lapsed")
    publish_task!(id, scope)
    claim!(id, scope, "cf-worker-lapsed")

    previous = Application.get_env(:barkpark, :task_lease_ttl_seconds)
    Application.put_env(:barkpark, :task_lease_ttl_seconds, 0)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:barkpark, :task_lease_ttl_seconds)
        value -> Application.put_env(:barkpark, :task_lease_ttl_seconds, value)
      end
    end)

    {result, warnings} = warned_mutate([%{"createOrReplace" => attrs_for(id)}], scope)

    assert match?({:ok, {_tx, [_r]}}, result),
           "a claim whose lease has lapsed holds nothing — the write must land, got: #{inspect(result)}"

    assert Enum.any?(warnings, &(&1.code == @code)),
           "the lapsed-lease path is the advisory path, got: #{inspect(warnings)}"
  end
end
