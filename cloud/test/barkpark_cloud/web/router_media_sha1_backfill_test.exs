defmodule BarkparkCloud.Web.RouterMediaSha1BackfillTest.FakeBox do
  @moduledoc """
  A box that answers `POST /v1/admin/media/sha1-backfill` with a reply the
  test sets, and records each request it gets.
  """

  def start(reply),
    do: Agent.start_link(fn -> %{reply: reply, requests: []} end, name: __MODULE__)

  def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

  def request(%{method: method, url: url, headers: headers} = req) do
    bearer =
      Enum.find_value(headers, fn {k, v} ->
        if String.downcase(k) == "authorization", do: String.replace_prefix(v, "Bearer ", "")
      end)

    entry = %{
      method: method,
      path: URI.parse(url).path,
      bearer: bearer,
      body: Jason.decode!(req[:body] || "{}")
    }

    Agent.get_and_update(__MODULE__, fn s ->
      {status, body} = s.reply
      {{:ok, %{status: status, body: Jason.encode!(body)}}, %{s | requests: [entry | s.requests]}}
    end)
  end
end

defmodule BarkparkCloud.Web.RouterMediaSha1BackfillTest do
  @moduledoc """
  `POST /v1/operator/barkparks/:id/media-sha1-backfill` through the real
  router: Cloud forwards the request to the box with the admin token it holds,
  passes the box's reply back, maps refusals, and writes an audit row only for
  an applied page that touched a file. Only a platform operator reaches it.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Accounts.AuditEvent
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Web.Router
  alias __MODULE__.FakeBox

  @opts Router.init([])
  @password "correct-horse-battery"
  @held "held-admin-secret"

  @plan %{
    "applied" => false,
    "unhashed" => 3,
    "datasets" => [%{"workspace" => "ws-a", "dataset" => "production", "unhashed" => 3}]
  }

  @page %{
    "applied" => true,
    "hashed" => 2,
    "failed" => [
      %{
        "id" => "f-1",
        "workspace" => "ws-a",
        "dataset" => "production",
        "reason" => "blob_not_found"
      }
    ],
    "next_after" => nil,
    "unhashed" => 1
  }

  setup do
    prior_client = Application.get_env(:barkpark_cloud, :studio_link_http_client)
    prior_ops = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    Application.put_env(:barkpark_cloud, :studio_link_http_client, FakeBox)

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, :studio_link_http_client, prior_client)
      Application.put_env(:barkpark_cloud, :platform_admin_emails, prior_ops)
    end)

    :ok
  end

  defp session(operator?) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    if operator?, do: Application.put_env(:barkpark_cloud, :platform_admin_emails, [user.email])
    {:ok, token} = Accounts.create_user_session_token(user)
    {team, token}
  end

  defp box(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: "https://box-#{n}.example.test",
      admin_token_encrypted: Vault.encrypt(@held)
    )
    |> Repo.update!()
    |> BarkparkCloud.UrlClaimFixtures.claim_url_host!()
  end

  defp backfill(id, token, body) do
    conn(:post, "/v1/operator/barkparks/#{id}/media-sha1-backfill", Jason.encode!(body))
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp audit_row(bp),
    do: Repo.get_by(AuditEvent, target_id: bp.id, action: "barkpark.media_sha1_backfilled")

  test "a dry run forwards to the box with the held token and writes no audit row" do
    {:ok, _} = FakeBox.start({200, @plan})
    {team, token} = session(true)
    bp = box(team)

    conn = backfill(bp.id, token, %{})
    assert conn.status == 200, conn.resp_body
    refute conn.resp_body =~ @held

    assert %{"ok" => true, "barkpark_id" => id, "backfill" => reply} =
             Jason.decode!(conn.resp_body)

    assert id == bp.id
    assert reply == @plan

    assert [req] = FakeBox.requests()
    assert req.method == :post
    assert req.path == "/v1/admin/media/sha1-backfill"
    assert req.bearer == @held
    assert req.body == %{"apply" => false}
    refute audit_row(bp)
  end

  test "an applied page forwards the cursor and limit and writes an audit row" do
    {:ok, _} = FakeBox.start({200, @page})
    {team, token} = session(true)
    bp = box(team)

    conn = backfill(bp.id, token, %{apply: true, after: "f-0", limit: 100})
    assert conn.status == 200, conn.resp_body
    assert Jason.decode!(conn.resp_body)["backfill"] == @page

    assert [req] = FakeBox.requests()
    assert req.body == %{"apply" => true, "after" => "f-0", "limit" => 100}

    assert %AuditEvent{metadata: meta} = audit_row(bp)
    assert meta["hashed"] == 2
    assert meta["failed"] == 1
    assert meta["unhashed"] == 1
  end

  test "an applied page that touched nothing writes no audit row" do
    {:ok, _} =
      FakeBox.start(
        {200,
         %{"applied" => true, "hashed" => 0, "failed" => [], "next_after" => nil, "unhashed" => 0}}
      )

    {team, token} = session(true)
    bp = box(team)

    assert backfill(bp.id, token, %{apply: true}).status == 200
    refute audit_row(bp)
  end

  test "box refusals map to Cloud codes" do
    {team, token} = session(true)
    bp = box(team)

    for {reply, status, code} <- [
          {{404, %{}}, 409, "box_too_old"},
          {{403, %{"error" => %{"code" => "forbidden"}}}, 502, "not_box_admin"},
          {{422, %{"error" => %{"code" => "unprocessable", "message" => "bad"}}}, 502,
           "backfill_refused"}
        ] do
      if pid = Process.whereis(FakeBox), do: Agent.stop(pid)
      {:ok, _} = FakeBox.start(reply)
      conn = backfill(bp.id, token, %{apply: true})
      assert conn.status == status, conn.resp_body
      assert Jason.decode!(conn.resp_body)["error"] == code
    end

    refute audit_row(bp)
  end

  test "bad input is 422 and makes no box call" do
    {:ok, _} = FakeBox.start({200, @plan})
    {team, token} = session(true)
    bp = box(team)

    for body <- [%{apply: "yes"}, %{after: 7}, %{limit: 0}, %{limit: 501}] do
      assert backfill(bp.id, token, body).status == 422
    end

    assert FakeBox.requests() == []
  end

  test "a non-operator is refused and an unknown barkpark is 404" do
    {:ok, _} = FakeBox.start({200, @plan})
    {team, token} = session(false)
    bp = box(team)
    assert backfill(bp.id, token, %{}).status in [401, 403]
    assert FakeBox.requests() == []

    {_team, op} = session(true)
    assert backfill(Ecto.UUID.generate(), op, %{}).status == 404
  end
end
