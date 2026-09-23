defmodule BarkparkWeb.StudioOperatorPremiseTriggerTest do
  @moduledoc """
  THE STANDING TRIGGER for the filed-for-the-future row
  `arpss-studio-unscoped-dataset-reads` ("Studio unscoped dataset-string reads
  — re-audit if Studio becomes multi-tenant").

  That row parks TWO reads that carry no workspace predicate:

    * `Barkpark.Tasks.Board.load_task_docs/1` — `where d.type == "task" and
      d.dataset == ^dataset`, no `workspace_id`, feeding `Board.snapshot/1`;
    * `Barkpark.StudioChat`'s one-hop ledger reads behind `epic_goal/2`
      (`held_task_parent_id/1`, `published_task_doc/1`, `epic_slice_counts/1`)
      — `where d.type == "task"` and NOT EVEN a dataset predicate.

  Both are declared safe by their DOOR, never by their query: the only
  principal who can reach them is the instance operator. "Re-audit if Studio
  becomes multi-tenant" is not a predicate anyone can evaluate, so this file
  states the premise mechanically and reds when it stops holding.

  ## THE PREDICATE

  `BarkparkWeb.LiveAuth` has exactly two grades of mount gate, and the
  difference between them IS the row's trigger:

    * INSTANCE-GLOBAL (`:ops`, `:admin`) — `on_mount(:ops, _params, …)`
      discards params and resolves the grant against the instance-global
      `ops`/`admin` token permission or, for a user session, an admin role in
      `Tenancy.get_default_workspace()`. A principal whose only admin grant
      lives in some OTHER workspace never passes.
    * TARGET-WORKSPACE (`:scoped_admin`) — `on_mount(:scoped_admin, params, …)`
      resolves the workspace named in the URL and admits anyone holding an
      admin ROLE there, with no global permission and no Default-workspace
      role at all (`live_auth_target_workspace_test.exs` proves that arm).

  So, stated so a stranger can check it without reading the history:

      STUDIO IS STILL SINGLE-OPERATOR FOR A READER R  ⟺  every route in
      `BarkparkWeb.Router.__routes__/0` that mounts R sits in a live_session
      whose `on_mount` list carries an INSTANCE-GLOBAL `BarkparkWeb.LiveAuth`
      hook and NO TARGET-WORKSPACE one.

  It is a rule over the router, not a list of today's two call sites: a third
  mount added tomorrow is measured by the same sentence.

  ## WHAT THIS FILE FOUND (read before trusting the row's own text)

  The predicate is not hypothetical — one half has ALREADY FLIPPED:

    * `Tasks.Web.BoardLive` still passes. Both of its mounts (flat `/admin`
      and the scoped mirror `/w/:ws/p/:proj/admin`) come from
      `plugin_routes(scope: :ops)` and both carry `{LiveAuth, :ops}`. The
      scoped mount is only a scoped URL over a still-global gate.
    * `BarkparkWeb.Studio.ChatLive` does NOT. It is mounted in
      `live_session :scoped_admin_studio` at `/w/:ws/p/:proj/studio/chat`,
      whose gate is `{LiveAuth, :scoped_admin}` — the target-workspace grade.
      A workspace-B-only admin therefore already reaches a LiveView that calls
      `StudioChat.epic_goal/2`, whose ledger hops read `type:task` globally.

  So the `board.ex` half is a LIVE TRIGGER (test 1, 2, 3) and the
  `studio_chat.ex` half is an ARRIVED one (test 4), recorded here rather than
  left to a human remembering.

  ## MUTATION PROOF

  Swap `{BarkparkWeb.LiveAuth, :ops}` for `{BarkparkWeb.LiveAuth, :scoped_admin}`
  in the `live_session :scoped_plugin_ops` block of `router.ex` — the one-line
  edit that "makes the ops Studio multi-tenant" — and test 1 goes RED naming
  `BoardLive` and the offending path. Restore it and it is GREEN again.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.Board
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  # Params-blind, instance-rooted. `on_mount(:ops, _params, …)` /
  # `on_mount(:admin, _params, …)` — both discard the URL workspace.
  @instance_global_gates [:ops, :admin]

  # Reads the workspace out of the URL and grades a ROLE in it.
  @target_workspace_gates [:scoped_admin]

  # The board reader the row parks. Named as a module, never as a line number:
  # the row's own `board.ex:227` citation had already rotted to an unrelated
  # doc block by the time this file was written.
  @board_reader Barkpark.Plugins.Tasks.Web.BoardLive

  # The studio-chat reader the row parks — it calls `StudioChat.epic_goal/2`.
  @chat_reader BarkparkWeb.Studio.ChatLive

  # ── router census (derived, never hand-listed) ────────────────────────────

  defp mounts_of(module) do
    for route <- BarkparkWeb.Router.__routes__(),
        {mod, _action, _opts, %{name: name, extra: extra}} <-
          [route.metadata[:phoenix_live_view]],
        mod == module do
      %{path: route.path, session: name, on_mount: Map.get(extra, :on_mount, [])}
    end
  end

  # The `BarkparkWeb.LiveAuth` hook names a live_session carries, as atoms.
  # `on_mount` entries are `%Phoenix.LiveView.Lifecycle.Hook{}` structs whose
  # `:id` is the `{module, arg}` pair the router wrote.
  defp live_auth_gates(on_mount) do
    for hook <- on_mount,
        {BarkparkWeb.LiveAuth, gate} <- [hook_id(hook)],
        do: gate
  end

  defp hook_id(%{id: id}), do: id
  defp hook_id({_mod, _arg} = id), do: id
  defp hook_id(_), do: nil

  # ── 1. THE LIVE TRIGGER — the board door is still instance-global ─────────

  describe "board.ex — `Board.load_task_docs/1` is reachable only behind an instance-global gate" do
    test "every router mount of BoardLive carries an instance-global LiveAuth hook and no target-workspace one" do
      mounts = mounts_of(@board_reader)

      # Non-vacuity. A rename or a kill-switched plugin would otherwise make
      # this test pass by measuring an empty list.
      refute mounts == [],
             """
             No route in BarkparkWeb.Router mounts #{inspect(@board_reader)}.
             This guard would then be vacuous. If the board moved, point
             @board_reader at its new module; if it was deleted, so was the
             finding — delete this file and close the row.
             """

      offenders =
        for m <- mounts,
            gates = live_auth_gates(m.on_mount),
            bad = Enum.filter(gates, &(&1 in @target_workspace_gates)),
            global = Enum.filter(gates, &(&1 in @instance_global_gates)),
            bad != [] or global == [] do
          "  #{m.path} (live_session #{inspect(m.session)}) — LiveAuth gates: #{inspect(gates)}"
        end

      assert offenders == [],
             """
             STUDIO HAS BECOME MULTI-TENANT AT THE BOARD DOOR.

             #{inspect(@board_reader)} is now mounted behind a TARGET-WORKSPACE
             gate #{inspect(@target_workspace_gates)} (or behind no instance-global
             gate at all). It renders `Barkpark.Tasks.Board.snapshot/1`, whose
             `load_task_docs/1` reads `type:task` for a raw dataset STRING with
             NO `workspace_id` predicate — see the ruling comment above that
             function, which rests entirely on this door being operator-only.

             That read is now a cross-tenant leak of the same class as
             `Barkpark.Content.DedupWall` (row arpss-dedup-wall-cross-tenant-scope).
             Scope the query to the viewer's workspace, or give the multi-tenant
             surface its own workspace-scoped board.

             Offending mounts:
             #{Enum.join(offenders, "\n")}
             """
    end
  end

  # ── 2. THE GATE SEMANTICS — behavioural, both directions ──────────────────

  describe ":ops is an instance-global gate (the premise test 1 rests on)" do
    setup %{conn: conn} do
      {default_ws, _proj} = ensure_default_scope!()

      suffix = System.unique_integer([:positive])
      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "prem-b-#{suffix}", name: "Premise B"})
      {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

      {:ok, conn: conn, default_ws: default_ws, ws_b: ws_b}
    end

    test "a user who is admin of a NON-default workspace only is REFUSED the board",
         %{conn: conn, default_ws: default_ws, ws_b: ws_b} do
      {user, conn} = user_session!(conn, [{ws_b, "admin"}])

      # The principal really is the multi-tenant shape: admin THERE, nothing here.
      assert TenancyAuth.workspace_admin?(user, ws_b.id)
      refute TenancyAuth.workspace_admin?(user, default_ws.id)

      # Both spellings of the board route — the flat one and the scoped mirror.
      assert {:error, {:redirect, %{to: redirect}}} = live(conn, "/admin/projects")
      assert redirect in ["/studio", "/login"]

      assert {:error, {:redirect, %{to: _}}} =
               live(conn, "/w/#{ws_b.slug}/p/default/admin/projects")
    end

    test "the CONTROL: the same gate ADMITS an admin of the default workspace",
         %{conn: conn, default_ws: default_ws} do
      {user, conn} = user_session!(conn, [{default_ws, "admin"}])
      assert TenancyAuth.workspace_admin?(user, default_ws.id)

      # A mount, not a redirect. Without this arm the refusal above could be a
      # broken route rather than a working gate.
      assert {:ok, _view, _html} = live(conn, "/admin/projects")
    end
  end

  # ── 3. WHY THE DOOR IS THE ONLY THING HOLDING ─────────────────────────────

  describe "Board.snapshot/1 is workspace-blind (the read itself has no tenant predicate)" do
    test "a task owned by a NON-default workspace appears on the board with nothing about that workspace supplied" do
      {_default_ws, _proj} = ensure_default_scope!()

      suffix = System.unique_integer([:positive])
      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "blind-b-#{suffix}", name: "Blind B"})

      # A dataset label nobody else in this shared test database uses, so the
      # assertion never meets another partition's rows.
      dataset = "premise-trigger-#{suffix}"
      doc_id = "premise-foreign-#{suffix}"

      Repo.insert!(%Document{
        doc_id: doc_id,
        type: "task",
        dataset: dataset,
        status: "published",
        title: "Workspace B's private card title",
        rev: "rev-#{doc_id}",
        workspace_id: ws_b.id,
        content: %{"lifecycle_status" => "in_progress"}
      })

      board = Board.snapshot(dataset: dataset)
      card = board.cards_by_id[doc_id]

      assert card,
             """
             `Board.snapshot/1` no longer returns a task doc owned by a
             non-default workspace. If `load_task_docs/1` grew a tenant
             predicate, the premise of arpss-studio-unscoped-dataset-reads
             changed for the better — re-read the row and close it rather than
             deleting this assertion.
             """

      assert card.title == "Workspace B's private card title"
    end
  end

  # ── 4. THE ARRIVED HALF — studio_chat is already behind a per-workspace gate ──

  describe "studio_chat.ex — the epic-goal ledger reads are ALREADY reachable per-workspace" do
    test "ChatLive is mounted behind a target-workspace gate, and that gate admits a workspace-B-only admin" do
      mounts = mounts_of(@chat_reader)

      refute mounts == [],
             "No route mounts #{inspect(@chat_reader)} — repoint @chat_reader or delete this arm."

      scoped =
        for m <- mounts,
            gates = live_auth_gates(m.on_mount),
            Enum.any?(gates, &(&1 in @target_workspace_gates)),
            do: m

      # RECORDED STATE, not an aspiration: if this list ever empties, someone
      # moved ChatLive back behind an instance-global gate and the studio_chat
      # half of the row became safe again. Re-read the row; do not just delete.
      refute scoped == [],
             """
             #{inspect(@chat_reader)} is no longer mounted behind any of
             #{inspect(@target_workspace_gates)}. The studio_chat half of
             arpss-studio-unscoped-dataset-reads may now be safe — re-read the
             row and record the change instead of dropping this arm.

             Mounts seen: #{inspect(Enum.map(mounts, & &1.path))}
             """

      # And the gate class really does admit the multi-tenant principal. Proven
      # on SettingsLive, which shares `live_session :scoped_admin_studio` with
      # ChatLive: ChatLive.mount carries an extra runtime-availability refusal
      # that would confound an auth verdict, SettingsLive does not — so this
      # measures the GATE, not the LiveView.
      {default_ws, _proj} = ensure_default_scope!()
      suffix = System.unique_integer([:positive])
      {:ok, ws_b} = Tenancy.create_workspace(%{slug: "arrived-b-#{suffix}", name: "Arrived B"})
      {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

      assert Enum.any?(scoped, fn m -> m.session == :scoped_admin_studio end),
             "ChatLive left :scoped_admin_studio — repoint the sibling surface below."

      {user, conn} = user_session!(scoped_conn(), [{ws_b, "admin"}])
      refute TenancyAuth.workspace_admin?(user, default_ws.id)

      mounted? =
        match?({:ok, _view, _html}, live(conn, "/w/#{ws_b.slug}/p/default/studio/settings"))

      assert mounted?,
             """
             The :scoped_admin gate refused a workspace-B-only admin. If the
             gate grade changed, the studio_chat half of the row changed with
             it — re-read the row.
             """
    end
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp user_session!(conn, memberships) do
    email = "premise-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    Enum.each(memberships, fn {ws, role} ->
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, role, "user")
    end)

    {:ok, raw} = Accounts.create_user_session_token(user)
    {user, Plug.Test.init_test_session(conn, %{"user_session" => raw})}
  end
end
