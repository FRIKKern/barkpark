defmodule BarkparkWeb.ChatScopeTenantAdminTest do
  @moduledoc """
  `/v1/chat` scope of an `admin` token that belongs to a tenant workspace
  (task-f98c47f23e7bde9a).

  With the operator allowlist unset, `RequireChatAccess` gave `:global` to ANY
  token carrying `admin`, whatever its workspace: a tenant-B admin token read,
  streamed and wrote workspace A's (and the Default workspace's) sessions. It
  now gets its own workspace's chat. `:global` stays with the legacy instance
  operator: an admin token of the Default workspace or of no workspace. With
  the allowlist armed nothing changes.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, StudioChat}
  alias Barkpark.StudioChat.Recorder
  alias BarkparkWeb.Studio.ClaudeChat

  @sentinel "SENTINEL-TITLE-ON-THE-STREAM"
  @admin ["read", "write", "admin"]
  @env_keys [:claude_chat, :public_demo_studio, :operator_emails, :operator_token_ids]

  setup do
    Barkpark.ChatSessionResidue.purge!()
    {default_ws, _} = ensure_default_scope!()
    prev = Map.new(@env_keys, &{&1, Application.get_env(:barkpark, &1)})

    Application.put_env(:barkpark, :claude_chat,
      enabled: true,
      execution_profile: :self_hosted,
      command: {"cat", []}
    )

    Application.put_env(:barkpark, :public_demo_studio, false)
    Application.put_env(:barkpark, :operator_emails, [])
    Application.put_env(:barkpark, :operator_token_ids, [])

    on_exit(fn ->
      if sup = Process.whereis(Barkpark.StudioChat.RuntimeSupervisor) do
        for {_, pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(pid) do
          DynamicSupervisor.terminate_child(sup, pid)
        end
      end

      for {key, val} <- prev do
        if is_nil(val),
          do: Application.delete_env(:barkpark, key),
          else: Application.put_env(:barkpark, key, val)
      end
    end)

    ws_a = create_workspace!()
    ws_b = create_workspace!()

    %{
      default_ws: default_ws,
      ws_a: ws_a,
      ws_b: ws_b,
      sid_a: session!(ws_a.id),
      sid_b: session!(ws_b.id),
      sid_default: session!(default_ws.id),
      b_chat: mint!(["read", "chat"], ws_b.id)
    }
  end

  defp mint!(perms, ws_id) do
    raw = "chat-scope-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "chat scope", "production", perms, ws_id)
    raw
  end

  defp session!(ws_id) do
    sid = Ecto.UUID.generate()
    attrs = %{id: sid, cwd: ClaudeChat.cwd(), mode: "plan", provider: "claude"}
    {:ok, _} = StudioChat.create_session(attrs, {:workspace, ws_id})
    sid
  end

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp show(raw, sid), do: as(raw) |> get("/v1/chat/sessions/#{sid}")

  defp listed(raw) do
    resp = as(raw) |> get("/v1/chat/sessions")
    for s <- json_response(resp, 200)["sessions"], do: s["id"]
  end

  # Open the events stream; when it is accepted, put one title frame on the
  # session topic and retire it. Returns `{status, body}`.
  defp stream(raw, sid) do
    task = Task.async(fn -> as(raw) |> get("/v1/chat/sessions/#{sid}/events") end)
    Process.sleep(300)
    topic = Recorder.topic(sid)
    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, {:chat_title, sid, @sentinel})
    Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, :retire)

    case Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, conn} -> {conn.status, conn.resp_body}
      _ -> flunk("the events stream neither refused nor ended on :retire")
    end
  end

  # The herd stream: the connect snapshot of every session in scope, then retire.
  defp fleet_snapshot(raw) do
    task = Task.async(fn -> as(raw) |> get("/v1/chat/events") end)
    Process.sleep(300)
    send(task.pid, :retire)

    case Task.yield(task, 3_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, %{status: 200} = conn} -> conn.resp_body
      _ -> flunk("the fleet stream did not open and end on :retire")
    end
  end

  defp rollup_total(raw) do
    resp = as(raw) |> get("/v1/chat/rollup")
    json_response(resp, 200)["counts"] |> Map.values() |> Enum.sum()
  end

  # Every write door on a session id, in router order. `{door, status}` each.
  defp write_doors(raw, sid) do
    post_json = fn path, body ->
      as(raw) |> post("/v1/chat/sessions/#{sid}#{path}", Jason.encode!(body))
    end

    [
      patch: as(raw) |> patch("/v1/chat/sessions/#{sid}", Jason.encode!(%{draft: "written"})),
      messages: post_json.("/messages", %{content: "hello"}),
      interrupt: post_json.("/interrupt", %{}),
      approval: post_json.("/approval", %{request_id: "req-1", decision: "deny"}),
      answer: post_json.("/answer", %{request_id: "req-1", answers: %{"q" => "a"}}),
      archive: post_json.("/archive", %{}),
      unarchive: post_json.("/unarchive", %{}),
      # An empty upload: 400 past the tenant oracle, 404 before it.
      attachments: post_json.("/attachments", %{})
    ]
    |> Enum.map(fn {door, resp} -> {door, resp.status} end)
  end

  defp all_404(doors), do: Enum.map(doors, fn {door, _} -> {door, 404} end)

  defp arm_allowlist!(token_ids),
    do: Application.put_env(:barkpark, :operator_token_ids, token_ids)

  describe "allowlist unset: a tenant admin token and ANOTHER workspace's sessions" do
    test "show, stream and list answer as they do for the tenant's chat token", ctx do
      raw = mint!(@admin, ctx.ws_b.id)

      assert show(ctx.b_chat, ctx.sid_a).status == 404
      assert show(raw, ctx.sid_a).status == 404
      assert show(raw, ctx.sid_default).status == 404

      assert {404, chat_body} = stream(ctx.b_chat, ctx.sid_a)
      assert {404, admin_body} = stream(raw, ctx.sid_a)
      refute admin_body =~ @sentinel

      assert Jason.decode!(admin_body)["error"]["code"] ==
               Jason.decode!(chat_body)["error"]["code"]

      ids = listed(raw)
      refute ctx.sid_a in ids
      refute ctx.sid_default in ids
      assert ctx.sid_b in ids

      herd = fleet_snapshot(raw)
      refute herd =~ ctx.sid_a
      refute herd =~ ctx.sid_default
      assert herd =~ ctx.sid_b
      assert rollup_total(raw) == 1
    end

    test "every write door on workspace A's session is the not-found oracle", ctx do
      raw = mint!(@admin, ctx.ws_b.id)

      assert write_doors(ctx.b_chat, ctx.sid_a) == all_404(write_doors(ctx.b_chat, ctx.sid_a))
      assert write_doors(raw, ctx.sid_a) == all_404(write_doors(raw, ctx.sid_a))

      row = StudioChat.get_session(ctx.sid_a, :global)
      assert {row.draft, row.archived_at} == {nil, nil}
    end

    test "a turn on the Default workspace's host session is the not-found oracle", ctx do
      raw = mint!(@admin, ctx.ws_b.id)

      assert write_doors(raw, ctx.sid_default) == all_404(write_doors(raw, ctx.sid_default))
      assert StudioChat.get_session(ctx.sid_default, :global).message_count in [nil, 0]
      assert Recorder.whereis(ctx.sid_default) == nil
    end

    test "an admin token that also carries chat is held the same way", ctx do
      raw = mint!(@admin ++ ["chat"], ctx.ws_b.id)

      assert show(raw, ctx.sid_a).status == 404
      assert {404, _} = stream(raw, ctx.sid_a)
      assert write_doors(raw, ctx.sid_a) == all_404(write_doors(raw, ctx.sid_a))
    end
  end

  describe "allowlist unset: a tenant admin token and its OWN workspace's sessions" do
    for {name, extra} <- [{"without chat", []}, {"with chat", ["chat"]}] do
      test "reads, lists, streams and writes them (admin #{name})", ctx do
        raw = mint!(@admin ++ unquote(extra), ctx.ws_b.id)

        assert json_response(show(raw, ctx.sid_b), 200)["id"] == ctx.sid_b
        assert ctx.sid_b in listed(raw)

        assert {200, body} = stream(raw, ctx.sid_b)
        assert body =~ @sentinel

        # `messages` and `answer` are a managed turn on the instance host, which
        # no tenant-owned session may run: 403, before and after this change.
        assert write_doors(raw, ctx.sid_b) == [
                 patch: 200,
                 messages: 403,
                 interrupt: 202,
                 approval: 204,
                 answer: 403,
                 archive: 200,
                 unarchive: 200,
                 attachments: 400
               ]

        assert StudioChat.get_session(ctx.sid_b, :global).draft == "written"

        created = as(raw) |> post("/v1/chat/sessions", Jason.encode!(%{}))
        new_id = json_response(created, 201)["id"]
        assert StudioChat.get_session(new_id, :global).owner_workspace_id == ctx.ws_b.id
        assert json_response(show(raw, new_id), 200)["id"] == new_id
      end
    end
  end

  describe "allowlist unset: the legacy instance operator keeps :global" do
    test "a Default-workspace admin token and a no-workspace admin token read every session",
         ctx do
      for raw <- [mint!(@admin, ctx.default_ws.id), mint!(@admin, nil)] do
        for sid <- [ctx.sid_a, ctx.sid_b, ctx.sid_default] do
          assert show(raw, sid).status == 200
        end

        ids = listed(raw)
        assert ctx.sid_a in ids and ctx.sid_b in ids and ctx.sid_default in ids

        assert {200, body} = stream(raw, ctx.sid_a)
        assert body =~ @sentinel

        herd = fleet_snapshot(raw)
        assert herd =~ ctx.sid_a and herd =~ ctx.sid_b and herd =~ ctx.sid_default
        assert rollup_total(raw) >= 3
      end
    end
  end

  describe "allowlist armed: unchanged" do
    test "an allowlisted tenant admin token is :global", ctx do
      raw = "chat-scope-op-" <> Ecto.UUID.generate()
      {:ok, token} = Auth.create_token(raw, "op", "production", @admin, ctx.ws_b.id)
      arm_allowlist!([token.id])

      assert show(raw, ctx.sid_a).status == 200
      assert show(raw, ctx.sid_b).status == 200
      assert ctx.sid_a in listed(raw)
    end

    test "a tenant admin token outside it: own workspace with chat, refused without", ctx do
      {:ok, op} = Auth.create_token("op-" <> Ecto.UUID.generate(), "op", "production", @admin)
      arm_allowlist!([op.id])

      with_chat = mint!(@admin ++ ["chat"], ctx.ws_b.id)
      assert show(with_chat, ctx.sid_b).status == 200
      assert show(with_chat, ctx.sid_a).status == 404
      assert listed(with_chat) == [ctx.sid_b]

      for raw <- [
            mint!(@admin, ctx.ws_b.id),
            mint!(@admin, ctx.default_ws.id),
            mint!(@admin, nil)
          ] do
        for sid <- [ctx.sid_a, ctx.sid_b] do
          resp = show(raw, sid)
          assert json_response(resp, 403)["error"]["code"] == "host_execution_not_permitted"
        end
      end
    end
  end
end
