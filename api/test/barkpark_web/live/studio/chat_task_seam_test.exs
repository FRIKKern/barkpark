defmodule BarkparkWeb.Studio.ChatTaskSeamTest do
  @moduledoc """
  task-ed873c9ae56685b7: the Studio chat reads the task ledger ONLY through
  `BarkparkWeb.Studio.ChatTaskSeam`, and honours the workspace's plugin
  enablement (`PaperTaskSeam.resolver/1`: registry declaration +
  `function_exported?/3` + `Barkpark.Plugins.Enablement`).

    * TASKS DISABLED FOR THE WORKSPACE — the chat mounts a session whose
      worker holds a claim, and shows no Doing strip row, no picker toggle and
      no picker (not even an empty one); a claim taken after mount folds
      nothing; the view stays alive.
    * TASKS ENABLED (control) — the SAME fixture shows the claim, the toggle
      and the ready row, so the disabled arms are not green because the strip
      broke.
    * SOURCE — no chat file names `Barkpark.Tasks` outside the seam, by AST
      (a comment or `@moduledoc` mention is not a reference), with a control
      that the scan does see the seam's own reference.

  A mutation that reads the ledger without the seam (e.g. `Tasks.prime/1` in
  the hydrate, an ungated subscription, an unconditional picker toggle) shows
  the claim, the frame or the picker with tasks disabled, which reds the
  matching DISABLED test.

  HERMETIC: every workspace, user, session and task id is unique and created
  inside this test's sandbox transaction; nothing lands in the Default
  workspace, so no other test's dataset or strip reads it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]

  alias Barkpark.Accounts
  alias Barkpark.Content
  alias Barkpark.StudioChat
  alias Barkpark.Tasks
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Studio.ChatTaskSeam
  alias BarkparkWeb.Studio.ClaudeChat

  @ledger "production"

  defmodule NullTitleAdapter do
    def post(_url, _body, _headers), do: {:error, :disabled_in_tests}
  end

  defmodule NullTitleCli do
    def run(_binary, _args), do: {:error, :disabled_in_tests}
  end

  setup %{conn: conn} do
    Barkpark.ChatSessionResidue.purge!()

    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "cts-ws-#{System.unique_integer([:positive])}",
        name: "CTS"
      })

    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    scope = [workspace_id: ws.id]
    upsert_task_schemas!(scope)
    Barkpark.LabelFixtures.register_tags!(@ledger)

    user = register_user("cts-#{System.unique_integer([:positive])}@example.test")
    {:ok, raw} = Accounts.create_user_session_token(user)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "admin", "user")

    {:ok, session} =
      StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"}, {:workspace, ws.id})

    worker = ClaudeChat.worker_id(session.id)

    held = task!(scope, "held")
    {:ok, claimed} = Tasks.claim_by_id(held.doc_id, worker, scope)
    assert claimed.content["claim"]["worker"] == worker, "precondition: the claim did not land"

    ready = task!(scope, "ready")

    enable_fake_chat()

    %{
      conn: conn,
      ws: ws,
      scope: scope,
      raw: raw,
      sid: session.id,
      worker: worker,
      held: held,
      ready: ready,
      path: "/w/#{ws.slug}/p/default/studio/chat/#{session.id}"
    }
  end

  # ── tasks DISABLED for the workspace ──────────────────────────────────────

  describe "tasks disabled for the workspace" do
    setup ctx do
      {:ok, _} =
        Tenancy.set_workspace_plugin_settings(ctx.ws.id, %{"tasks" => %{"enabled" => false}})

      assert ChatTaskSeam.resolve(ctx.ws.id) == nil,
             "precondition: disabling tasks for the workspace did not close the seam"

      :ok
    end

    test "HYDRATE: the chat mounts with no Doing strip row for a held claim", ctx do
      view = mount!(ctx)
      assert_loaded!(view, ctx, nil)

      html = render(view)

      assert strip_ids(html) == [],
             "tasks are off, yet the Doing strip showed #{inspect(strip_ids(html))}"

      refute html =~ ctx.held.doc_id
      assert Process.alive?(view.pid)
    end

    test "PICKER: no picker toggle renders and the toggle event opens no picker", ctx do
      view = mount!(ctx)
      assert_loaded!(view, ctx, nil)

      refute render(view) =~ ~s(phx-click="toggle-task-picker"),
             "tasks are off, yet the ready-picker toggle rendered"

      html = render_click(view, "toggle-task-picker", %{})
      refute html =~ ~s(data-role="chat-task-picker"), "tasks are off, yet a ready picker opened"
      refute html =~ ctx.ready.doc_id
      assert Process.alive?(view.pid)
    end

    test "LIVE: a claim taken after mount folds nothing into the strip", ctx do
      view = mount!(ctx)
      assert_loaded!(view, ctx, nil)

      later = task!(ctx.scope, "later")
      {:ok, _} = Tasks.claim_by_id(later.doc_id, ctx.worker, ctx.scope)

      html = render(view)

      assert strip_ids(html) == [],
             "tasks are off, yet a live claim folded: #{inspect(strip_ids(html))}"

      assert Process.alive?(view.pid)
    end

    test "every seam read answers empty with no reader" do
      assert ChatTaskSeam.ready(nil, workspace_id: Ecto.UUID.generate()) == []
      assert ChatTaskSeam.held_claims(nil, "w", workspace_id: Ecto.UUID.generate()) == []
      assert ChatTaskSeam.criteria_progress(nil, %{"acceptance_criteria" => [%{}]}) == nil
      assert ChatTaskSeam.epic_children(nil, ["p"], Ecto.UUID.generate()) == []
      assert ChatTaskSeam.epic_goal(nil, "claude", Ecto.UUID.generate()) == nil
      refute ChatTaskSeam.available?(nil)
    end
  end

  # ── tasks ENABLED (control) ───────────────────────────────────────────────

  describe "tasks enabled (control)" do
    test "the same fixture shows the held claim, the toggle and the ready row", ctx do
      assert ChatTaskSeam.resolve(ctx.ws.id) == Barkpark.Tasks.PaperResolver

      view = mount!(ctx)
      assert_loaded!(view, ctx, Barkpark.Tasks.PaperResolver)

      html = render(view)
      assert strip_ids(html) == [ctx.held.doc_id]
      assert html =~ ~s(phx-click="toggle-task-picker")

      picker = render_click(view, "toggle-task-picker", %{})
      assert picker =~ ~s(data-role="chat-task-picker")
      assert picker =~ ~s(phx-value-id="#{ctx.ready.doc_id}")

      later = task!(ctx.scope, "later")
      {:ok, _} = Tasks.claim_by_id(later.doc_id, ctx.worker, ctx.scope)
      assert Enum.sort(strip_ids(render(view))) == Enum.sort([ctx.held.doc_id, later.doc_id])
    end
  end

  # ── source: no chat file names Barkpark.Tasks outside the seam ────────────

  describe "source" do
    @web_root Path.expand("../../../../lib/barkpark_web/live/studio", __DIR__)
    @core_root Path.expand("../../../../lib/barkpark", __DIR__)
    @seam Path.join(@web_root, "chat_task_seam.ex")
    @chat_live Path.join(@web_root, "chat_live.ex")

    # The one studio_chat file that still names Barkpark.Tasks, OUTSIDE the
    # studio fence: `RuntimeUsage` verifies a usage receipt against the task
    # CLAIM FENCE (`Tasks.verify_claim_fence/2`) — a write-side authority check
    # for cycle-fleet receipts, not a chat read. Recorded, not sanctioned: the
    # set must EQUAL this list, so a NEW reference reds and a removal reds as
    # stale (prune it).
    @known_outside_fence ["lib/barkpark/studio_chat/runtime_usage.ex"]

    test "no chat file names Barkpark.Tasks outside ChatTaskSeam (AST, with control)" do
      web_files = Path.wildcard(Path.join(@web_root, "chat*.ex"))

      core_files = [
        Path.join(@core_root, "studio_chat.ex")
        | Path.wildcard(Path.join(@core_root, "studio_chat/**/*.ex"))
      ]

      # Control 1: the scan reaches the view and the seam, and it DETECTS the
      # seam's own reference — so an empty offender list is not a blind scan.
      assert @chat_live in web_files
      assert @seam in web_files
      assert names_tasks?(@seam), "control: the AST scan cannot see the seam's Barkpark.Tasks"

      # Control 2: the view actually calls the seam.
      src = File.read!(@chat_live)

      for call <- ~w(ChatTaskSeam.resolve ChatTaskSeam.ready ChatTaskSeam.held_claims
                     ChatTaskSeam.epic_children ChatTaskSeam.epic_goal
                     ChatTaskSeam.criteria_progress) do
        assert src =~ call <> "(", "chat_live.ex does not call #{call}/n"
      end

      web_offenders = for f <- web_files, f != @seam, names_tasks?(f), do: rel(f)
      assert web_offenders == []

      core_offenders = for f <- core_files, names_tasks?(f), do: rel(f)
      assert Enum.sort(core_offenders) == @known_outside_fence
    end

    defp rel(path), do: Path.relative_to(path, Path.expand("../../../..", __DIR__))

    # A real reference to `Barkpark.Tasks` or one of its submodules: an
    # `__aliases__` node `[:Barkpark, :Tasks | _]`, or a multi-alias
    # `alias Barkpark.{Tasks, ...}`. Comments and strings are not in the AST.
    defp names_tasks?(path) do
      ast = path |> File.read!() |> Code.string_to_quoted!()

      {_, found} =
        Macro.prewalk(ast, false, fn
          {:__aliases__, _, [:Barkpark, :Tasks | _]} = node, _acc ->
            {node, true}

          {{:., _, [{:__aliases__, _, [:Barkpark]}, :{}]}, _, inner} = node, acc ->
            {node, acc or Enum.any?(inner, &match?({:__aliases__, _, [:Tasks | _]}, &1))}

          node, acc ->
            {node, acc}
        end)

      found
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp mount!(ctx) do
    result = live(init_test_session(ctx.conn, %{"user_session" => ctx.raw}), ctx.path)

    assert match?({:ok, _view, _html}, result),
           "the chat did not mount #{ctx.path} (got #{inspect(result)})"

    {:ok, view, _html} = result
    view
  end

  # PRECONDITION: the view is scoped to the fixture workspace, loaded the
  # fixture session (so the hydrate ran), and resolved the expected reader.
  defp assert_loaded!(view, ctx, reader) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)

    assert match?(%{id: _}, assigns[:current_workspace]) and
             assigns.current_workspace.id == ctx.ws.id,
           "precondition: the view is not scoped to the fixture workspace"

    assert assigns[:store_session_id] == ctx.sid,
           "precondition: the session did not load, so the hydrate never ran"

    assert assigns[:task_reader] == reader
  end

  defp strip_ids(html) do
    ~r/data-role="chat-hand-task"\s+data-task-id="([^"]+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  defp upsert_task_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@ledger) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @ledger, scope)
    end

    :ok
  end

  defp task!(scope, title) do
    doc_id = "cts-#{System.unique_integer([:positive])}"

    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" => "chat task seam fixture #{doc_id}",
        "lifecycle_status" => "open",
        "dedup_bypass" => true,
        "acceptance_criteria" => [%{"criterion" => "the seam gates the read", "met" => false}]
      }
      |> Map.merge(Barkpark.LabelFixtures.weighted_labels())

    {:ok, _draft} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => "#{title} #{doc_id}", "content" => content},
        @ledger,
        scope
      )

    {:ok, pub} = Content.publish_document(doc_id, "task", @ledger, scope)
    assert pub.workspace_id == scope[:workspace_id]
    pub
  end

  defp enable_fake_chat do
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
  end
end
