defmodule BarkparkCloud.Web.RouterTokenSeatRestoreTest.FakeBox do
  @moduledoc """
  A box that answers `POST /v1/admin/tokens/:id/seats/restore` with a reply
  the test sets, and records each request it gets.
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

defmodule BarkparkCloud.Web.RouterTokenSeatRestoreTest do
  @moduledoc """
  `POST /v1/operator/barkparks/:id/token-seats/restore` (task-c6185553d0bd7869)
  through the real router: Cloud forwards the request to the box with the
  admin token it holds, passes the box's plan back, maps refusals, and writes
  an audit row only for an applied restore. Only a platform operator reaches
  it.
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
    "token_id" => "tok-new",
    "predecessors" => ["tok-old"],
    "restore" => [%{"workspace" => "ws-a", "role" => "admin", "from_token" => "tok-old"}],
    "already" => ["default"],
    "refused" => [],
    "applied" => false
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

  defp restore(id, token, body) do
    conn(:post, "/v1/operator/barkparks/#{id}/token-seats/restore", Jason.encode!(body))
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp audit_row(bp),
    do: Repo.get_by(AuditEvent, target_id: bp.id, action: "barkpark.token_seats_restored")

  test "a dry run forwards to the box with the held token and writes no audit row" do
    {:ok, _} = FakeBox.start({200, @plan})
    {team, token} = session(true)
    bp = box(team)

    conn = restore(bp.id, token, %{workspaces: ["ws-a"]})
    assert conn.status == 200, conn.resp_body
    refute conn.resp_body =~ @held

    assert %{"ok" => true, "barkpark_id" => id, "restore" => plan} = Jason.decode!(conn.resp_body)
    assert id == bp.id
    assert plan == @plan

    assert [req] = FakeBox.requests()
    assert req.method == :post
    assert req.path == "/v1/admin/tokens/current/seats/restore"
    assert req.bearer == @held
    assert req.body == %{"workspaces" => ["ws-a"], "apply" => false}
    refute audit_row(bp)
  end

  test "an applied restore names the token and writes an audit row" do
    {:ok, _} = FakeBox.start({200, %{@plan | "applied" => true}})
    {team, token} = session(true)
    bp = box(team)

    conn = restore(bp.id, token, %{token: "tok-new", workspaces: ["ws-a"], apply: true})
    assert conn.status == 200, conn.resp_body

    assert [req] = FakeBox.requests()
    assert req.path == "/v1/admin/tokens/tok-new/seats/restore"
    assert req.body["apply"] == true

    row = audit_row(bp)
    assert row.metadata["token_id"] == "tok-new"
    assert row.metadata["predecessors"] == ["tok-old"]
    refute inspect(row.metadata) =~ @held
  end

  test "a seat no predecessor held comes back 409 with the box's plan" do
    refused = %{
      @plan
      | "restore" => [],
        "refused" => [%{"workspace" => "ws-x", "reason" => "not_held_before"}]
    }

    {:ok, _} =
      FakeBox.start(
        {409,
         %{
           error: %{
             code: "conflict",
             reason: "not_held_before",
             message: "no",
             details: refused
           }
         }}
      )

    {team, token} = session(true)
    bp = box(team)

    conn = restore(bp.id, token, %{workspaces: ["ws-x"], apply: true})
    assert conn.status == 409
    body = Jason.decode!(conn.resp_body)
    assert body["error"] == "seat_not_held_before"
    assert body["restore"]["refused"] == refused["refused"]
    refute audit_row(bp)
  end

  test "box refusals map to Cloud codes" do
    {team, token} = session(true)
    bp = box(team)

    cases = [
      {{404, %{error: %{code: "not_found"}}}, 409, "box_too_old"},
      {{404, %{error: %{code: "not_found", reason: "token_not_found"}}}, 404, "token_not_found"},
      {{409, %{error: %{code: "conflict", reason: "token_not_live"}}}, 409, "token_not_live"},
      {{403, %{error: %{code: "forbidden", required: "platform_operator"}}}, 502,
       "not_box_admin"},
      {{401, %{error: "unauthorized"}}, 502, "not_box_admin"},
      {{500, %{error: %{code: "boom"}}}, 502, "restore_refused"}
    ]

    for {reply, status, code} <- cases do
      if pid = Process.whereis(FakeBox), do: Agent.stop(pid)
      {:ok, _} = FakeBox.start(reply)
      conn = restore(bp.id, token, %{})
      assert conn.status == status, "#{inspect(reply)}: #{conn.resp_body}"
      assert Jason.decode!(conn.resp_body)["error"] == code
    end
  end

  test "bad input is refused before any box call" do
    {:ok, _} = FakeBox.start({200, @plan})
    {team, token} = session(true)
    bp = box(team)

    assert restore(bp.id, token, %{workspaces: "ws-a"}).status == 422
    assert restore(bp.id, token, %{apply: "yes"}).status == 422
    assert restore(bp.id, token, %{token: 7}).status == 422
    assert FakeBox.requests() == []
  end

  test "only a platform operator reaches it" do
    {:ok, _} = FakeBox.start({200, @plan})
    {team, token} = session(false)
    bp = box(team)

    conn = restore(bp.id, token, %{workspaces: ["ws-a"], apply: true})
    assert conn.status == 403
    assert FakeBox.requests() == []
  end

  test "an unknown barkpark is 404" do
    {:ok, _} = FakeBox.start({200, @plan})
    {_team, token} = session(true)
    assert restore(Ecto.UUID.generate(), token, %{}).status == 404
  end
end
