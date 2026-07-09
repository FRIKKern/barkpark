defmodule Barkpark.Plugins.Github.InboundEventsTest do
  @moduledoc """
  Wave 8 slice 3 — inbound event breadth (charter D14). The bookkeeping-only
  sibling of birth-only `Intake`: a deleted/transferred intake issue, or an
  outsider closing their own intake issue, becomes a VISIBLE detach — never a
  silent state.

  Every path is asserted to ACT (detach: link state flip + a `detached` conflict
  row), RECORD, or deliberately NO-OP (`:ignored`/`:dropped`). Loop-cut invariants
  are proven: bot-drop runs FIRST on every path (the App's own close echo must not
  detach) and every `Link.put` mutation-event carries `source == "github"` EXACTLY
  (outbox-excluded). No `lifecycle_status` is ever written; `kind` stays
  `"detached"` with a `detail.reason` discriminator (Health's 3-kind bucketing
  untouched).
  """

  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.{Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Plugins.Github.{Conflicts, InboundEvents, Intake, Link}

  @dataset "production"
  @repo "FRIKKern/barkpark"

  setup do
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

  # Intake births a task through the real Content path; stub the backlink comment
  # so no network is touched.
  defp intake_opts(scope) do
    scope
    |> Keyword.put(:dataset, @dataset)
    |> Keyword.put(:repo, @repo)
    |> Keyword.put(:comment_fun, fn _repo, _num, _body, _opts -> {:ok, %{"id" => 1}} end)
  end

  # InboundEvents opts: scope + dataset + repo. `:conflict_fun` defaults to the
  # real recorder so the tests assert the actual `github_sync_conflicts` rows.
  defp inbound_opts(scope) do
    scope
    |> Keyword.put(:dataset, @dataset)
    |> Keyword.put(:repo, @repo)
  end

  # Birth a born-dark `gh-<num>` intake task (state == "intake").
  defp birth_intake!(number, scope) do
    payload = opened_payload(number)
    assert {:ok, :born, doc} = Intake.ingest(payload, intake_opts(scope))
    assert Link.get(doc)["state"] == "intake"
    doc
  end

  # Birth then adopt (flip content.github.state → "adopted").
  defp adopted_task!(number, scope) do
    _doc = birth_intake!(number, scope)
    {:ok, adopted} = Link.put("gh-#{number}", @dataset, %{"state" => "adopted"}, scope)
    assert Link.get(adopted)["state"] == "adopted"
    adopted
  end

  defp opened_payload(number) do
    %{
      "action" => "opened",
      "issue" => %{
        "number" => number,
        "title" => "Outsider found a bug",
        "body" => "Steps to reproduce: click the thing."
      },
      "sender" => %{"login" => "outsider", "type" => "User"},
      "repository" => %{"full_name" => @repo}
    }
  end

  defp event_payload(action, number, overrides \\ %{}) do
    %{
      "action" => action,
      "issue" =>
        %{"number" => number, "title" => "t", "body" => "b"}
        |> Map.merge(Map.get(overrides, "issue", %{})),
      "sender" => Map.get(overrides, "sender", %{"login" => "outsider", "type" => "User"}),
      "repository" => Map.get(overrides, "repository", %{"full_name" => @repo})
    }
  end

  defp link_state(number, scope) do
    case Content.get_document(Content.draft_id("gh-#{number}"), "task", @dataset, scope) do
      {:ok, doc} -> Link.get(doc)["state"]
      _ -> nil
    end
  end

  defp detached_conflicts(number) do
    Conflicts.list(kind: "detached", repo: @repo)
    |> Enum.filter(&(&1.issue == number))
  end

  defp github_events(number) do
    like = "%gh-#{number}"

    Repo.all(
      from e in MutationEvent,
        where: like(e.doc_id, ^like),
        order_by: e.id
    )
  end

  # ── deleted / transferred → detach an existing intake task ──────────────────

  describe "deleted / transferred on an existing gh-<num> task" do
    test "deleted detaches: link state flip + detached conflict (reason deleted)",
         %{scope: scope} do
      birth_intake!(10, scope)

      assert {:ok, :detached, "gh-10"} =
               InboundEvents.handle(event_payload("deleted", 10), inbound_opts(scope))

      assert link_state(10, scope) == "detached"

      assert [conflict] = detached_conflicts(10)
      assert conflict.kind == "detached"
      assert conflict.detail["reason"] == "deleted"
      assert conflict.repo == @repo
      assert conflict.doc_id == "gh-10"
    end

    test "transferred detaches with reason transferred (OLD source-repo issue id)",
         %{scope: scope} do
      birth_intake!(11, scope)

      assert {:ok, :detached, "gh-11"} =
               InboundEvents.handle(event_payload("transferred", 11), inbound_opts(scope))

      assert link_state(11, scope) == "detached"
      assert [%{detail: %{"reason" => "transferred"}}] = detached_conflicts(11)
    end

    test "NEVER writes lifecycle_status on detach (outbound_only — no bidirectionality)",
         %{scope: scope} do
      birth_intake!(12, scope)

      assert {:ok, :detached, _} =
               InboundEvents.handle(event_payload("deleted", 12), inbound_opts(scope))

      {:ok, doc} = Content.get_document(Content.draft_id("gh-12"), "task", @dataset, scope)
      # lifecycle stays exactly as intake left it — the detach touches only
      # content.github.state, never the lifecycle.
      assert doc.content["lifecycle_status"] == "open"
    end
  end

  describe "deleted / transferred on a MISSING task → :ignored" do
    test "deleted on a never-intook issue is a deliberate 2xx no-op", %{scope: scope} do
      assert InboundEvents.handle(event_payload("deleted", 99), inbound_opts(scope)) == :ignored
      assert detached_conflicts(99) == []
      # No task, no detach — nothing minted.
      assert link_state(99, scope) == nil
    end

    test "transferred on a never-intook issue is :ignored", %{scope: scope} do
      assert InboundEvents.handle(event_payload("transferred", 98), inbound_opts(scope)) ==
               :ignored

      assert detached_conflicts(98) == []
    end
  end

  # ── closed → detach ONLY an intake task closed by a human ───────────────────

  describe "closed on an intake task by a non-bot sender" do
    test "detaches with reason closed_by_author", %{scope: scope} do
      birth_intake!(20, scope)

      assert {:ok, :detached, "gh-20"} =
               InboundEvents.handle(event_payload("closed", 20), inbound_opts(scope))

      assert link_state(20, scope) == "detached"
      assert [%{detail: %{"reason" => "closed_by_author"}}] = detached_conflicts(20)
    end
  end

  describe "closed that must NOT detach" do
    test "Bot-sender close → :dropped, NO detach (the App's own close echo)",
         %{scope: scope} do
      birth_intake!(21, scope)

      payload =
        event_payload("closed", 21, %{"sender" => %{"login" => "barkpark[bot]", "type" => "Bot"}})

      assert InboundEvents.handle(payload, inbound_opts(scope)) == :dropped

      # The intake link is untouched — a bot close never detaches.
      assert link_state(21, scope) == "intake"
      assert detached_conflicts(21) == []
    end

    test "adopted-task close → :ignored (the outbound loop owns that surface)",
         %{scope: scope} do
      adopted_task!(22, scope)

      assert InboundEvents.handle(event_payload("closed", 22), inbound_opts(scope)) == :ignored

      # State stays adopted; no detach, no conflict.
      assert link_state(22, scope) == "adopted"
      assert detached_conflicts(22) == []
    end

    test "close on a never-intook issue → :ignored", %{scope: scope} do
      assert InboundEvents.handle(event_payload("closed", 23), inbound_opts(scope)) == :ignored
      assert detached_conflicts(23) == []
    end
  end

  # ── bot-drop FIRST on every path (D4 cut #1) ────────────────────────────────

  describe "bot-drop runs first on every action" do
    test "a Bot-sender deleted → :dropped, NO detach", %{scope: scope} do
      birth_intake!(30, scope)

      payload =
        event_payload("deleted", 30, %{"sender" => %{"type" => "Bot", "login" => "x[bot]"}})

      assert InboundEvents.handle(payload, inbound_opts(scope)) == :dropped
      assert link_state(30, scope) == "intake"
      assert detached_conflicts(30) == []
    end
  end

  # ── loop-cut #2: every detach write is source="github" EXACTLY ──────────────

  describe "loop cut #2 — source=\"github\" on the detach Link.put row" do
    test "the detach mutation-event carries source \"github\" (outbox-excluded)",
         %{scope: scope} do
      birth_intake!(40, scope)
      before = github_events(40)

      assert {:ok, :detached, _} =
               InboundEvents.handle(event_payload("deleted", 40), inbound_opts(scope))

      after_events = github_events(40)

      # The detach added at least one new mutation-event.
      assert length(after_events) > length(before)
      # EVERY event on this task — birth AND the detach stamp — is source "github",
      # so the outbox excludes them and no inbound write ever echoes back out.
      assert Enum.all?(after_events, &(&1.source == "github"))
      refute Enum.any?(after_events, &(&1.source == "github:inbound"))
    end
  end

  # ── the injectable conflict recorder seam ───────────────────────────────────

  describe "conflict_fun seam" do
    test "the recorder receives kind \"detached\" + the reason discriminator",
         %{scope: scope} do
      birth_intake!(50, scope)
      test_pid = self()

      opts =
        inbound_opts(scope)
        |> Keyword.put(:conflict_fun, fn attrs ->
          send(test_pid, {:conflict, attrs})
          {:ok, %{id: 1}}
        end)

      assert {:ok, :detached, "gh-50"} =
               InboundEvents.handle(event_payload("transferred", 50), opts)

      assert_receive {:conflict, attrs}
      assert attrs.kind == "detached"
      assert attrs.detail["reason"] == "transferred"
      assert attrs.issue == 50
      assert attrs.repo == @repo
      assert attrs.doc_id == "gh-50"
      assert attrs.dataset == @dataset
    end

    test "a raising recorder is swallowed — the detach still stands", %{scope: scope} do
      birth_intake!(51, scope)

      opts =
        inbound_opts(scope)
        |> Keyword.put(:conflict_fun, fn _attrs -> raise "recorder down" end)

      # The durable state flip already committed; a flaky recorder never rolls it
      # back or fails the delivery.
      assert {:ok, :detached, "gh-51"} =
               InboundEvents.handle(event_payload("deleted", 51), opts)

      assert link_state(51, scope) == "detached"
    end
  end

  # ── robustness: bot-drop + non-inbound actions + missing issue ──────────────

  describe "guards" do
    test "an unrouted action (reopened) is :ignored", %{scope: scope} do
      birth_intake!(60, scope)
      assert InboundEvents.handle(event_payload("reopened", 60), inbound_opts(scope)) == :ignored
      assert link_state(60, scope) == "intake"
    end

    test "a payload without an issue is :ignored", %{scope: scope} do
      payload = %{"action" => "deleted", "sender" => %{"type" => "User"}}
      assert InboundEvents.handle(payload, inbound_opts(scope)) == :ignored
    end
  end
end
