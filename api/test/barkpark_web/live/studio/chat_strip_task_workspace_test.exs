defmodule BarkparkWeb.Studio.ChatStripTaskWorkspaceTest do
  @moduledoc """
  The Studio chat's Doing strip and ready picker read the task ledger in the
  VIEWER's workspace, never the instance Default (task-180a07e9d178d6a8).

  ## The defect

  `ChatLive.hand_task_scope/0` was arity zero: it read
  `Tenancy.get_default_workspace/0` for every viewer on every mount, and so did
  the live subscription beside it. ChatLive is also mounted inside
  `live_session :scoped_admin_studio` behind `{LiveAuth, :scoped_admin}`, a gate
  that proves admin in the URL workspace and nothing more. So an admin of
  workspace A ONLY was shown the Default workspace's ready queue and the
  Default workspace's claims held by this session's worker, and never saw the
  claims its own agent took in A.

  ## Why A is the scope the writer writes in

  `ensure_session/1` stamps a new session's `owner_workspace_id` from
  `:current_workspace`; the agent's task token is minted into that same
  workspace (`Provider.Claude.mint_workspace_id/2`, arm 1); and the flat
  `/v1/tasks` routes run `DeriveWorkspaceFromToken` before `AssignDefaultScope`,
  so every claim, pulse and create that agent makes lands in A. The strip must
  read A to show them, and must read ONLY A so no other tenant's row is shown.

  ## The arms

  Three workspaces: A (the viewer's), B (a foreign tenant) and the seeded
  Default. The SAME worker id holds a claim in all three, so the only thing
  that can decide what the strip shows is the workspace it reads.

    * hydrate path: claims exist before mount; the strip must show A's only.
    * live path: mount first (strip empty), claim after, so the rows can only
      arrive as `{:document_changed, ...}` frames.
    * ready picker: an open task in each workspace; the picker must list A's.
    * POSITIVE CONTROL: a flat Default admin still sees its Default claim, so
      the arms above are not passing because the strip broke.

  HERMETIC: every workspace, user, session and task id is unique and created
  inside this test's sandbox transaction.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]

  alias Barkpark.Accounts
  alias Barkpark.Content
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.TaskLedgerScope
  alias Barkpark.Tasks
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.TenancyFixtures
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
    {default_ws, default_proj} = TenancyFixtures.ensure_default_scope!()

    ws_a = workspace!("strip-ws-a")
    ws_b = workspace!("strip-ws-b")

    # The writer's scope per workspace, as the flat /v1/tasks pipeline resolves
    # it for a token bound there: the Default project only under the Default
    # workspace, and no project anywhere else (AssignDefaultScope).
    scopes = %{
      default: [workspace_id: default_ws.id, project_id: default_proj.id],
      a: [workspace_id: ws_a.id],
      b: [workspace_id: ws_b.id]
    }

    for {_k, scope} <- scopes do
      upsert_task_schemas!(scope)
      Barkpark.LabelFixtures.register_tags!(@ledger)
    end

    # An admin of workspace A and of NOTHING else: no Default role, no
    # membership in B. `{LiveAuth, :scoped_admin}` admits it for A's URL.
    user_a = register_user("strip-a-#{System.unique_integer([:positive])}@example.test")
    {:ok, user_a_raw} = Accounts.create_user_session_token(user_a)
    {:ok, _} = TenancyAuth.create_membership(ws_a.id, user_a.id, "admin", "user")

    # The positive-control principal: an admin of Default, on the flat mount.
    user_default =
      register_user("strip-default-#{System.unique_integer([:positive])}@example.test")

    {:ok, user_default_raw} = Accounts.create_user_session_token(user_default)
    {:ok, _} = TenancyAuth.create_membership(default_ws.id, user_default.id, "admin", "user")

    enable_fake_chat()

    %{
      conn: conn,
      default_ws: default_ws,
      ws_a: ws_a,
      ws_b: ws_b,
      scopes: scopes,
      user_a_raw: user_a_raw,
      user_default_raw: user_default_raw
    }
  end

  # ── the resolver ─────────────────────────────────────────────────────────

  describe "TaskLedgerScope.resolve/1" do
    test "names the workspace it is handed, never the Default", ctx do
      assert %{workspace_id: ws_a_id, project_id: nil, dataset: @ledger} =
               TaskLedgerScope.resolve(ctx.ws_a.id)

      assert ws_a_id == ctx.ws_a.id
      refute ws_a_id == ctx.default_ws.id
    end

    test "pairs the Default project only with the Default workspace", ctx do
      assert TaskLedgerScope.resolve(ctx.default_ws.id) == %{
               workspace_id: ctx.default_ws.id,
               project_id: ctx.scopes.default[:project_id],
               dataset: @ledger
             }
    end

    test "a viewer with no workspace resolves to no workspace (fail-closed)" do
      assert TaskLedgerScope.resolve(nil) == %{
               workspace_id: nil,
               project_id: nil,
               dataset: @ledger
             }
    end
  end

  # ── the Doing strip ──────────────────────────────────────────────────────

  describe "scoped /w/:ws/p/:proj/studio/chat — an admin of workspace A ONLY" do
    test "HYDRATE: the Doing strip folds A's claim and not B's or Default's", ctx do
      {sid, worker} = session!(ctx.ws_a)
      held = claim_in_each!(ctx.scopes, worker)

      view = mount!(ctx.conn, ctx.user_a_raw, scoped_path(ctx.ws_a, sid))
      assert_viewer_scope!(view, ctx.ws_a)
      html = render(view)

      assert_strip(html, held)
    end

    test "LIVE: claims taken after mount fold A's and not B's or Default's", ctx do
      {sid, worker} = session!(ctx.ws_a)

      view = mount!(ctx.conn, ctx.user_a_raw, scoped_path(ctx.ws_a, sid))
      assert_viewer_scope!(view, ctx.ws_a)
      assert strip_ids(render(view)) == [], "precondition: the strip starts empty"

      held = claim_in_each!(ctx.scopes, worker)
      html = render(view)

      assert_strip(html, held)
    end

    test "READY PICKER: lists A's ready task and not B's or Default's", ctx do
      {sid, _worker} = session!(ctx.ws_a)

      ready =
        Map.new(ctx.scopes, fn {k, scope} -> {k, task!(scope, "ready #{k}")} end)

      view = mount!(ctx.conn, ctx.user_a_raw, scoped_path(ctx.ws_a, sid))
      assert_viewer_scope!(view, ctx.ws_a)
      html = render_click(view, "toggle-task-picker", %{})

      picker = picker_html(html)

      listed =
        ready
        |> Enum.filter(fn {_k, doc} -> picker =~ ~s(phx-value-id="#{doc.doc_id}") end)
        |> Enum.map(fn {k, _doc} -> k end)
        |> Enum.sort()

      assert listed == [:a],
             "an admin of workspace A ONLY must see exactly its own ready task [:a] in " <>
               "the ready picker; it was shown #{inspect(listed)}"
    end
  end

  describe "POSITIVE CONTROL: flat /studio/chat — an admin of Default" do
    test "the Doing strip still folds the Default claim, hydrate and live", ctx do
      {sid, worker} = session!(ctx.default_ws)
      before = task!(ctx.scopes.default, "default before mount")
      {:ok, _} = Tasks.claim_by_id(before.doc_id, worker, ctx.scopes.default)

      view = mount!(ctx.conn, ctx.user_default_raw, "/studio/chat/#{sid}")
      assert_viewer_scope!(view, ctx.default_ws)
      assert strip_ids(render(view)) == [before.doc_id]

      later = task!(ctx.scopes.default, "default after mount")
      {:ok, _} = Tasks.claim_by_id(later.doc_id, worker, ctx.scopes.default)

      assert Enum.sort(strip_ids(render(view))) == Enum.sort([before.doc_id, later.doc_id])
    end
  end

  # ── assertions ───────────────────────────────────────────────────────────

  # The strip's rows, each labelled with the workspace whose claim it is. ONE
  # assertion over the whole labelled set, so a red names every row the viewer
  # was shown, not just the first missing one.
  defp assert_strip(html, held) do
    shown = label(strip_ids(html), held)

    assert shown == [:a],
           "an admin of workspace A ONLY must see exactly its own claim [:a] in the " <>
             "Doing strip; it was shown #{inspect(shown)}"
  end

  defp label(ids, by_ws) do
    owner = Map.new(by_ws, fn {k, doc} -> {doc.doc_id, k} end)
    ids |> Enum.map(&Map.get(owner, &1, {:unknown, &1})) |> Enum.sort()
  end

  # PRECONDITION: the socket really resolved to the viewer's workspace. A
  # refusal asserted against a socket scoped elsewhere would prove nothing.
  defp assert_viewer_scope!(view, ws) do
    %{socket: %{assigns: assigns}} = :sys.get_state(view.pid)

    assert match?(%{id: _}, assigns[:current_workspace]) and
             assigns.current_workspace.id == ws.id,
           "precondition: the view is not scoped to #{ws.slug} " <>
             "(current_workspace: #{inspect(assigns[:current_workspace])})"
  end

  defp strip_ids(html) do
    ~r/data-role="chat-hand-task"\s+data-task-id="([^"]+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
  end

  defp picker_html(html) do
    case Regex.run(~r/data-role="chat-task-picker".*/s, html) do
      [picker] -> picker
      _ -> flunk("precondition: the ready picker did not open")
    end
  end

  # ── fixtures ─────────────────────────────────────────────────────────────

  defp claim_in_each!(scopes, worker) do
    Map.new(scopes, fn {k, scope} ->
      t = task!(scope, "claim #{k}")
      {:ok, claimed} = Tasks.claim_by_id(t.doc_id, worker, scope)

      assert claimed.content["claim"]["worker"] == worker
      assert claimed.workspace_id == scope[:workspace_id]

      {k, claimed}
    end)
  end

  defp scoped_path(ws, sid), do: "/w/#{ws.slug}/p/default/studio/chat/#{sid}"

  defp session!(ws) do
    {:ok, session} =
      StudioChat.create_session(%{id: Ecto.UUID.generate(), mode: "plan"}, {:workspace, ws.id})

    {session.id, ClaudeChat.worker_id(session.id)}
  end

  defp mount!(conn, user_session_raw, path) do
    result = live(init_test_session(conn, %{"user_session" => user_session_raw}), path)

    assert match?({:ok, _view, _html}, result),
           "precondition: the admin failed to mount #{path} (got #{inspect(result)})"

    {:ok, view, _html} = result
    view
  end

  defp workspace!(prefix) do
    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "#{prefix}-#{System.unique_integer([:positive])}",
        name: String.upcase(prefix)
      })

    {:ok, _proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    ws
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
    doc_id = "stws-#{System.unique_integer([:positive])}"

    content =
      %{
        "kind" => "task",
        "brief" => Barkpark.TaskBriefFixtures.brief(),
        "description" => "strip workspace fixture #{doc_id}",
        "lifecycle_status" => "open",
        "dedup_bypass" => true,
        "acceptance_criteria" => [%{"criterion" => "the strip shows the claim", "met" => false}]
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
