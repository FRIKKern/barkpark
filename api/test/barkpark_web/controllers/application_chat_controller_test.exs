defmodule BarkparkWeb.ApplicationChatControllerTest do
  use BarkparkWeb.ConnCase, async: false
  @moduletag :requires_plugins
  import Barkpark.TenancyFixtures
  alias Barkpark.{Accounts, ChatHosts, Repo, StudioChat}

  setup do
    ws = create_workspace!()
    {user, raw} = login(ws)
    {_, other} = login(ws)

    {:ok, enrollment} =
      ChatHosts.issue_enrollment(ws.id, %{name: "test application", approved_roots: []})

    {:ok, enrolled} = ChatHosts.enroll(enrollment.enrollment_token)
    {:ok, host} = ChatHosts.authenticate(enrolled.credential)
    old = Application.get_env(:barkpark, :personal_chat_applications)

    Application.put_env(:barkpark, :personal_chat_applications, %{
      "fixture" => %{
        workspace_id: ws.id,
        host_id: host.id,
        version: "1",
        contract_version: "fixture/1"
      }
    })

    on_exit(fn ->
      if old,
        do: Application.put_env(:barkpark, :personal_chat_applications, old),
        else: Application.delete_env(:barkpark, :personal_chat_applications)
    end)

    %{ws: ws, user: user, raw: raw, other: other, host: host, credential: enrolled.credential}
  end

  defp login(ws) do
    email = "application-http-#{System.unique_integer([:positive])}@example.com"
    password = "application HTTP test password"
    {:ok, user} = Accounts.register_user(%{email: email, password: password})
    Accounts.confirm_provisioned_user(user)
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")

    response =
      scoped_conn()
      |> put_req_header("content-type", "application/json")
      |> post("/v1/auth/login", Jason.encode!(%{email: email, password: password}))
      |> json_response(201)

    {user, response["token"]}
  end

  defp call(auth, method, path, body \\ %{}),
    do:
      scoped_conn()
      |> put_req_header("authorization", auth)
      |> put_req_header("content-type", "application/json")
      |> dispatch(@endpoint, method, path, Jason.encode!(body))

  defp base(ctx), do: "/w/#{ctx.ws.slug}/v1/personal-chat"

  defp create(ctx),
    do:
      call("Bearer " <> ctx.raw, :post, base(ctx) <> "/applications/fixture/sessions")
      |> json_response(201)

  defp accept(ctx, id),
    do:
      call("Bearer " <> ctx.raw, :post, base(ctx) <> "/sessions/#{id}/turns", %{
        query: "Fictional follow-up",
        request_id: "request-1",
        expected_revision: 0
      })
      |> json_response(200)

  test "real login accepts only raw input and separate bound host commits versioned context",
       ctx do
    created = create(ctx)
    turn = accept(ctx, created["id"])
    path = "/v1/chat-host/application-turns/#{turn["id"]}"
    work = call("Host " <> ctx.credential, :get, path) |> json_response(200)
    assert work["actor_user_id"] == ctx.user.id
    assert work["query"] == "Fictional follow-up"
    refute Map.has_key?(work, "actor_session_id")

    body = %{
      epoch: turn["epoch"],
      expected_revision: 0,
      request_digest: turn["request_digest"],
      result: %{
        contract_version: "fixture/1",
        context: %{audience: "students"},
        selection: [],
        source_identities: [],
        answer: %{
          id: "answer-1",
          text: "Fictional test result",
          presentation: %{statements: [], citations: []}
        }
      }
    }

    assert call("Bearer " <> ctx.raw, :post, path <> "/commit", body).status == 401
    result = call("Host " <> ctx.credential, :post, path <> "/commit", body) |> json_response(200)
    assert result["revision"] == 1

    view =
      call("Bearer " <> ctx.raw, :get, base(ctx) <> "/sessions/#{created["id"]}/application")
      |> json_response(200)

    assert view["context"] == %{"audience" => "students"}

    assert call(
             "Bearer " <> ctx.other,
             :get,
             base(ctx) <> "/sessions/#{created["id"]}/application"
           ).status == 404

    assert call(
             "Host " <> ctx.credential,
             :post,
             base(ctx) <> "/sessions/#{created["id"]}/turns",
             %{query: "host forgery"}
           ).status == 401

    assert {:error, :personal_chat_runtime_unavailable} = StudioChat.runtime_access(created["id"])
  end

  test "personal draft remains editable but cannot seed application context or commit history",
       ctx do
    created = create(ctx)
    path = base(ctx) <> "/sessions/#{created["id"]}"

    assert call("Bearer " <> ctx.raw, :patch, path, %{draft: "reader-authored draft"}).status ==
             200

    assert call("Bearer " <> ctx.raw, :patch, path, %{
             application_state: %{context: %{forged: true}}
           }).status == 400

    for field <- ~w(messages context selection source_identities provider host_id) do
      assert call(
               "Bearer " <> ctx.raw,
               :post,
               path <> "/turns",
               Map.put(
                 %{"query" => "Question", "request_id" => "x", "expected_revision" => 0},
                 field,
                 %{}
               )
             ).status == 400
    end

    assert Repo.get!(Barkpark.StudioChat.Session, created["id"]).application_state["context"] ==
             %{}

    assert StudioChat.list_messages(created["id"], {:personal, ctx.ws.id, ctx.user.id}) == []
  end

  test "unconfigured binding and revoked login cannot create or execute work", ctx do
    created = create(ctx)
    turn = accept(ctx, created["id"])
    Accounts.revoke_user_session_token(ctx.raw)

    assert call("Host " <> ctx.credential, :get, "/v1/chat-host/application-turns/#{turn["id"]}").status ==
             401

    assert call("Bearer " <> ctx.raw, :get, base(ctx) <> "/sessions/#{created["id"]}/application").status ==
             401

    Application.delete_env(:barkpark, :personal_chat_applications)

    assert call("Bearer " <> ctx.other, :post, base(ctx) <> "/applications/fixture/sessions").status ==
             503
  end
end
