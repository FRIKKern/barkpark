defmodule BarkparkWeb.ChatSendIdempotencyKeyTest do
  @moduledoc """
  `POST /v1/chat/sessions/:id/messages` with an `Idempotency-Key` header is safe
  to retry (task-88749c42544d7f09).

  Without the header each POST is a new turn. A client that sent, lost the 202
  on the way back and sent again ran the turn twice. With the header:

    * a repeat of the same key, for the same session, from the same token, with
      the same body, answers what the first answered (`Idempotency-Replay:
      true`) and dispatches nothing: one lease, one host turn, one user row;
    * the same key with a different request (body or query string) is
      refused 422 `idempotency_key_reused`, and nothing is dispatched;
    * every spelling of the session's path (upper-case id, trailing slash)
      reaches the same key;
    * another token, or another session, never reaches the key;
    * a retry while the first is still being answered gets 409
      `idempotency_key_in_use`;
    * a 503 is not remembered: the turn was not sent, so the retry sends it.

  The key lives in the shared `idempotency_keys` store for 24 hours.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  @moduletag :requires_plugins

  alias Barkpark.Auth
  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.{ExecutionLease, RegisteredHost}
  alias Barkpark.Idempotency
  alias Barkpark.Repo
  alias Barkpark.Repo.IdempotencyStore.Key
  alias Barkpark.StudioChat
  alias Barkpark.Tenancy
  alias BarkparkWeb.Plugs.Idempotency, as: IdempotencyPlug

  @dataset "production"
  @fixture Path.expand("../../support/fixtures/chat_host_go_capabilities.json", __DIR__)

  setup do
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    prev_chat = Application.get_env(:barkpark, :claude_chat)
    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})

    on_exit(fn ->
      reap_recorders()
      Application.put_env(:barkpark, :public_demo_studio, prev_demo)

      if prev_chat,
        do: Application.put_env(:barkpark, :claude_chat, prev_chat),
        else: Application.delete_env(:barkpark, :claude_chat)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "sik-#{suffix}", name: "SIK #{suffix}"})
    raw = "sik-member-#{suffix}"

    {:ok, token} =
      Auth.create_token(raw, "sik-member", @dataset, ["read", "write", "admin"], ws.id)

    other = "sik-other-#{suffix}"
    {:ok, _} = Auth.create_token(other, "sik-other", @dataset, ["read", "write", "admin"], ws.id)

    %{host_id: enroll_host!(ws, "go-host-#{suffix}"), raw: raw, token: token, other: other}
  end

  test "a repeated keyed send runs one turn and stores one user row",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)

    first = send_message(raw, sid, %{content: "once"}, "key-once")
    assert json_response(first, 202) == %{"accepted" => true}
    assert get_resp_header(first, "idempotency-replay") == []

    again = send_message(raw, sid, %{content: "once"}, "key-once")
    assert again.status == 202
    assert again.resp_body == first.resp_body
    assert get_resp_header(again, "idempotency-replay") == ["true"]

    host = Repo.get!(RegisteredHost, host_id)
    assert [%{command: command}] = send_turns(host, sid)
    assert command.payload.content == "once"
    assert [%ExecutionLease{}] = leases(sid)
    assert [%{role: "user", source_markdown: "once"}] = StudioChat.list_messages(sid, :global)
  end

  test "the same key with a different body is refused and dispatches nothing",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    assert send_message(raw, sid, %{content: "first"}, "key-body") |> json_response(202)

    body = send_message(raw, sid, %{content: "second"}, "key-body") |> json_response(422)
    assert body["error"]["code"] == "idempotency_key_reused"

    host = Repo.get!(RegisteredHost, host_id)
    assert [%{command: %{payload: %{content: "first"}}}] = send_turns(host, sid)
    assert [_] = leases(sid)
    assert [%{source_markdown: "first"}] = StudioChat.list_messages(sid, :global)
  end

  # create_message reads query and body params together, so content sent in the
  # query string must be bound as well, or a reused key drops the new message.
  test "the same key with other content in the query string is refused",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    path = "/v1/chat/sessions/#{sid}/messages"
    assert keyed_post(raw, path <> "?content=AAA", "key-query") |> json_response(202)

    body = keyed_post(raw, path <> "?content=BBB", "key-query") |> json_response(422)
    assert body["error"]["code"] == "idempotency_key_reused"

    assert [_] = leases(sid)
    assert [%{source_markdown: "AAA"}] = StudioChat.list_messages(sid, :global)
  end

  test "every spelling of the session's path reaches the same key",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    first = keyed_post(raw, "/v1/chat/sessions/#{sid}/messages", "key-path", %{content: "p"})
    assert json_response(first, 202)

    for path <- [
          "/v1/chat/sessions/#{String.upcase(sid)}/messages",
          "/v1/chat/sessions/#{sid}/messages/"
        ] do
      again = keyed_post(raw, path, "key-path", %{content: "p"})
      assert again.status == 202, "#{path}: #{again.status} #{again.resp_body}"
      assert get_resp_header(again, "idempotency-replay") == ["true"], path
    end

    assert [_] = leases(sid)
    assert [_] = StudioChat.list_messages(sid, :global)
  end

  test "a map and a list of pairs never share a fingerprint" do
    as_map = %{"a" => %{"b" => 1, "c" => 2}}
    as_pairs = %{"a" => [["b", 1], ["c", 2]]}

    refute IdempotencyPlug.bound_scope("s", as_map) == IdempotencyPlug.bound_scope("s", as_pairs)

    assert IdempotencyPlug.bound_scope("s", %{"x" => 1, "y" => 2}) ==
             IdempotencyPlug.bound_scope("s", %{"y" => 2, "x" => 1})
  end

  test "another token sending the same key and body is a new send",
       %{host_id: host_id, raw: raw, other: other} do
    sid = create_host_session!(raw, host_id)
    assert send_message(raw, sid, %{content: "shared"}, "key-shared") |> json_response(202)

    theirs = send_message(other, sid, %{content: "shared"}, "key-shared")
    assert json_response(theirs, 202)
    assert get_resp_header(theirs, "idempotency-replay") == []

    assert length(leases(sid)) == 2
    assert length(StudioChat.list_messages(sid, :global)) == 2
  end

  test "the same key and body sent to another session is a new send",
       %{host_id: host_id, raw: raw} do
    a = create_host_session!(raw, host_id)
    b = create_host_session!(raw, host_id)
    assert send_message(raw, a, %{content: "same"}, "key-two-sessions") |> json_response(202)

    other_session = send_message(raw, b, %{content: "same"}, "key-two-sessions")
    assert json_response(other_session, 202)
    assert get_resp_header(other_session, "idempotency-replay") == []

    assert [_] = leases(a)
    assert [_] = leases(b)
    assert [%{source_markdown: "same"}] = StudioChat.list_messages(b, :global)
  end

  test "without the header every send is a new turn, as before",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    first = send_message(raw, sid, %{content: "twice"}, nil)
    second = send_message(raw, sid, %{content: "twice"}, nil)

    assert json_response(first, 202) == %{"accepted" => true}
    assert json_response(second, 202) == %{"accepted" => true}
    assert get_resp_header(second, "idempotency-replay") == []

    host = Repo.get!(RegisteredHost, host_id)
    assert length(send_turns(host, sid)) == 2
    assert length(leases(sid)) == 2
    assert length(StudioChat.list_messages(sid, :global)) == 2
    assert Repo.aggregate(Key, :count) == 0
  end

  test "a retry while the first send is still being answered is refused 409",
       %{host_id: host_id, raw: raw, token: token} do
    sid = create_host_session!(raw, host_id)
    path = "/v1/chat/sessions/#{sid}/messages"
    hash = Idempotency.hash_key("key-busy", token.id, "POST", path)
    scope = IdempotencyPlug.bound_scope("chat_send", %{"content" => "busy"})
    assert Idempotency.claim(hash, scope) == :claimed

    body = send_message(raw, sid, %{content: "busy"}, "key-busy") |> json_response(409)
    assert body["error"]["code"] == "idempotency_key_in_use"
    assert leases(sid) == []
  end

  test "a 503 is not remembered: the retry with the same key sends the turn",
       %{host_id: host_id, raw: raw} do
    sid = create_host_session!(raw, host_id)
    fail_user_inserts!()

    capture_log(fn ->
      assert send_message(raw, sid, %{content: "retry me"}, "key-503") |> json_response(503)
    end)

    Repo.query!("DROP TRIGGER sik_fail_user_rows ON chat_messages")

    retry = send_message(raw, sid, %{content: "retry me"}, "key-503")
    assert json_response(retry, 202)
    assert get_resp_header(retry, "idempotency-replay") == []
    assert [%{source_markdown: "retry me"}] = StudioChat.list_messages(sid, :global)
  end

  test "a keyed send costs two more queries than an unkeyed one; a replay runs no turn query",
       %{host_id: host_id, raw: raw} do
    plain_sid = create_host_session!(raw, host_id)
    keyed_sid = create_host_session!(raw, host_id)

    plain = count_queries(fn -> send_message(raw, plain_sid, %{content: "q"}, nil) end)
    keyed = count_queries(fn -> send_message(raw, keyed_sid, %{content: "q"}, "key-q") end)
    replay = count_queries(fn -> send_message(raw, keyed_sid, %{content: "q"}, "key-q") end)

    assert keyed == plain + 2
    assert replay < plain
  end

  # Statements the request process issues, counted from Ecto's own telemetry.
  defp count_queries(fun) do
    me = self()
    ref = make_ref()
    id = "sik-count-#{inspect(ref)}"

    :telemetry.attach(
      id,
      [:barkpark, :repo, :query],
      fn _, _, _, _ -> if self() == me, do: send(me, {ref, :query}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain(ref, 0)
  end

  defp drain(ref, n) do
    receive do
      {^ref, :query} -> drain(ref, n + 1)
    after
      0 -> n
    end
  end

  defp fail_user_inserts! do
    Repo.query!("""
    CREATE FUNCTION sik_fail_user_rows() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.role = 'user' THEN RAISE EXCEPTION 'injected store fault'; END IF;
      RETURN NEW;
    END $$
    """)

    Repo.query!(
      "CREATE TRIGGER sik_fail_user_rows BEFORE INSERT ON chat_messages " <>
        "FOR EACH ROW EXECUTE FUNCTION sik_fail_user_rows()"
    )
  end

  defp enroll_host!(ws, name) do
    {:ok, issued} =
      ChatHosts.issue_enrollment(ws.id, %{name: name, approved_roots: [System.tmp_dir!()]})

    caps = @fixture |> File.read!() |> Jason.decode!()

    {:ok, %{credential: credential}} =
      ChatHosts.enroll(issued.enrollment_token, %{"protocol_version" => 1, "capabilities" => caps})

    {:ok, host} = ChatHosts.authenticate(credential)
    {:ok, _} = ChatHosts.heartbeat(host, %{"protocol_version" => 1, "capabilities" => caps})
    issued.host.id
  end

  defp json_conn(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp create_host_session!(raw, host_id) do
    json_conn(raw)
    |> post(
      "/v1/chat/sessions",
      Jason.encode!(%{
        provider: "claude",
        execution_target: "registered_host",
        execution_host_id: host_id
      })
    )
    |> json_response(201)
    |> Map.fetch!("id")
  end

  defp send_message(raw, sid, body, key) do
    conn = json_conn(raw)
    conn = if key, do: put_req_header(conn, "idempotency-key", key), else: conn
    post(conn, "/v1/chat/sessions/#{sid}/messages", Jason.encode!(body))
  end

  defp keyed_post(raw, path, key, body \\ %{}) do
    raw
    |> json_conn()
    |> put_req_header("idempotency-key", key)
    |> post(path, Jason.encode!(body))
  end

  defp send_turns(host, sid) do
    host
    |> ChatHosts.next_commands()
    |> Enum.filter(&(&1.command.operation == :send_turn and &1.command.session_id == sid))
  end

  defp leases(sid), do: Repo.all(from(l in ExecutionLease, where: l.session_id == ^sid))

  defp reap_recorders do
    if pid = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
      for {_, child, _, _} <- DynamicSupervisor.which_children(pid), is_pid(child) do
        DynamicSupervisor.terminate_child(pid, child)
      end
    end
  catch
    :exit, _ -> :ok
  end
end
