defmodule BarkparkWeb.Integration.SessionBearerStreamsTest do
  @moduledoc """
  task-cc6ad07a8aa36338 — the scoped editor streams take a member's login
  session as the bearer, as the rest of the scoped data API has since #22764.

  `GET /w/:ws/p/:proj/v1/data/listen` and `.../presence` (and presence's
  `focus`) sat behind `:require_token` (API tokens only), so a signed-in
  editor's studio got 401 on both while its reads and writes worked: no
  presence, no live updates. Every session here comes from the real
  `POST /v1/auth/login`.

  Streams run inside a `Task`; `:sse_overloaded` ends the loop and hands back
  the body, as in `presence_api_test.exs`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Accounts.UserSession
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.PresenceState

  @password "correct horse battery staple"
  @ds "production"

  setup do
    ensure_default_scope!()
    ws = create_workspace!("cc6-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "cc6-p-#{System.unique_integer([:positive])}")

    raw = "cc6-token-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "cc6-token", @ds, ["read", "write"], ws.id)

    member = user!("member")
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "user")
    other_member = user!("other")
    {:ok, _} = TenancyAuth.create_membership(ws.id, other_member.id, "member", "user")
    outsider = user!("outsider")

    base = "/w/#{ws.slug}/p/#{proj.slug}/v1/data"

    %{
      ws: ws,
      proj: proj,
      token: raw,
      member: member,
      session: login!(member.email),
      other_session: login!(other_member.email),
      outsider_session: login!(outsider.email),
      listen: "#{base}/listen/#{@ds}",
      presence: "#{base}/presence/#{@ds}",
      topic: PresenceState.topic(ws.id, proj.id, @ds)
    }
  end

  defp user!(tag) do
    email = "cc6-#{tag}-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    Accounts.confirm_provisioned_user(user)
    user
  end

  defp login!(email) do
    scoped_conn()
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/login", Jason.encode!(%{email: email, password: @password}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  defp bearer(raw), do: put_req_header(scoped_conn(), "authorization", "Bearer " <> raw)

  # A refusal answers at once; a stream is held open until told to end.
  defp request(conn, path, params \\ %{}) do
    task = Task.async(fn -> get(conn, path, params) end)

    case Task.yield(task, 300) do
      {:ok, resp} ->
        resp

      nil ->
        send(task.pid, :sse_overloaded)
        Task.await(task, 10_000)
    end
  end

  defp wait_for(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(20) && wait_for(fun, tries - 1)
    end
  end

  describe "a member's login session as the bearer" do
    test "listen streams", ctx do
      resp = request(bearer(ctx.session), ctx.listen)
      assert resp.status == 200, resp.resp_body
    end

    test "presence streams, and the room names the user", ctx do
      task =
        Task.async(fn ->
          get(bearer(ctx.session), ctx.presence, %{"sessionId" => "cc6-a"})
        end)

      wait_for(fn -> Presence.get_by_key(ctx.topic, "api:cc6-a") != [] end)
      assert %{metas: [%{name: name}]} = Presence.get_by_key(ctx.topic, "api:cc6-a")
      assert name == ctx.member.email

      focus =
        bearer(ctx.session)
        |> put_req_header("content-type", "application/json")
        |> post(ctx.presence <> "/focus", Jason.encode!(%{sessionId: "cc6-a", field: "title"}))

      assert focus.status == 200, focus.resp_body

      # Another member's session cannot steer this one's presence.
      steer =
        bearer(ctx.other_session)
        |> put_req_header("content-type", "application/json")
        |> post(ctx.presence <> "/focus", Jason.encode!(%{sessionId: "cc6-a", field: "body"}))

      assert steer.status == 404, steer.resp_body

      send(task.pid, :sse_overloaded)
      assert Task.await(task, 10_000).status == 200
    end

    test "a session revoked mid-stream ends listen with unauthorized", ctx do
      previous = Application.get_env(:barkpark, :listen_reauth_interval_ms)
      Application.put_env(:barkpark, :listen_reauth_interval_ms, 0)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:barkpark, :listen_reauth_interval_ms, previous),
          else: Application.delete_env(:barkpark, :listen_reauth_interval_ms)
      end)

      # A real live event, as the stream receives one.
      Phoenix.PubSub.subscribe(Barkpark.PubSub, "documents:ws:#{ctx.ws.id}:#{@ds}")
      {:ok, doc} = create_document_in!(ctx.ws, ctx.proj, "memo", %{"title" => "CC6-AFTER"}, @ds)

      msg =
        receive do
          {:document_changed, %{doc_id: id} = m} when id == doc.doc_id -> m
        after
          2_000 -> flunk("no broadcast for the fixture document")
        end

      task = Task.async(fn -> get(bearer(ctx.session), ctx.listen) end)
      Process.sleep(200)
      bearer(ctx.session) |> delete("/v1/auth/logout")
      send(task.pid, {:document_changed, msg})
      send(task.pid, :sse_overloaded)
      body = Task.await(task, 10_000).resp_body
      assert body =~ "event: unauthorized"
      refute body =~ "CC6-AFTER"
    end
  end

  describe "refused" do
    test "a non-member's session is 403 on both streams", ctx do
      assert request(bearer(ctx.outsider_session), ctx.listen).status == 403

      assert request(bearer(ctx.outsider_session), ctx.presence, %{"sessionId" => "cc6-x"}).status ==
               403
    end

    test "a revoked session is 401", ctx do
      bearer(ctx.session) |> delete("/v1/auth/logout")
      assert request(bearer(ctx.session), ctx.listen).status == 401
      assert request(bearer(ctx.session), ctx.presence).status == 401
    end

    test "an expired session is 401", ctx do
      hash = UserSession.hash_token(ctx.session)
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      Repo.update_all(from(s in UserSession, where: s.token_hash == ^hash),
        set: [expires_at: past]
      )

      assert request(bearer(ctx.session), ctx.listen).status == 401
      assert request(bearer(ctx.session), ctx.presence).status == 401
    end

    test "a session in the cookie only (no bearer) does not open them", ctx do
      conn = Plug.Test.init_test_session(scoped_conn(), %{"user_session" => ctx.session})
      assert request(conn, ctx.listen).status in [401, 403]
    end

    test "the flat listen stays API-token only", ctx do
      assert request(bearer(ctx.session), "/v1/data/listen/#{@ds}").status == 401
    end
  end

  describe "an API token (control)" do
    test "streams listen and presence as before", ctx do
      assert request(bearer(ctx.token), ctx.listen).status == 200
      assert request(bearer(ctx.token), ctx.presence, %{"sessionId" => "cc6-t"}).status == 200
    end

    test "the flat listen still streams for a token", ctx do
      assert request(bearer(ctx.token), "/v1/data/listen/#{@ds}").status == 200
    end
  end
end
