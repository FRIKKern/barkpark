defmodule BarkparkWeb.ChatRegisteredHostReadsTest do
  @moduledoc """
  task-f44bbb6363d28e37: a chat on a registered host can carry file contents
  and command output from that computer. #28693 stopped a member from creating
  or driving one; this file pins that a member cannot SEE one either. Every
  door that takes a session id (read, its messages, the event stream,
  interrupt, steer, send, approve, answer, archive, attachments) answers the
  not-found oracle: the same 404 as a missing id, so the session's existence
  does not leak. The list leaves the session out.

  The seat that may see it is the seat that may drive it
  (`HostExecutionGate.may_see_session?/2`): an owner or admin seat in the
  session's workspace, or a token whose `owner_user_id` is an owner there.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest
  import Barkpark.AccountsFixtures, only: [register_user: 1]
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"
  @env_keys [:claude_chat, :public_demo_studio, :operator_emails, :operator_token_ids]

  setup do
    ensure_default_scope!()
    prev = Map.new(@env_keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])

    on_exit(fn ->
      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end
    end)

    ws = create_workspace!()
    {:ok, issued} = ChatHosts.issue_enrollment(ws.id, %{name: "reads-host"})

    {member_raw, _} = mint!(["read", "chat"], ws.id)
    {admin_raw, _} = mint!(["read", "write", "admin"], ws.id)

    host_sid = host_session!(ws, issued.host.id, "HOST-CHAT-TITLE")
    managed_sid = managed_session!(ws, "MEMBER-MANAGED-TITLE")

    %{
      ws: ws,
      member_raw: member_raw,
      admin_raw: admin_raw,
      host_sid: host_sid,
      managed_sid: managed_sid
    }
  end

  # ── fixtures ───────────────────────────────────────────────────────────────

  defp mint!(perms, ws_id, opts \\ []) do
    raw = "host-reads-" <> Ecto.UUID.generate()
    {:ok, token} = Auth.create_token(raw, "host reads", @dataset, perms, ws_id, opts)
    {raw, token}
  end

  # A host session with a transcript and a pending approval, written to the
  # store directly: what an owner's chat leaves behind.
  defp host_session!(ws, host_id, title) do
    sid = Ecto.UUID.generate()

    {:ok, _} =
      StudioChat.create_session(
        %{
          id: sid,
          title: title,
          title_source: "human",
          provider: "claude",
          execution_target: "registered_host",
          execution_host_id: host_id,
          mode: "plan"
        },
        {:workspace, ws.id}
      )

    {:ok, _} =
      StudioChat.append_message(sid, %{role: "assistant", source_markdown: "HOST-SECRET-OUTPUT"})

    {:ok, _} =
      StudioChat.append_message(StudioChat.get_session(sid), %{
        role: "approval",
        source_markdown: "Bash",
        metadata: %{"request_id" => "r-1", "tool_name" => "Bash", "approval_status" => "pending"}
      })

    sid
  end

  defp managed_session!(ws, title) do
    {:ok, s} =
      StudioChat.create_session(
        %{id: Ecto.UUID.generate(), title: title, title_source: "human", mode: "plan"},
        {:workspace, ws.id}
      )

    s.id
  end

  defp json_conn(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  # Every id door, as `{label, fun(conn, sid) -> conn}`.
  defp doors do
    [
      {"GET show", &get(&1, "/v1/chat/sessions/#{&2}")},
      {"GET show ?since", &get(&1, "/v1/chat/sessions/#{&2}?since=0")},
      {"GET events", &bounded(fn -> get(&1, "/v1/chat/sessions/#{&2}/events") end)},
      {"POST interrupt", &post(&1, "/v1/chat/sessions/#{&2}/interrupt", "{}")},
      {"PATCH steer", &patch(&1, "/v1/chat/sessions/#{&2}", ~s({"mode":"acceptEdits"}))},
      {"PATCH title", &patch(&1, "/v1/chat/sessions/#{&2}", ~s({"title":"renamed"}))},
      {"PATCH model", &patch(&1, "/v1/chat/sessions/#{&2}", ~s({"model_choice":"opus"}))},
      {"PATCH effort", &patch(&1, "/v1/chat/sessions/#{&2}", ~s({"effort_choice":"high"}))},
      {"POST messages", &post(&1, "/v1/chat/sessions/#{&2}/messages", ~s({"content":"hi"}))},
      {"POST approval",
       &post(&1, "/v1/chat/sessions/#{&2}/approval", ~s({"request_id":"r-1","decision":"allow"}))},
      {"POST approval deny",
       &post(&1, "/v1/chat/sessions/#{&2}/approval", ~s({"request_id":"r-1","decision":"deny"}))},
      {"POST answer",
       &post(&1, "/v1/chat/sessions/#{&2}/answer", ~s({"request_id":"r-1","answers":{"q":"a"}}))},
      {"POST archive", &post(&1, "/v1/chat/sessions/#{&2}/archive", "{}")},
      {"POST unarchive", &post(&1, "/v1/chat/sessions/#{&2}/unarchive", "{}")},
      {"GET attachment", &get(&1, "/v1/chat/sessions/#{&2}/attachments/#{Ecto.UUID.generate()}")}
    ]
  end

  # The event stream never returns once it opens: a door that opens it for a
  # member is a leak, reported as a 200 instead of hanging the test.
  defp bounded(fun) do
    task = Task.async(fun)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, conn} -> conn
      _ -> %Plug.Conn{status: 200, resp_body: ~s({"error":"stream opened"})}
    end
  end

  defp strip_request_id(conn) do
    conn.resp_body |> Jason.decode!() |> update_in(["error"], &Map.delete(&1, "request_id"))
  end

  defp listed_titles(raw, archived \\ false) do
    json_conn(raw)
    |> get("/v1/chat/sessions?archived=#{archived}")
    |> json_response(200)
    |> Map.fetch!("sessions")
    |> Enum.map(& &1["title"])
  end

  # ── a member sees nothing of the host session ──────────────────────────────

  test "a member token's read of the host session is the missing-id 404",
       %{member_raw: member_raw, host_sid: host_sid} do
    conn = json_conn(member_raw) |> get("/v1/chat/sessions/#{host_sid}")
    missing = json_conn(member_raw) |> get("/v1/chat/sessions/#{Ecto.UUID.generate()}")

    assert conn.status == 404
    assert strip_request_id(conn) == strip_request_id(missing)
    refute conn.resp_body =~ "HOST-SECRET-OUTPUT"
  end

  test "every id door answers a member token the same 404 as a missing id, and writes nothing",
       %{member_raw: member_raw, host_sid: host_sid} do
    before = StudioChat.get_session(host_sid, :global)

    leaks =
      for {label, door} <- doors(),
          conn = door.(json_conn(member_raw), host_sid),
          missing = door.(json_conn(member_raw), Ecto.UUID.generate()),
          missing.status != 404 or conn.status != 404 or
            strip_request_id(conn) != strip_request_id(missing),
          do: "#{label}: #{conn.status} (missing id: #{missing.status})"

    assert leaks == [],
           "doors that tell a member the host session exists:\n" <> Enum.join(leaks, "\n")

    after_row = StudioChat.get_session(host_sid, :global)

    assert Map.take(after_row, [:title, :mode, :model_choice, :effort_choice, :archived_at]) ==
             Map.take(before, [:title, :mode, :model_choice, :effort_choice, :archived_at])

    messages = StudioChat.list_messages(host_sid, :global)
    assert length(messages) == 2

    assert [%{metadata: %{"approval_status" => "pending"}}] =
             Enum.filter(messages, &(&1.role == "approval"))
  end

  test "the list leaves the host session out for a member token, and keeps its managed one",
       %{member_raw: member_raw} do
    titles = listed_titles(member_raw)

    refute "HOST-CHAT-TITLE" in titles
    assert "MEMBER-MANAGED-TITLE" in titles
  end

  test "a member-seat token held for a member user is refused the same way",
       %{ws: ws, host_sid: host_sid} do
    user = register_user("host-reads-#{System.unique_integer([:positive])}@example.test")
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    {raw, _} = mint!(["read", "chat"], ws.id, owner_user_id: user.id)

    assert (json_conn(raw) |> get("/v1/chat/sessions/#{host_sid}")).status == 404
    refute "HOST-CHAT-TITLE" in listed_titles(raw)
  end

  # ── the seats that see it ──────────────────────────────────────────────────

  test "CONTROL: an admin-seat token reads and lists the host session",
       %{admin_raw: admin_raw, host_sid: host_sid} do
    body = json_conn(admin_raw) |> get("/v1/chat/sessions/#{host_sid}") |> json_response(200)

    assert body["id"] == host_sid
    assert "HOST-CHAT-TITLE" in listed_titles(admin_raw)
  end

  test "CONTROL: a member-seat token held for an owner reads and lists it",
       %{ws: ws, host_sid: host_sid} do
    user = register_user("host-reads-#{System.unique_integer([:positive])}@example.test")
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "owner", "user")
    {raw, _} = mint!(["read", "chat"], ws.id, owner_user_id: user.id)

    assert (json_conn(raw) |> get("/v1/chat/sessions/#{host_sid}")).status == 200
    assert "HOST-CHAT-TITLE" in listed_titles(raw)
  end

  test "CONTROL: a member token still reads its managed session",
       %{member_raw: member_raw, managed_sid: managed_sid} do
    assert (json_conn(member_raw) |> get("/v1/chat/sessions/#{managed_sid}")).status == 200
  end

  # ── Studio: the flat mount's unbound superuser ─────────────────────────────

  describe "Studio's flat mount, an unbound admin token (no seat anywhere)" do
    setup %{conn: conn} do
      raw = "host-reads-unbound-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "unbound", @dataset, ["read", "write", "admin"])
      {:ok, _} = token |> Ecto.Changeset.change(%{workspace_id: nil}) |> Repo.update()
      %{conn: init_test_session(conn, %{"api_token" => raw})}
    end

    test "does not load the host session onto the socket, nor list it",
         %{conn: conn, host_sid: host_sid} do
      {:ok, view, _html} = live(conn, "/studio/chat/#{host_sid}")
      assigns = :sys.get_state(view.pid).socket.assigns

      refute assigns[:store_session_id] == host_sid
      refute Enum.any?(assigns[:sessions] || [], &(&1.id == host_sid))
      refute render(view) =~ "HOST-SECRET-OUTPUT"
    end

    test "cannot archive or delete the host session by id from the sidebar",
         %{conn: conn, host_sid: host_sid} do
      {:ok, view, _html} = live(conn, "/studio/chat")

      render_click(view, "session-archive", %{"id" => host_sid})
      assert StudioChat.get_session(host_sid, :global).archived_at == nil

      render_click(view, "session-delete", %{"id" => host_sid})
      assert StudioChat.get_session(host_sid, :global)
    end

    test "CONTROL: still loads a managed session of any workspace (charter D17/D18)",
         %{conn: conn, managed_sid: managed_sid} do
      {:ok, view, _html} = live(conn, "/studio/chat/#{managed_sid}")

      assert :sys.get_state(view.pid).socket.assigns[:store_session_id] == managed_sid
    end
  end
end
