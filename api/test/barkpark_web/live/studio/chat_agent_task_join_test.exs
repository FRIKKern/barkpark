defmodule BarkparkWeb.Studio.ChatAgentTaskJoinTest do
  @moduledoc """
  The Doing strip's agent↔task join, end to end (task-ba42f986bb0d4594).

  NO hand-written task frames here. Every claim is taken through
  `Tasks.claim_by_id/3` and every now-line through `Tasks.pulse_by_id/3`, so the
  `{:document_changed, …}` the LiveView folds is the one `Content.Broadcast`
  actually publishes on the workspace document topic the strip subscribes to.
  That is the point: the older strip tests send a hand-built map whose
  `claim.now` is a STRING, a shape `Tasks.Pulse` never writes (it writes
  `%{"text", "ts"}`), and that fixture is what hid the crash pinned below.

  The paths under test are the two the row names: the live
  `document_changed` fold, and the hydrate on session open (the
  `Tasks.prime/1` read plus the epic-children read beside it).
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.AgentTaskJoin
  alias Barkpark.Tasks
  alias Barkpark.TenancyFixtures
  alias BarkparkWeb.Studio.ClaudeChat

  @admin_token "chat-agent-join-admin-token"
  @dataset "production"

  # Verbatim live row (doc_id dr-w10-f1-zombied-run-remediation) and the label
  # bp-epic-cycle emits for it: the 40-character slice lands on "re-d".
  @live_long_title "A ZOMBIED run is detected but never re-dispatched — the remediation half"
  @live_label "build:a-zombied-run-is-detected-but-never-re-d"

  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()
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

    Barkpark.LabelFixtures.register_tags!(@dataset)

    {:ok, _} =
      Auth.create_token(@admin_token, "chat admin", @dataset, ["read", "write", "admin"], ws.id)

    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :studio_chat_title_http_adapter, NullTitleAdapter)
    Application.put_env(:barkpark, :studio_chat_title_cli, NullTitleCli)

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
      Application.delete_env(:barkpark, :studio_chat_title_http_adapter)
      Application.delete_env(:barkpark, :studio_chat_title_cli)
    end)

    {:ok, conn: init_test_session(conn, %{"api_token" => @admin_token}), scope: scope}
  end

  # ── ledger through the real writers ─────────────────────────────────────────

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Create + publish through the same wall `bp task create --publish` pays: the
  # claim lives on the PUBLISHED row, and the strip ignores draft twins.
  # `dedup_bypass` is the wall's own deliberate escape: the QUIET arm NEEDS two
  # near-identical titles (the live corpus holds exactly such pairs), and the
  # publish-time near-duplicate wall would otherwise refuse the second one.
  defp task!(scope, title, extra) do
    doc_id = uniq("ajt")

    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" => "agent-task join fixture #{doc_id}",
        "lifecycle_status" => "open",
        "dedup_bypass" => true,
        "acceptance_criteria" => [
          %{"criterion" => "the first thing holds", "met" => true},
          %{"criterion" => "the second thing holds", "met" => false}
        ]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())
      |> Map.merge(extra)

    {:ok, _draft} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => title, "content" => content},
        @dataset,
        scope
      )

    {:ok, pub} = Content.publish_document(doc_id, "task", @dataset, scope)
    pub
  end

  defp claim!(scope, doc, worker) do
    {:ok, claimed} = Tasks.claim_by_id(doc.doc_id, worker, scope)
    claimed
  end

  defp pulse!(doc, worker, text) do
    {:ok, pulsed} = Tasks.pulse_by_id(doc.id, worker, text: text)
    pulsed
  end

  # The builder's worker id exactly as bp-epic-cycle mints it:
  # `epic-builder-${slug(item.title)}`.
  defp builder_worker(title), do: "epic-builder-" <> AgentTaskJoin.emitter_slug(title)

  # A workflow rail whose Build phase carries the given agent labels — the
  # shape `StudioChat.set_rail_snapshot/2` persists and a reopen hydrates.
  defp rail_with(labels) do
    agents =
      for label <- labels do
        %{
          "type" => "workflow_agent",
          "phaseIndex" => 1,
          "label" => label,
          "state" => "progress",
          "startedAt" => 100
        }
      end

    %{
      "wf" => %{
        "status" => "running",
        "seq" => 1,
        "row" => %{"task_type" => "local_workflow", "description" => "wave 1"},
        "workflow" => [%{"type" => "workflow_phase", "index" => 1, "title" => "Build"} | agents]
      }
    }
  end

  defp open_session!(_conn, labels) do
    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"})
    {:ok, _} = StudioChat.set_rail_snapshot(sid, rail_with(labels))
    {sid, ClaudeChat.worker_id(sid)}
  end

  defp agent_lines(html), do: Regex.scan(~r/data-role="chat-agent-task"/, html) |> length()

  # ── criterion 0 premise: where the claim actually lives ─────────────────────

  describe "the exact-worker fold against the REAL broadcast shape" do
    # The lead's premise warning was that the fold reads content["claim"] while
    # the bp READ API serves the claim at doc.claim. Both halves are true and
    # they do not conflict: `Tasks.Query.to_render_map/3` LIFTS content.claim
    # to a top-level `claim` for the HTTP envelope, but the stored row — and
    # `msg.doc.content` in the broadcast, which is `doc.content` verbatim —
    # carry it at content["claim"]. This arm proves it through the writer.
    test "a real claim and a real pulse raise the strip; the now-line renders as text",
         %{conn: conn, scope: scope} do
      {sid, worker} = open_session!(conn, [])
      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")

      t = task!(scope, "Fix the gate latch", %{})
      claimed = claim!(scope, t, worker)
      assert claimed.content["claim"]["worker"] == worker

      html = render(view)
      assert html =~ ~s(data-role="chat-hand-task")
      assert html =~ "Fix the gate latch"
      assert html =~ "1/2 ✓"

      # The FINDING: Tasks.Pulse writes claim.now as %{"text","ts"}. The strip
      # interpolated it raw, and Phoenix.HTML.Safe has no Map implementation,
      # so the first real pulse crashed the LiveView.
      pulsed = pulse!(t, worker, "reading the brief")
      assert %{"text" => "reading the brief", "ts" => _} = pulsed.content["claim"]["now"]

      html = render(view)
      assert html =~ "reading the brief"
      assert Process.alive?(view.pid)
    end
  end

  # ── criterion 0 + 3: the epic-scoped fold, both paths ──────────────────────

  describe "the epic-parent fold surfaces epic-builder claims" do
    test "LIVE path: a builder's claim + pulse under the session's epic joins its rail label",
         %{conn: conn, scope: scope} do
      {sid, worker} = open_session!(conn, [@live_label])
      epic = task!(scope, "The epic", %{})
      slice = task!(scope, "The slice this session runs", %{"parent_id" => epic.doc_id})
      claim!(scope, slice, worker)

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      assert agent_lines(render(view)) == 0

      # the builder claims under ITS OWN worker — the exact-worker fold never
      # matches it; only the epic-parent fold can
      target = task!(scope, @live_long_title, %{"parent_id" => epic.doc_id})
      claim!(scope, target, builder_worker(@live_long_title))
      pulse!(target, builder_worker(@live_long_title), "gating the join")

      line = view |> element(~s([data-role="chat-agent-task"])) |> render()
      assert line =~ ~s(data-task-id="#{target.doc_id}")
      assert line =~ @live_label
      assert line =~ "#{target.doc_id} · 1/2 criteria · ▸ gating the join (now)"
      assert line =~ ~s(href="/admin/projects?task=#{target.doc_id}")
    end

    test "HYDRATE path: claims already on the ledger render on session open, no live frame",
         %{conn: conn, scope: scope} do
      {sid, worker} = open_session!(conn, [@live_label])
      epic = task!(scope, "The epic", %{})
      slice = task!(scope, "The slice this session runs", %{"parent_id" => epic.doc_id})
      claim!(scope, slice, worker)
      target = task!(scope, @live_long_title, %{"parent_id" => epic.doc_id})
      claim!(scope, target, builder_worker(@live_long_title))

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")

      line = view |> element(~s([data-role="chat-agent-task"])) |> render()
      assert line =~ ~s(data-task-id="#{target.doc_id}")
      assert line =~ "#{target.doc_id} · 1/2 criteria"
      assert line =~ ~s(href="/admin/projects?task=#{target.doc_id}")
      # un-pulsed: no now-line is painted, never an empty ▸
      refute line =~ "▸"
    end

    test "a builder claim under an epic this session does NOT hold never surfaces",
         %{conn: conn, scope: scope} do
      {sid, worker} = open_session!(conn, [@live_label])
      mine = task!(scope, "My epic", %{})
      slice = task!(scope, "My slice", %{"parent_id" => mine.doc_id})
      claim!(scope, slice, worker)
      other = task!(scope, "Somebody else's epic", %{})
      target = task!(scope, @live_long_title, %{"parent_id" => other.doc_id})
      claim!(scope, target, builder_worker(@live_long_title))

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      assert agent_lines(render(view)) == 0
    end
  end

  # ── criterion 2: QUIET arms + the CONTROL ─────────────────────────────────

  describe "ambiguous, absent and non-slug labels render NOTHING" do
    @colliding_a "Historical smoke record cmux smoke t2 1700"
    @colliding_b "Historical smoke record cmux smoke t2 1701"

    setup %{scope: scope} do
      epic = task!(scope, "The epic", %{})
      {:ok, epic: epic}
    end

    defp held_slice!(scope, epic, worker) do
      slice = task!(scope, "The slice this session runs", %{"parent_id" => epic.doc_id})
      claim!(scope, slice, worker)
    end

    test "QUIET: a label whose 40-char slug two siblings share renders nothing",
         %{conn: conn, scope: scope, epic: epic} do
      label = "build:" <> AgentTaskJoin.emitter_slug(@colliding_a)

      {sid, worker} =
        open_session!(conn, [label, "Digest the survey", "build:nothing-named-this"])

      held_slice!(scope, epic, worker)

      a = task!(scope, @colliding_a, %{"parent_id" => epic.doc_id})
      claim!(scope, a, builder_worker(@colliding_a))
      # the colliding sibling need not be claimed — it only has to EXIST
      task!(scope, @colliding_b, %{"parent_id" => epic.doc_id})

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      assert agent_lines(render(view)) == 0
    end

    test "CONTROL: the SAME label renders once the colliding sibling is gone",
         %{conn: conn, scope: scope, epic: epic} do
      label = "build:" <> AgentTaskJoin.emitter_slug(@colliding_a)

      {sid, worker} =
        open_session!(conn, [label, "Digest the survey", "build:nothing-named-this"])

      held_slice!(scope, epic, worker)

      a = task!(scope, @colliding_a, %{"parent_id" => epic.doc_id})
      claim!(scope, a, builder_worker(@colliding_a))

      {:ok, view, _html} = live(conn, "/studio/chat/#{sid}")
      html = render(view)
      assert agent_lines(html) == 1
      assert html =~ ~s(data-task-id="#{a.doc_id}")
    end
  end
end
