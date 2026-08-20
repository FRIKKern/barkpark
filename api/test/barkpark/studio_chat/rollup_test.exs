defmodule Barkpark.StudioChat.RollupTest do
  @moduledoc """
  The workspace fleet rollup (herd layer, charter D64h): `StudioChat.rollup/1`
  counts sessions per `agent_state` and picks ONE precedence state in the order
  `blocked > working > idle > unknown` — unknown LAST, matching the shipped Go
  `herdRank` (`TestHerdAttentionSort`). Scope rides the SAME fail-closed
  `scope_sessions/2` gate as every other read funnel: `:global` sees all,
  `{:workspace, ws}` only its own `owner_workspace_id` rows (NULL-owner rows
  invisible), junk scopes zero rows.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Session

  @zero %{working: 0, blocked: 0, idle: 0, unknown: 0}

  # Insert through the real create funnel (defaults agent_state to "idle"), then
  # flip through the real write funnel `set_agent_state/4` — never a raw UPDATE.
  # A blocked flip carries the D80h corroboration honestly: a real pending ask
  # row first (the same store truth the `:ask` in-WHERE guard reads).
  defp session!(owner_workspace_id, agent_state) do
    id = Ecto.UUID.generate()

    {:ok, s} =
      %Session{}
      |> Session.create_changeset(%{id: id, owner_workspace_id: owner_workspace_id})
      |> Repo.insert()

    case agent_state do
      "idle" ->
        :ok

      "blocked" ->
        {:ok, _} =
          StudioChat.append_message(id, %{
            role: "approval",
            metadata: %{
              "request_id" => "ru-#{System.unique_integer([:positive])}",
              "approval_status" => "pending"
            }
          })

        {1, nil} = StudioChat.set_agent_state(id, "blocked", :ask)

      other ->
        {1, nil} = StudioChat.set_agent_state(id, other, :derived)
    end

    s
  end

  describe "counts per agent_state" do
    test "each of the four states is counted; absent states zero-fill" do
      ws = create_workspace!()

      session!(ws.id, "working")
      session!(ws.id, "working")
      session!(ws.id, "blocked")
      session!(ws.id, "idle")
      session!(ws.id, "unknown")

      assert %{counts: %{working: 2, blocked: 1, idle: 1, unknown: 1}} =
               StudioChat.rollup({:workspace, ws.id})

      # Absent states are present as 0, never missing keys.
      ws2 = create_workspace!()
      session!(ws2.id, "working")

      assert StudioChat.rollup({:workspace, ws2.id}) == %{
               counts: %{working: 1, blocked: 0, idle: 0, unknown: 0},
               precedence: :working
             }
    end

    test "an empty in-scope fleet rolls up to :unknown with all-zero counts" do
      ws = create_workspace!()

      assert StudioChat.rollup({:workspace, ws.id}) == %{counts: @zero, precedence: :unknown}
    end
  end

  describe "precedence = blocked > working > idle > unknown (D64h, unknown LAST)" do
    test "one blocked session outranks everything" do
      ws = create_workspace!()
      session!(ws.id, "working")
      session!(ws.id, "idle")
      session!(ws.id, "unknown")
      session!(ws.id, "blocked")

      assert %{precedence: :blocked} = StudioChat.rollup({:workspace, ws.id})
    end

    test "working outranks idle and unknown when nothing is blocked" do
      ws = create_workspace!()
      session!(ws.id, "idle")
      session!(ws.id, "unknown")
      session!(ws.id, "working")

      assert %{precedence: :working} = StudioChat.rollup({:workspace, ws.id})
    end

    test "idle outranks unknown — the D64h pin against the older inverted order" do
      # The retired task-text order (blocked>working>unknown>idle) would pick
      # :unknown here and visibly disagree with the Go herdRank. Idle must win.
      ws = create_workspace!()
      session!(ws.id, "unknown")
      session!(ws.id, "idle")

      assert %{precedence: :idle} = StudioChat.rollup({:workspace, ws.id})
    end

    test "unknown is picked only when it is the only populated state" do
      ws = create_workspace!()
      session!(ws.id, "unknown")

      assert %{precedence: :unknown, counts: %{unknown: 1}} =
               StudioChat.rollup({:workspace, ws.id})
    end
  end

  describe "scope fail-closed (reuses scope_sessions/2 semantics)" do
    test "MUTATION: another workspace's session never appears in this workspace's rollup" do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      session!(ws_a.id, "working")
      # The foreign row is BLOCKED — if the scope filter leaked, it would not
      # only inflate counts but flip precedence to :blocked. Both must hold.
      session!(ws_b.id, "blocked")

      assert StudioChat.rollup({:workspace, ws_a.id}) == %{
               counts: %{working: 1, blocked: 0, idle: 0, unknown: 0},
               precedence: :working
             }

      assert StudioChat.rollup({:workspace, ws_b.id}) == %{
               counts: %{working: 0, blocked: 1, idle: 0, unknown: 0},
               precedence: :blocked
             }
    end

    test "NULL-owner sessions count only for :global, never for a workspace scope" do
      ws = create_workspace!()
      session!(nil, "blocked")
      session!(ws.id, "working")

      # The workspace scope must NOT see the NULL-owner (admin/global) session.
      assert StudioChat.rollup({:workspace, ws.id}) == %{
               counts: %{working: 1, blocked: 0, idle: 0, unknown: 0},
               precedence: :working
             }

      # :global sees BOTH — the NULL-owner blocked row is in and wins precedence.
      # (Other tests in this DB-sandboxed case are invisible; async-safe.)
      assert %{counts: %{blocked: blocked, working: working}, precedence: :blocked} =
               StudioChat.rollup(:global)

      assert blocked >= 1
      assert working >= 1
    end

    test "a junk scope fails closed to zero rows, and bare-binary scope equals the tuple form" do
      ws = create_workspace!()
      session!(ws.id, "working")

      # Anything that is neither :global nor a workspace binary → where(false).
      assert StudioChat.rollup(nil) == %{counts: @zero, precedence: :unknown}
      assert StudioChat.rollup({:workspace, nil}) == %{counts: @zero, precedence: :unknown}

      # The store-funnel bare form and the controller chat_scope tuple agree.
      assert StudioChat.rollup(ws.id) == StudioChat.rollup({:workspace, ws.id})
    end
  end

  describe "archived sessions leave the rollup (charter D28 — the swipe-to-archive aftermath)" do
    test "an archived blocked session stops counting and stops lighting precedence" do
      # The exact mobile gesture's aftermath: a session goes blocked (real
      # pending ask + set_agent_state, the same funnel the sweeper corroborates),
      # then the operator archives it. rollup/1 is a read funnel like
      # list_sessions/fleet_snapshot — an archived row must NOT keep the
      # needs-you badge lit forever (TabBar reads counts.blocked).
      ws = create_workspace!()
      blocked = session!(ws.id, "blocked")

      assert %{counts: %{blocked: 1}, precedence: :blocked} =
               StudioChat.rollup({:workspace, ws.id})

      {:ok, _} = StudioChat.archive_session(blocked.id, ws.id)

      assert StudioChat.rollup({:workspace, ws.id}) == %{counts: @zero, precedence: :unknown}

      # Unarchive restores it — the shelf flip is symmetric, not a delete.
      {:ok, _} = StudioChat.unarchive_session(blocked.id, ws.id)

      assert %{counts: %{blocked: 1}, precedence: :blocked} =
               StudioChat.rollup({:workspace, ws.id})
    end
  end
end
