defmodule BarkparkWeb.Studio.PresenceProjectScopeTest do
  @moduledoc """
  Owner ruling #30 Q7 (2026-10-03, task-1631e0fa917452d9; also RQ11 on
  task-6132833921b7dc36): Studio presence is keyed by workspace + project +
  dataset, and paper presence by workspace + project + dataset + slug.

  Before, Studio presence rode one topic per WORKSPACE, so a share or grant
  viewer of one project received the doc ids, types and display names being
  edited in every other project of that workspace — projects it cannot read.
  Paper presence was keyed workspace + dataset + slug, so two projects'
  same-slug papers shared one room.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.{PaperPresence, Presence}
  alias BarkparkWeb.Studio.PresenceState

  @dataset "production"

  describe "PresenceState.topic/3" do
    test "two projects of one workspace never share a room" do
      refute PresenceState.topic("ws", "p1", @dataset) ==
               PresenceState.topic("ws", "p2", @dataset)
    end

    test "two datasets of one project never share a room" do
      refute PresenceState.topic("ws", "p1", "production") ==
               PresenceState.topic("ws", "p1", "staging")
    end

    test "a socket with no project gets its own room, never the workspace-wide one" do
      refute PresenceState.topic("ws", nil, @dataset) == PresenceState.topic("ws")
      refute PresenceState.topic("ws", nil, @dataset) == PresenceState.topic("ws", "p1", @dataset)
    end
  end

  describe "PaperPresence.topic/4" do
    test "two projects' same-slug papers never share a room" do
      refute PaperPresence.topic("ws", "p1", @dataset, "a") ==
               PaperPresence.topic("ws", "p2", @dataset, "a")
    end
  end

  test "a Studio socket is tracked on its project's room, not the workspace room", %{conn: conn} do
    ws = create_workspace!("presence-ws-#{System.unique_integer([:positive])}")
    p1 = create_project!(ws, "alpha")
    p2 = create_project!(ws, "beta")

    email = "presence-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    {:ok, raw} = Accounts.create_user_session_token(user)
    member_conn = Plug.Test.init_test_session(conn, %{"user_session" => raw})

    {:ok, view, _} = live(member_conn, "/w/#{ws.slug}/p/#{p1.slug}/d/#{@dataset}/studio")
    _ = render(view)

    own_room = PresenceState.topic(ws.id, p1.id, @dataset)
    assert Presence.list(own_room) != %{}, "the member should be tracked on #{own_room}"

    # Nobody in project beta, and nobody on the old workspace-wide topic,
    # learns that this member is in project alpha.
    assert Presence.list(PresenceState.topic(ws.id, p2.id, @dataset)) == %{}
    assert Presence.list(PresenceState.topic(ws.id)) == %{}
  end
end
