defmodule BarkparkWeb.ChatHostReportStateTest do
  @moduledoc """
  POST /v1/chat/sessions/:id/state (herd-s6, charter D78h–D80h): the fenced
  external reporter's authoritative herd-state write, end-to-end through the
  `:registered_chat_host` pipeline. Every fence deny leg is exercised over HTTP
  with a REAL enrolled host + a REAL execution lease — the fence is a literal
  chat_execution_leases reuse (D79h), and the deny grammar mirrors
  /v1/chat-host/events: stale_fence / lease_expired → 409, no lease → 422,
  bad vocabulary → 422 before the store is ever touched.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query

  alias Barkpark.ChatHosts
  alias Barkpark.ChatHosts.ExecutionLease
  alias Barkpark.Repo
  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Recorder
  alias Barkpark.StudioChat.Runtime.Command
  alias Barkpark.Tenancy

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "rs-#{suffix}", name: "RS #{suffix}"})

    {:ok, %{enrollment_token: token}} = ChatHosts.issue_enrollment(ws.id, %{name: "reporter"})
    {:ok, %{credential: credential}} = ChatHosts.enroll(token)
    {:ok, host} = ChatHosts.authenticate(credential)

    sid = Ecto.UUID.generate()
    {:ok, _} = StudioChat.create_session(%{id: sid, mode: "plan"}, {:workspace, ws.id})

    %{ws: ws, host: host, credential: credential, sid: sid}
  end

  # The real lease mint (the dispatch path a registered host actually rides).
  defp lease!(host, sid) do
    command = %Command{
      operation: :start,
      provider: "claude",
      session_id: sid,
      idempotency_key: "rs-cmd-#{System.unique_integer([:positive])}",
      payload: %{}
    }

    {:ok, fence} = ChatHosts.lease_and_enqueue(host, command, [])
    fence
  end

  defp as_host(credential) do
    scoped_conn()
    |> put_req_header("authorization", "Host #{credential}")
    |> put_req_header("content-type", "application/json")
  end

  defp report(credential, sid, body) do
    as_host(credential) |> post("/v1/chat/sessions/#{sid}/state", body)
  end

  defp agent_state(sid), do: StudioChat.get_session(sid).agent_state

  test "a fenced report writes the column, returns the fence receipt, and speaks on the fleet-feeding topic",
       %{credential: credential, host: host, sid: sid, ws: ws} do
    Phoenix.PubSub.subscribe(Barkpark.PubSub, Recorder.activity_topic())
    fence = lease!(host, sid)

    body =
      report(credential, sid, %{"state" => "working", "epoch" => fence.epoch})
      |> json_response(200)

    assert body["session_id"] == sid
    assert body["agent_state"] == "working"
    assert body["lease_id"] == fence.lease_id
    assert body["epoch"] == fence.epoch
    assert is_binary(body["expires_at"])

    assert agent_state(sid) == "working"
    ws_id = ws.id

    assert_receive {:chat_reported_state, ^sid,
                    %{agent_state: "working", owner_workspace_id: ^ws_id}}
  end

  test "a fenced BLOCKED report writes — the live fence IS the D80h corroboration",
       %{credential: credential, host: host, sid: sid} do
    fence = lease!(host, sid)

    assert report(credential, sid, %{"state" => "blocked", "epoch" => fence.epoch})
           |> json_response(200)

    assert agent_state(sid) == "blocked"
  end

  test "422 before the store: an off-vocabulary state never lands",
       %{credential: credential, host: host, sid: sid} do
    _fence = lease!(host, sid)

    body = report(credential, sid, %{"state" => "busy", "epoch" => 1}) |> json_response(422)
    assert body["error"]["code"] == "invalid_state_report"
    assert agent_state(sid) == "idle"
  end

  test "422: a missing or non-integer epoch never reaches the fence",
       %{credential: credential, host: host, sid: sid} do
    _fence = lease!(host, sid)

    assert report(credential, sid, %{"state" => "working"})
           |> json_response(422)
           |> get_in(["error", "code"]) == "invalid_state_report"

    assert report(credential, sid, %{"state" => "working", "epoch" => "1"})
           |> json_response(422)
           |> get_in(["error", "code"]) == "invalid_state_report"

    assert agent_state(sid) == "idle"
  end

  test "409 stale_fence: a wrong epoch is refused (compared though vestigial — never bumped today)",
       %{credential: credential, host: host, sid: sid} do
    fence = lease!(host, sid)

    body =
      report(credential, sid, %{"state" => "working", "epoch" => fence.epoch + 1})
      |> json_response(409)

    assert body["error"]["code"] == "stale_fence"
    assert agent_state(sid) == "idle"
  end

  test "409 stale_fence: another registered host cannot report over the fence holder's lease",
       %{host: host, sid: sid, ws: ws} do
    fence = lease!(host, sid)

    {:ok, %{enrollment_token: token2}} = ChatHosts.issue_enrollment(ws.id, %{name: "intruder"})
    {:ok, %{credential: credential2}} = ChatHosts.enroll(token2)

    body =
      report(credential2, sid, %{"state" => "working", "epoch" => fence.epoch})
      |> json_response(409)

    assert body["error"]["code"] == "stale_fence"
    assert agent_state(sid) == "idle"
  end

  test "409 stale_fence: a revoked lease no longer fences",
       %{credential: credential, host: host, sid: sid} do
    fence = lease!(host, sid)

    {1, _} =
      Repo.update_all(
        from(l in ExecutionLease, where: l.id == ^fence.lease_id),
        set: [revoked_at: DateTime.utc_now()]
      )

    body =
      report(credential, sid, %{"state" => "working", "epoch" => fence.epoch})
      |> json_response(409)

    assert body["error"]["code"] == "stale_fence"
    assert agent_state(sid) == "idle"
  end

  test "409 lease_expired: the dead-reporter clock — an expired lease is refused",
       %{credential: credential, host: host, sid: sid} do
    fence = lease!(host, sid)

    {1, _} =
      Repo.update_all(
        from(l in ExecutionLease, where: l.id == ^fence.lease_id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -5, :second)]
      )

    body =
      report(credential, sid, %{"state" => "working", "epoch" => fence.epoch})
      |> json_response(409)

    assert body["error"]["code"] == "lease_expired"
    assert agent_state(sid) == "idle"
  end

  test "422 lease_not_found: a session with no lease at all has no fence to hold",
       %{credential: credential, sid: sid} do
    body = report(credential, sid, %{"state" => "working", "epoch" => 1}) |> json_response(422)
    assert body["error"]["code"] == "unprocessable"
    assert body["error"]["message"] =~ "lease_not_found"
    assert agent_state(sid) == "idle"
  end

  test "multi-lease selection (D79h): the LATEST live lease is the fence row",
       %{credential: credential, host: host, sid: sid} do
    old_fence = lease!(host, sid)

    # the older lease settles (completed leaves the leased/running selection)
    {1, _} =
      Repo.update_all(
        from(l in ExecutionLease, where: l.id == ^old_fence.lease_id),
        set: [status: "completed"]
      )

    fresh = lease!(host, sid)

    body =
      report(credential, sid, %{"state" => "unknown", "epoch" => fresh.epoch})
      |> json_response(200)

    assert body["lease_id"] == fresh.lease_id
    assert agent_state(sid) == "unknown"
  end

  test "401: no host credential, no report", %{sid: sid} do
    conn =
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/chat/sessions/#{sid}/state", %{"state" => "working", "epoch" => 1})

    assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    assert agent_state(sid) == "idle"
  end
end
