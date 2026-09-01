defmodule BarkparkWeb.Studio.PdsW42ChatLiveFlatLifecycleGlobalTest do
  @moduledoc """
  pds-w42-bl-chatlive-routed-clauses-ungated — the flat `/studio/chat` lifecycle
  clauses must act inside the acting principal's own tenancy.

  ## What the row claimed, and what the source actually said

  The row claimed ChatLive's 39 routed `handle_event` clauses sit behind "no
  deny-gate whatsoever" on the flat route. That is NOT what the router says:
  `:admin_studio` carries `{BarkparkWeb.LiveAuth, :admin}`, which HALTS a
  principal holding no `admin` grant. A socket that never mounts never reaches
  a `handle_event` clause, so "ungated" was too strong.

  The real defect — proven by run before it was fixed, and guarded here — was a
  TENANCY one, and it was on the CLAUSES, not the mount:

    * `LiveAuth.on_mount(:admin)` is a FLAT, GLOBAL-permission gate. It asks
      `Auth.has_permission?(token, "admin")` and never looks at the token's
      `workspace_id`. A token BOUND to workspace B therefore mounts
      `/studio/chat`.
    * Four routed clauses then took a CLIENT-SUPPLIED session id and drove it
      at hard-coded `:global` scope — `session-archive`, `session-unarchive`,
      `session-delete`, and `session-rename` (whose store call, `rename/2`,
      takes no scope argument at all and reads `:global` by default).

  A workspace-B-bound admin token could therefore rename, archive and DELETE a
  chat session owned by workspace A. `ChatLive.principal_chat_scope/1` closes
  it: a workspace-BOUND token acts only inside its own workspace, while an
  unbound token and a user-session admin keep the `:global` superuser path
  (charter D17/D18), so the admin sidebar is unchanged for them.

  ## Why every clause is tested TWICE

  Each of the four clauses gets a REFUSED arm and a LANDS arm:

    * REFUSED — the ws-B principal drives the clause against a workspace-A row
      and the row's prior state is intact afterwards.
    * LANDS — the SAME principal drives the SAME clause against its OWN ws-B
      row and the mutation goes through.

  The second arm is what makes the first one mean something. A guard that
  simply broke rename/archive/unarchive/delete outright would satisfy every
  refusal assertion in this file; only the LANDS arm can tell a scope check
  apart from a dead feature. Conversely the refusal arms are stated against a
  value that was READ BACK and asserted present moments earlier in the same
  test, on the same connection — never a bare "nothing happened", which under
  async logging would prove nothing.

  `test/5` is the principal-class proof the row asked for: the SAME token is
  REFUSED at mount of the workspace-scoped route for workspace A while the flat
  route admits it. That asymmetry is why this principal is not simply a
  legitimate instance-wide superuser.

  The fake runtime is enabled in EVERY test: `ChatLive.mount/3` refuses when no
  provider is enabled, and a mount refused for a MISSING RUNTIME would make
  every refusal assertion below vacuously green for the wrong reason.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session, as: StudioChatSession
  alias Barkpark.Tenancy

  @flat_path "/studio/chat"

  setup %{conn: conn} do
    {ws_a, proj_a} = ensure_default!()

    {:ok, ws_b} =
      Tenancy.create_workspace(%{
        slug: "pdsw42-b-#{System.unique_integer([:positive])}",
        name: "PDS W42 B"
      })

    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    enable_fake_chat()

    # The PRINCIPAL: an admin token BOUND to workspace B. `on_mount(:admin)`
    # reads only `permissions`, so the binding is invisible to the flat gate and
    # this token still mounts /studio/chat.
    raw = "pdsw42-bound-b-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        raw,
        "pds w42 ws-b admin",
        "production",
        ["read", "write", "admin"],
        ws_b.id
      )

    # The FOREIGN target: a chat session owned by workspace A.
    foreign = session_owned_by!(ws_a, "ws-A private chat")

    # The OWN target: a chat session owned by workspace B, the principal's own
    # tenancy. Drives the LANDS arm of every clause.
    own = session_owned_by!(ws_b, "ws-B own chat")

    # Fixture guards. Without these, a refusal assertion could pass against a
    # row that was never A's, and a LANDS assertion against a row that was never
    # B's — both vacuous.
    assert Repo.get(StudioChatSession, foreign.id).owner_workspace_id == ws_a.id,
           "fixture did not produce a workspace-A-owned session — refusal arms would be vacuous"

    assert Repo.get(StudioChatSession, own.id).owner_workspace_id == ws_b.id,
           "fixture did not produce a workspace-B-owned session — LANDS arms would be vacuous"

    refute foreign.id == own.id

    %{
      conn: init_test_session(conn, %{"api_token" => raw}),
      ws_a: ws_a,
      proj_a: proj_a,
      ws_b: ws_b,
      foreign: foreign,
      own: own
    }
  end

  describe "flat :admin_studio — a ws-B-bound admin token is confined to workspace B" do
    test "session-rename is REFUSED on ws-A's row and LANDS on its own", %{
      conn: conn,
      foreign: foreign,
      own: own
    } do
      view = mount_flat!(conn)

      before_title = Repo.get(StudioChatSession, foreign.id).title

      assert before_title == "ws-A private chat",
             "the foreign row does not carry its seeded title — the refusal read-back is unsound"

      marker = "OWNED-BY-WS-B-#{System.unique_integer([:positive])}"

      render_click(view, "session-rename", %{"id" => foreign.id, "value" => marker})

      # REFUSED — the title is still the value asserted present two statements
      # ago, not a bare absence of change.
      assert Repo.get(StudioChatSession, foreign.id).title == before_title,
             "a ws-B-bound admin token renamed a workspace-A chat session across the tenancy line"

      # LANDS — the same clause, same socket, its OWN row. Proves the guard is a
      # scope check and not a broken rename.
      render_click(view, "session-rename", %{"id" => own.id, "value" => marker})

      own_after = Repo.get(StudioChatSession, own.id)

      assert own_after.title == marker,
             "the ws-B admin could not rename its OWN session — the scope guard is over-tight"

      assert own_after.title_source == "human",
             "rename/2 pins title_source — an unchanged source would mean something else wrote it"
    end

    test "session-archive is REFUSED on ws-A's row and LANDS on its own", %{
      conn: conn,
      foreign: foreign,
      own: own
    } do
      view = mount_flat!(conn)

      refute Repo.get(StudioChatSession, foreign.id).archived_at,
             "the foreign row is already archived — the refusal cannot be observed"

      render_click(view, "session-archive", %{"id" => foreign.id})

      # REFUSED — still no stamp on a row proven unstamped a statement ago.
      refute Repo.get(StudioChatSession, foreign.id).archived_at,
             "a ws-B-bound admin token archived a workspace-A chat session across the tenancy line"

      # LANDS — PRESENCE of a timestamp where there was none.
      render_click(view, "session-archive", %{"id" => own.id})

      assert Repo.get(StudioChatSession, own.id).archived_at,
             "the ws-B admin could not archive its OWN session — the scope guard is over-tight"
    end

    test "session-unarchive is REFUSED on ws-A's row and LANDS on its own", %{
      conn: conn,
      foreign: foreign,
      own: own
    } do
      # Put BOTH rows on the archived shelf out of band, so each clause has
      # something to clear.
      assert {:ok, _} = StudioChat.archive_session(foreign.id, :global)
      assert {:ok, _} = StudioChat.archive_session(own.id, :global)

      foreign_stamp = Repo.get(StudioChatSession, foreign.id).archived_at

      assert foreign_stamp,
             "the foreign row is not archived — `unarchive` would have nothing to clear"

      view = mount_flat!(conn)
      render_click(view, "session-unarchive", %{"id" => foreign.id})

      # REFUSED — the exact stamp read a moment ago is still there.
      assert Repo.get(StudioChatSession, foreign.id).archived_at == foreign_stamp,
             "a ws-B-bound admin token unarchived a workspace-A chat session across the tenancy line"

      # LANDS — a witnessed transition on its own row.
      render_click(view, "session-unarchive", %{"id" => own.id})

      refute Repo.get(StudioChatSession, own.id).archived_at,
             "the ws-B admin could not unarchive its OWN session — the scope guard is over-tight"
    end

    test "session-delete is REFUSED on ws-A's row and LANDS on its own", %{
      conn: conn,
      foreign: foreign,
      own: own
    } do
      view = mount_flat!(conn)

      assert %StudioChatSession{} = Repo.get(StudioChatSession, foreign.id),
             "the foreign row vanished before the event — the refusal read-back is unsound"

      render_click(view, "session-delete", %{"id" => foreign.id})

      # REFUSED — PRESENCE: the row is still there, and still A's.
      surviving = Repo.get(StudioChatSession, foreign.id)

      assert %StudioChatSession{} = surviving,
             "a ws-B-bound admin token DELETED a workspace-A chat session across the tenancy line"

      assert surviving.owner_workspace_id == foreign.owner_workspace_id,
             "the surviving row changed owner — that is not the row the probe protected"

      # LANDS — the same clause reaches its own row. This is the one absence in
      # the module, admissible only because the delete above proved the same
      # query returns a row on this connection.
      assert %StudioChatSession{} = Repo.get(StudioChatSession, own.id)

      render_click(view, "session-delete", %{"id" => own.id})

      refute Repo.get(StudioChatSession, own.id),
             "the ws-B admin could not delete its OWN session — the scope guard is over-tight"
    end

    test "the same principal is REFUSED at the scoped route for that very workspace", %{
      conn: conn,
      ws_a: ws_a,
      proj_a: proj_a
    } do
      scoped = "/w/#{ws_a.slug}/p/#{proj_a.slug}/studio/chat"

      # `:scoped_admin` resolves workspace A from the URL and demands a grant
      # THERE. A ws-B-bound token has none, so the mount halts.
      assert {:error, {kind, _}} = live(conn, scoped),
             "the ws-B principal MOUNTED #{scoped} — if the scoped gate also lets it " <>
               "through, this token is effectively global and the finding needs re-framing"

      assert kind in [:redirect, :live_redirect],
             "expected a redirect halt from the scoped mount gate, got #{inspect(kind)}"

      # The opposing direction, same conn, same test: the flat route still
      # ADMITS it. One principal, two doors, two answers — that asymmetry is why
      # the clause-level scope check above is load-bearing.
      assert {:ok, _view, _html} = live(conn, @flat_path),
             "the flat route refused the principal too — then there is no asymmetry to guard"
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp session_owned_by!(ws, title) do
    {:ok, session} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), title: title, title_source: "human"},
        {:workspace, ws.id}
      )

    session
  end

  # Mount the flat route and PROVE it mounted. A bounced mount (auth halt, or
  # the missing-runtime refusal in `ChatLive.mount/3`) must never be mistaken
  # for a quiet success — every refusal assertion would then pass for free.
  defp mount_flat!(conn) do
    assert {:ok, view, _html} = live(conn, @flat_path),
           "the ws-B-bound admin token failed to mount the flat #{@flat_path} — " <>
             "every clause assertion in this test would be vacuous"

    view
  end

  defp ensure_default! do
    ws =
      case Tenancy.get_default_workspace() do
        nil ->
          {:ok, ws} = Tenancy.create_workspace(%{slug: "default", name: "Default"})
          ws

        ws ->
          ws
      end

    proj =
      case Tenancy.get_default_project() do
        nil ->
          {:ok, p} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
          p

        p ->
          p
      end

    {ws, proj}
  end

  # ChatLive.mount refuses when no provider is enabled. Without this every mount
  # assertion above would fail for a reason that has nothing to do with authz.
  defp enable_fake_chat do
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

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
    end)
  end
end
