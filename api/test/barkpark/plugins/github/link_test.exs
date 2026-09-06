defmodule Barkpark.Plugins.Github.LinkTest do
  @moduledoc """
  Wave-1 slice-5: the `content.github` Link helper (epic D3).

  Round-trips `content.github` through `Link.get/put`, asserts the write is
  stamped `source="github"` on the emitted `mutation_events` row (D4 cut #2),
  patch-merges rather than clobbers, and that `synced?/1` is true ONLY when the
  stored `synced_rev` equals the task's current `_rev` (D4 cut #3).
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Plugins.Github.{Link, Outbox}

  @dataset "production"

  setup do
    # E3 tag registry: the fixture weighted tags (fixture-tag-N) these tests
    # publish must resolve to PUBLISHED type:tag docs in the dataset scope.
    Barkpark.LabelFixtures.register_tags!(@dataset)

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp mk_task!(doc_id, scope) do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" =>
            Barkpark.LabelFixtures.with_labels(%{"kind" => "task", "lifecycle_status" => "open"})
        },
        @dataset,
        scope
      )

    doc
  end

  # A published task carrying a stated acceptance criterion, so `claim_by_id/3`
  # passes the criteria fence — the CLAIMED published row is what the mirror
  # stamp used to fork a twin of.
  defp mk_claimable_published_task!(doc_id, scope) do
    {:ok, _draft} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" =>
            Barkpark.LabelFixtures.with_labels(%{
              "kind" => "task",
              "lifecycle_status" => "open",
              "acceptance_criteria" => [
                %{"criterion" => "it works", "met" => false, "evidence" => ""}
              ]
            })
        },
        @dataset,
        scope
      )

    {:ok, published} = Content.publish_document(doc_id, "task", @dataset, scope)
    published
  end

  # A task that is CREATED then PUBLISHED — the collapse path's precondition.
  defp mk_published_task!(doc_id, scope) do
    _draft = mk_task!(doc_id, scope)
    {:ok, published} = Content.publish_document(doc_id, "task", @dataset, scope)
    published
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp github_events(doc_id) do
    Repo.all(
      from e in MutationEvent,
        where: e.doc_id == ^doc_id and e.source == "github",
        order_by: e.id
    )
  end

  defp max_event_id(dataset) do
    Repo.one(from(e in MutationEvent, where: e.dataset == ^dataset, select: max(e.id))) || 0
  end

  describe "get/1" do
    test "returns nil when the task has never been mirrored", %{scope: scope} do
      task = mk_task!(uniq("gh"), scope)
      assert Link.get(task) == nil
    end

    test "reads back what put/4 wrote", %{scope: scope} do
      id = uniq("gh")
      _task = mk_task!(id, scope)

      {:ok, doc} =
        Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 42, state: "synced"}, scope)

      assert %{"repo" => "FRIKKern/barkpark", "issue" => 42, "state" => "synced"} = Link.get(doc)
    end
  end

  describe "put/4" do
    test "stamps source=\"github\" on the emitted mutation_event", %{scope: scope} do
      id = uniq("gh")
      task = mk_task!(id, scope)

      {:ok, doc} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 7}, scope)

      events = github_events(doc.doc_id)
      assert length(events) == 1
      [ev] = events
      assert ev.source == "github"
      # The bookkeeping write must not disturb the task's own content contract.
      refute doc.rev == task.rev
      assert doc.content["kind"] == "task"
      assert doc.content["lifecycle_status"] == "open"
    end

    test "patch-merges into existing content.github (partial write preserves rest)",
         %{scope: scope} do
      id = uniq("gh")
      _task = mk_task!(id, scope)

      {:ok, _} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 99}, scope)
      # A later partial write of only synced_rev must keep repo + issue.
      {:ok, doc} = Link.put(id, @dataset, %{synced_rev: "abc123"}, scope)

      assert %{
               "repo" => "FRIKKern/barkpark",
               "issue" => 99,
               "synced_rev" => "abc123"
             } = Link.get(doc)
    end

    test "returns {:error, :not_found} for an unknown task", %{scope: scope} do
      assert {:error, :not_found} =
               Link.put(uniq("ghost"), @dataset, %{repo: "x/y", issue: 1}, scope)
    end

    test "leaves a never-published task a DRAFT (no force-publish under a user)",
         %{scope: scope} do
      id = uniq("gh")
      _draft = mk_task!(id, scope)

      {:ok, _doc} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 11}, scope)

      # No published row was conjured — the bookkeeping lives on the draft.
      assert {:error, :not_found} =
               Content.get_document(Content.published_id(id), "task", @dataset, scope)

      {:ok, draft} = Content.get_document(Content.draft_id(id), "task", @dataset, scope)
      assert %{"repo" => "FRIKKern/barkpark", "issue" => 11} = Link.get(draft)
    end

    test "stamps an ALREADY-published task in place — no draft twin is ever forked (D12)",
         %{scope: scope} do
      id = uniq("gh")
      _published = mk_published_task!(id, scope)

      {:ok, _doc} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 9}, scope)

      # No draft twin exists — the stamp was written onto the published row.
      assert {:error, :not_found} =
               Content.get_document(Content.draft_id(id), "task", @dataset, scope)

      # The bookkeeping landed on the surviving published row.
      {:ok, published} = Content.get_document(Content.published_id(id), "task", @dataset, scope)
      assert %{"repo" => "FRIKKern/barkpark", "issue" => 9} = Link.get(published)
      assert published.status == "published"
    end
  end

  # ── task-aa8f25be2c04d391: the mirror stamp never forks a twin ─────────────
  describe "the stamp never forks a drafts.<id> twin (C0)" do
    # The producer this row was filed for: on a CLAIMED published task the old
    # stamp forked a draft, tried to collapse it with `publish_document`, and
    # was REFUSED whenever the claim map had moved under `Tasks.Renew` since
    # the fork — leaving the twin behind. From then on `fetch_task/3` was
    # DRAFT-FIRST, so every later pass merged into that frozen twin and was
    # refused again: the published row never saw another stamp, and the
    # bookkeeping accumulated on a row no task reader serves (measured on
    # drafts.task-49b5c183f10ad0fc, 2026-09-06, eight revisions in 45 minutes).
    test "a stale twin no longer captures the stamp — both passes land PUBLISHED",
         %{scope: scope} do
      id = uniq("gh")
      _published = mk_claimable_published_task!(id, scope)
      {:ok, claimed} = Tasks.claim_by_id(id, "gh-worker", scope)

      # The fork the mirror's own earlier pass left behind: minted from the
      # published content, claim verbatim.
      {:ok, snapshot} = Content.get_document(id, "task", @dataset, scope)

      {:ok, _twin} =
        Content.create_document(
          "task",
          %{"doc_id" => id, "title" => snapshot.title, "content" => snapshot.content},
          @dataset,
          scope
        )

      # …and the claim moves on the PUBLISHED row (this is `Tasks.Renew` every
      # ~90 s), so the twin's claim is now stale and its collapse is refused.
      {:ok, _pulsed} = Tasks.pulse_by_id(claimed.id, "gh-worker", text: "still here")

      {:ok, _} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 3}, scope)
      {:ok, mid} = Content.get_document(id, "task", @dataset, scope)
      {:ok, _} = Link.put(id, @dataset, %{synced_rev: mid.rev, state: "synced"}, scope)

      # The bookkeeping is on the row every task reader serves…
      {:ok, published} = Content.get_document(id, "task", @dataset, scope)

      assert %{"repo" => "FRIKKern/barkpark", "issue" => 3, "state" => "synced"} =
               Link.get(published)

      # …and NOT on the twin: the mirror never wrote through it.
      {:ok, twin} = Content.get_document(Content.draft_id(id), "task", @dataset, scope)
      assert Link.get(twin) == nil

      # The live claim survived byte for byte — the fenced write patches only
      # `content.github` (the old path republished a whole forked document).
      {:ok, pulsed} = Content.get_document(id, "task", @dataset, scope)
      assert pulsed.content["claim"]["worker"] == "gh-worker"
      assert pulsed.content["claim"]["epoch"] == 2
    end

    test "two stamps on a CLAIMED published task fork no twin at all",
         %{scope: scope} do
      id = uniq("gh")
      _published = mk_claimable_published_task!(id, scope)
      {:ok, claimed} = Tasks.claim_by_id(id, "gh-worker", scope)
      claim_before = claimed.content["claim"]

      {:ok, _} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 3}, scope)
      {:ok, mid} = Content.get_document(id, "task", @dataset, scope)
      {:ok, _} = Link.put(id, @dataset, %{synced_rev: mid.rev, state: "synced"}, scope)

      assert {:error, :not_found} =
               Content.get_document(Content.draft_id(id), "task", @dataset, scope)

      {:ok, published} = Content.get_document(id, "task", @dataset, scope)
      assert published.content["claim"] == claim_before
    end
  end

  describe "refusals and forks are LOUD (C1)" do
    test "a lost rev fence is RETURNED as {:error, {:stamp_refused, …}} and logged at error level",
         %{scope: scope} do
      id = uniq("gh")
      _published = mk_published_task!(id, scope)
      {:ok, stale_doc} = Content.get_document(id, "task", @dataset, scope)

      # Move the row under the caller's struct.
      {:ok, _} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 1}, scope)

      {result, log} =
        with_log(fn ->
          Link.put_on_published(stale_doc, @dataset, %{issue: 2}, scope)
        end)

      assert {:error, {:stamp_refused, %{doc_id: ^id, gate: "rev_fence"}}} = result
      assert log =~ "[error]"
      assert log =~ id
      assert log =~ "rev_fence"

      # And the refusal is a refusal: the stale write did NOT land.
      {:ok, published} = Content.get_document(id, "task", @dataset, scope)
      assert %{"issue" => 1} = Link.get(published)
    end

    test "a pre-existing draft twin is NAMED at error level and the stamp still lands published",
         %{scope: scope} do
      id = uniq("gh")
      _published = mk_published_task!(id, scope)

      # A twin minted by something else (this module can no longer make one).
      {:ok, published} = Content.get_document(id, "task", @dataset, scope)

      {:ok, _twin} =
        Content.create_document(
          "task",
          %{"doc_id" => id, "title" => published.title, "content" => published.content},
          @dataset,
          scope
        )

      {result, log} =
        with_log(fn -> Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 5}, scope) end)

      assert {:ok, %Document{}} = result
      assert log =~ "[error]"
      assert log =~ "draft_twin_present"
      assert log =~ id

      # The stamp landed on the PUBLISHED row — the row every task reader
      # serves — and the twin was NOT published over.
      {:ok, after_doc} = Content.get_document(id, "task", @dataset, scope)
      assert %{"repo" => "FRIKKern/barkpark", "issue" => 5} = Link.get(after_doc)
      assert {:ok, twin} = Content.get_document(Content.draft_id(id), "task", @dataset, scope)
      assert Link.get(twin) == nil
    end
  end

  describe "the stamp does not chase its own tail (C2)" do
    test "N mirror passes over an unchanged task write exactly ONE revision",
         %{scope: scope} do
      id = uniq("gh")
      _published = mk_claimable_published_task!(id, scope)
      {:ok, _claimed} = Tasks.claim_by_id(id, "gh-worker", scope)

      revs =
        for _ <- 1..5 do
          {:ok, before} = Content.get_document(id, "task", @dataset, scope)

          {:ok, _} =
            Link.put(
              id,
              @dataset,
              %{repo: "FRIKKern/barkpark", issue: 4, synced_rev: before.rev, state: "synced"},
              scope
            )

          {:ok, aft} = Content.get_document(id, "task", @dataset, scope)
          aft.rev
        end

      # One write, then four no-ops: the rev stops moving.
      assert length(Enum.uniq(revs)) == 1

      # And the stamp is self-consistent, so `synced?/1` answers TRUE — the
      # mirror stops re-mirroring instead of stamping the rev it just replaced.
      {:ok, final} = Content.get_document(id, "task", @dataset, scope)
      assert Link.synced?(final)
    end
  end

  describe "loop immunity (D12 capstone)" do
    test "neither the stamp NOR the collapse-publish is drainable by the Outbox",
         %{scope: scope} do
      id = uniq("gh")
      _published = mk_published_task!(id, scope)

      # Everything the setup emitted is <= max_id; only the bookkeeping path's
      # events fall strictly after it.
      max_id = max_event_id(@dataset)

      {:ok, _doc} =
        Link.put(
          id,
          @dataset,
          %{repo: "FRIKKern/barkpark", issue: 7, synced_rev: "rev-a", state: "synced"},
          scope
        )

      # HARD invariant: every mutation_event the bookkeeping path emitted — the
      # draft stamp AND the collapse publish — carries source="github", so the
      # Outbox excludes them ALL. The mirror can never re-drain its own write.
      assert Outbox.fetch(@dataset, max_id, 100) == []

      # And the (formerly-published) task carries no permanent draft twin.
      assert {:error, :not_found} =
               Content.get_document(Content.draft_id(id), "task", @dataset, scope)
    end
  end

  describe "synced?/1" do
    test "false when content.github is absent", %{scope: scope} do
      task = mk_task!(uniq("gh"), scope)
      refute Link.synced?(task)
    end

    test "false when the stored synced_rev lags the doc's current _rev", %{scope: scope} do
      id = uniq("gh")
      _task = mk_task!(id, scope)

      # The stamp write ITSELF bumps the rev, so the returned doc's _rev never
      # equals the synced_rev it just stored — documents the D4-cut-#3 reality
      # (the source=github outbox exclusion, not this equality, is the loop's
      # primary guard; this check catches coalesced/duplicate MirrorJobs).
      {:ok, doc} = Link.put(id, @dataset, %{synced_rev: "whatever"}, scope)
      refute Link.synced?(doc)
    end

    test "true exactly when synced_rev == _rev (envelope form)" do
      gh = %{"repo" => "FRIKKern/barkpark", "issue" => 3, "synced_rev" => "rev-xyz"}

      matched = %{"content" => %{"github" => gh}, "_rev" => "rev-xyz"}
      assert Link.synced?(matched)

      mismatched = %{"content" => %{"github" => gh}, "_rev" => "rev-other"}
      refute Link.synced?(mismatched)
    end

    test "true on a %Document{} whose rev matches its stored synced_rev", %{scope: scope} do
      id = uniq("gh")
      _task = mk_task!(id, scope)
      {:ok, doc} = Link.put(id, @dataset, %{repo: "FRIKKern/barkpark", issue: 5}, scope)

      # Read the live row, then hand-build a Document carrying synced_rev == its
      # own rev — proving synced?/1 keys off the %Document{}.rev field.
      {:ok, current} = Content.get_document(Content.draft_id(id), "task", @dataset, scope)
      github = Link.get(current) |> Map.put("synced_rev", current.rev)
      synced_doc = %{current | content: Map.put(current.content, "github", github)}

      assert Link.synced?(synced_doc)
      refute Link.synced?(current)
      refute Link.synced?(doc)
    end
  end
end
