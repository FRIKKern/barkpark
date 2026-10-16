defmodule BarkparkWeb.PersonalChatControllerTest do
  use BarkparkWeb.ConnCase, async: false
  @moduletag :requires_plugins
  import Barkpark.TenancyFixtures
  import Ecto.Query
  alias Barkpark.{Accounts, Auth, Repo, StudioChat}
  alias Barkpark.Accounts.UserSession
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "personal chat test password"

  setup do
    ws = create_workspace!()
    other_ws = create_workspace!()
    {alice, a} = login_member(ws)
    {bob, b} = login_member(ws)
    {:ok, _} = TenancyAuth.create_membership(other_ws.id, alice.id, "member", "user")
    raw = "personal-chat-token-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "workspace chat", "production", ["chat"], ws.id)
    %{ws: ws, other_ws: other_ws, alice: alice, a: a, bob: bob, b: b, api: raw}
  end

  defp login_member(ws) do
    email = "personal-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

    response =
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
      |> json_response(201)

    {user, response["token"]}
  end

  defp call(raw, method, path, body \\ %{}) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, Jason.encode!(body))
  end

  defp base(ws), do: "/w/#{ws.slug}/v1/personal-chat"

  defp create(ctx),
    do:
      call(ctx.a, :post, base(ctx.ws) <> "/sessions", %{title: "Private title"})
      |> json_response(201)

  test "real login creates a server-owned row and reopening returns persisted user/assistant text without internal metadata",
       ctx do
    body = create(ctx)
    row = StudioChat.get_session(body["id"])
    assert row.owner_user_id == ctx.alice.id
    assert row.owner_workspace_id == ctx.ws.id
    assert body["runtime_available"] == false

    {:ok, _} =
      StudioChat.append_message(row, %{role: "user", source_markdown: "first-year students"})

    {:ok, _} =
      StudioChat.append_message(row, %{
        role: "assistant",
        source_markdown: "fixture only",
        metadata: %{"internal" => "hidden"}
      })

    {:ok, _} =
      StudioChat.append_message(row, %{role: "thinking", source_markdown: "not public answer"})

    read = call(ctx.a, :get, base(ctx.ws) <> "/sessions/#{row.id}") |> json_response(200)

    assert Enum.map(read["messages"], & &1["source_markdown"]) == [
             "first-year students",
             "fixture only"
           ]

    refute Jason.encode!(read) =~ "internal"
    refute Jason.encode!(read) =~ "not public answer"
    assert call(ctx.b, :get, base(ctx.ws) <> "/sessions/#{row.id}").status == 404
    assert call(ctx.a, :get, base(ctx.other_ws) <> "/sessions/#{row.id}").status == 404

    assert call(ctx.b, :get, base(ctx.ws) <> "/sessions")
           |> json_response(200)
           |> Map.fetch!("sessions") == []
  end

  test "history is a bounded ascending page with an explicit continuation, never a tail", ctx do
    body = create(ctx)
    row = StudioChat.get_session(body["id"])

    for seq <- 1..205 do
      role = if rem(seq, 2) == 1, do: "user", else: "thinking"
      {:ok, _} = StudioChat.append_message(row, %{role: role, source_markdown: "row #{seq}"})
    end

    path = base(ctx.ws) <> "/sessions/#{row.id}"
    first = call(ctx.a, :get, path) |> json_response(200)
    assert Enum.map(first["messages"], & &1["seq"]) == Enum.to_list(1..199//2)
    assert first["page"] == %{"has_more" => true, "next_since" => 199}
    second = call(ctx.a, :get, path <> "?since=199") |> json_response(200)
    assert Enum.map(second["messages"], & &1["seq"]) == [201, 203, 205]
    assert second["page"] == %{"has_more" => false, "next_since" => nil}
    empty = call(ctx.a, :get, path <> "?since=205") |> json_response(200)
    assert empty["messages"] == []
    assert empty["page"] == %{"has_more" => false, "next_since" => nil}
    assert call(ctx.b, :get, path <> "?since=199").status == 404

    for invalid <- ["-1", "text", "2147483648"] do
      assert call(ctx.a, :get, path <> "?since=" <> invalid).status == 400
    end
  end

  test "ownership, runtime configuration and imported assistant history are not client writable",
       ctx do
    for attrs <- [
          %{id: Ecto.UUID.generate()},
          %{owner_user_id: ctx.bob.id},
          %{owner_workspace_id: ctx.other_ws.id},
          %{provider: "codex"},
          %{messages: [%{role: "assistant", text: "fake"}]}
        ] do
      assert call(ctx.a, :post, base(ctx.ws) <> "/sessions", attrs).status == 400
    end

    row = create(ctx)

    for attrs <- [%{owner_user_id: ctx.bob.id}, %{model_choice: "anything"}, %{messages: []}] do
      assert call(ctx.a, :patch, base(ctx.ws) <> "/sessions/#{row["id"]}", attrs).status == 400
    end

    assert call(ctx.b, :patch, base(ctx.ws) <> "/sessions/#{row["id"]}", %{title: "stolen"}).status ==
             404
  end

  test "title, draft, archive and restore preserve the same owner", ctx do
    row = create(ctx)
    path = base(ctx.ws) <> "/sessions/#{row["id"]}"

    assert call(ctx.a, :patch, path, %{title: "A correction", draft: "For nursing students"}).status ==
             200

    assert call(ctx.a, :post, path <> "/archive").status == 200
    assert call(ctx.b, :post, path <> "/unarchive").status == 404

    assert call(ctx.a, :get, base(ctx.ws) <> "/sessions")
           |> json_response(200)
           |> Map.fetch!("sessions") == []

    assert length(
             call(ctx.a, :get, base(ctx.ws) <> "/sessions?archived=true")
             |> json_response(200)
             |> Map.fetch!("sessions")
           ) == 1

    assert call(ctx.a, :post, path <> "/unarchive").status == 200
    read = call(ctx.a, :get, path) |> json_response(200)
    assert read["title"] == "A correction"
    assert read["draft"] == "For nursing students"
    assert StudioChat.get_session(row["id"]).owner_user_id == ctx.alice.id
  end

  test "all unbound runtime, SSE and attachment paths refuse before any runtime or byte-store work",
       ctx do
    row = create(ctx)
    path = base(ctx.ws) <> "/sessions/#{row["id"]}"

    for {method, suffix} <- [
          {:post, "/messages"},
          {:post, "/interrupt"},
          {:post, "/approval"},
          {:post, "/answer"},
          {:get, "/events"},
          {:post, "/attachments"},
          {:get, "/attachments/unknown"}
        ] do
      own = call(ctx.a, method, path <> suffix, %{content: "Do not call a model"})
      assert own.status == 503, own.resp_body
      assert own.resp_body =~ "personal_chat_runtime_unavailable"
      assert call(ctx.b, method, path <> suffix).status == 404

      assert call(ctx.a, method, String.replace(path, row["id"], Ecto.UUID.generate()) <> suffix).status ==
               404
    end

    assert StudioChat.list_messages(row["id"], {:personal, ctx.ws.id, ctx.alice.id}) == []
    assert Barkpark.StudioChat.Recorder.whereis(row["id"]) == nil

    for suffix <- ["/events", "/rollup", "/managed-session"] do
      assert call(ctx.a, :get, base(ctx.ws) <> suffix).status == 503
    end
  end

  test "workspace API tokens retain legacy rows and cannot discover personal rows", ctx do
    row = create(ctx)
    {:ok, legacy} = StudioChat.create_session(%{id: Ecto.UUID.generate()}, ctx.ws.id)
    assert call(ctx.api, :get, base(ctx.ws) <> "/sessions").status == 401
    index = call(ctx.api, :get, "/v1/chat/sessions") |> json_response(200)
    assert Enum.map(index["sessions"], & &1["id"]) == [legacy.id]

    for {method, suffix} <- [
          {:get, ""},
          {:patch, ""},
          {:post, "/messages"},
          {:post, "/interrupt"},
          {:post, "/approval"},
          {:post, "/answer"},
          {:post, "/archive"},
          {:post, "/unarchive"},
          {:get, "/events"},
          {:post, "/attachments"},
          {:get, "/attachments/unknown"}
        ] do
      body =
        case suffix do
          "/approval" -> %{request_id: "unknown", decision: "deny"}
          "/answer" -> %{request_id: "unknown", answers: %{"Question" => "Choice"}}
          _ -> %{content: "ignored"}
        end

      refused = call(ctx.api, method, "/v1/chat/sessions/#{row["id"]}" <> suffix, body)
      assert refused.status == 404, "#{method} #{suffix}: #{refused.resp_body}"
    end

    assert StudioChat.fleet_snapshot(ctx.ws.id) |> Enum.map(& &1.session_id) == [legacy.id]
    assert StudioChat.rollup(ctx.ws.id).counts.idle == 1
    # Existing instance-operator scope remains explicitly privileged.
    assert StudioChat.get_session(row["id"], :global).owner_user_id == ctx.alice.id
  end

  test "missing and revoked sessions are refused and invalid bearer never falls back to a cookie",
       ctx do
    url = base(ctx.ws) <> "/sessions"
    assert scoped_conn() |> get(url) |> response(401)
    assert {:ok, 1} = Accounts.revoke_user_session_token(ctx.a)
    assert call(ctx.a, :get, url).status == 401

    conn =
      scoped_conn()
      |> Plug.Test.init_test_session(%{"user_session" => ctx.b})
      |> put_req_header("authorization", "Bearer invalid")
      |> get(url)

    assert conn.status == 401
  end

  test "expired sessions and removed workspace seats cannot read or restore", ctx do
    row = create(ctx)

    Repo.update_all(from(s in UserSession, where: s.user_id == ^ctx.alice.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
    )

    assert call(ctx.a, :get, base(ctx.ws) <> "/sessions/#{row["id"]}").status == 401
    Repo.delete_all(from(m in Barkpark.Tenancy.Membership, where: m.principal_id == ^ctx.bob.id))
    assert call(ctx.b, :get, base(ctx.ws) <> "/sessions").status == 403
    assert call(ctx.b, :post, base(ctx.ws) <> "/sessions/#{row["id"]}/unarchive").status == 403
  end

  test "cookie writes require the existing CSRF guard", ctx do
    url = base(ctx.ws) <> "/sessions"

    cookie = fn ->
      scoped_conn()
      |> Plug.Test.init_test_session(%{"user_session" => ctx.a})
      |> put_req_header("content-type", "application/json")
    end

    assert cookie.() |> get(url) |> response(200)
    assert cookie.() |> post(url, "{}") |> response(403)

    assert cookie.()
           |> put_req_header("x-requested-with", "XMLHttpRequest")
           |> post(url, "{}")
           |> response(201)
  end

  test "a workspace read grant without a seat cannot open personal chat", ctx do
    Repo.delete_all(from(m in Barkpark.Tenancy.Membership, where: m.principal_id == ^ctx.bob.id))

    {:ok, admin} =
      Auth.create_token(
        "grant-admin-#{System.unique_integer([:positive])}",
        "grant admin",
        "production",
        ["read", "write", "admin"]
      )

    {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, admin.id, "admin", "api_token")

    {:ok, %{token: raw}} =
      Barkpark.Access.mint(admin, %{
        grantee_email: ctx.bob.email,
        workspace_id: ctx.ws.id,
        capabilities: ["read"]
      })

    assert {:ok, _} = Barkpark.Access.claim(raw, ctx.bob)
    refused = call(ctx.b, :get, base(ctx.ws) <> "/sessions")
    assert refused.status == 403
    assert refused.resp_body =~ "personal_chat_membership_required"
  end
end
