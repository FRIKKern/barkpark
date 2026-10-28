defmodule BarkparkCloud.Web.RouterAdminTokenRotateTest.FakeBox do
  @moduledoc """
  A box with a token table, for `:studio_link_http_client`. It answers by
  bearer: a live token reads admin, a revoked or unknown one gets 401. The
  mint and revoke routes change the table, so the test can ask the box what
  the old token gets after a rotation. `fail/1` makes one route answer 500;
  `{:revoke, id}` fails the revoke of that one id.

  Seats follow the box's rule: a minted token is seated only in the mint's
  workspace, and a revoke needs an actor seated in every workspace the target
  is seated in (403 otherwise).
  """

  def start(tokens, seats),
    do:
      Agent.start_link(fn -> %{live: tokens, seats: seats, n: 0, fail: nil} end,
        name: __MODULE__
      )

  def fail(route), do: Agent.update(__MODULE__, &%{&1 | fail: route})
  def live?(token), do: Agent.get(__MODULE__, &Map.has_key?(&1.live, token))

  def request(%{method: method, url: url, headers: headers}) do
    bearer =
      Enum.find_value(headers, fn {k, v} ->
        if String.downcase(k) == "authorization", do: String.replace_prefix(v, "Bearer ", "")
      end)

    Agent.get_and_update(__MODULE__, fn s ->
      handle(s, route(method, URI.parse(url).path), bearer)
    end)
  end

  defp handle(%{live: live} = s, route, bearer) do
    cond do
      # As on a real box: capabilities answers any bearer, a dead one as public.
      route == :capabilities and not Map.has_key?(live, bearer) ->
        {reply(200, %{auth_tier: "public"}), s}

      not Map.has_key?(live, bearer) ->
        {reply(401, %{error: "unauthorized"}), s}

      s.fail == route ->
        {reply(500, %{error: "boom"}), s}

      true ->
        act(s, route, bearer)
    end
  end

  defp route(:get, "/v1/capabilities"), do: :capabilities
  defp route(:get, "/v1/tokens/current"), do: :current
  defp route(:post, "/w/acme/p/default/v1/tokens/elevated"), do: :mint
  defp route(:delete, "/w/acme/p/default/v1/tokens/" <> id), do: {:revoke, id}
  defp route(_, _), do: :other

  defp act(s, :capabilities, _bearer), do: {reply(200, %{auth_tier: "admin"}), s}

  defp act(s, :current, bearer),
    do:
      {reply(200, %{
         token: %{id: s.live[bearer], workspace: "acme"},
         memberships:
           for(
             ws <- Map.get(s.seats, s.live[bearer], []),
             do: %{workspace_slug: ws, role: "admin"}
           )
       }), s}

  defp act(s, :mint, _bearer) do
    n = s.n + 1
    raw = "successor-secret-#{n}"
    id = "tok-successor-#{n}"

    {reply(201, %{token: raw, id: id}),
     %{s | n: n, live: Map.put(s.live, raw, id), seats: Map.put(s.seats, id, ["acme"])}}
  end

  defp act(s, {:revoke, id}, bearer) do
    if Map.get(s.seats, id, []) -- Map.get(s.seats, s.live[bearer], []) == [] do
      live = s.live |> Enum.reject(fn {_raw, tid} -> tid == id end) |> Map.new()
      {reply(200, %{revoked: %{id: id}}), %{s | live: live}}
    else
      {reply(403, %{error: %{code: "forbidden"}}), s}
    end
  end

  defp act(s, _, _bearer), do: {reply(404, %{}), s}

  defp reply(status, map), do: {:ok, %{status: status, body: Jason.encode!(map)}}
end

defmodule BarkparkCloud.Web.RouterAdminTokenRotateTest.NotAdminSuccessor do
  @moduledoc "FakeBox, except a minted successor reads as a member on /v1/capabilities."
  alias BarkparkCloud.Web.RouterAdminTokenRotateTest.FakeBox

  def request(%{method: :get, url: url, headers: headers} = req) do
    successor? =
      Enum.any?(headers, fn {k, v} ->
        String.downcase(k) == "authorization" and String.contains?(v, "successor-secret")
      end)

    if URI.parse(url).path == "/v1/capabilities" and successor?,
      do: {:ok, %{status: 200, body: Jason.encode!(%{auth_tier: "member"})}},
      else: FakeBox.request(req)
  end

  def request(req), do: FakeBox.request(req)
end

defmodule BarkparkCloud.Web.RouterAdminTokenRotateTest do
  @moduledoc """
  `POST /v1/operator/barkparks/:id/admin-token/rotate` against a fake box that
  keeps a token table (`FakeBox` above), through the real router:

    * success: the successor is stored, the old token gets 401 from the box,
      the response carries ids and no secret, an audit row lands
    * a failure before the revoke completes (the mint, the successor's check,
      the revoke itself) leaves the old token stored and working, and no
      successor live
    * only a platform operator reaches it
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
  @old "held-admin-secret"
  @old_id "tok-held-1"

  setup do
    prior_client = Application.get_env(:barkpark_cloud, :studio_link_http_client)
    prior_ops = Application.get_env(:barkpark_cloud, :platform_admin_emails, [])
    Application.put_env(:barkpark_cloud, :studio_link_http_client, FakeBox)

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, :studio_link_http_client, prior_client)
      Application.put_env(:barkpark_cloud, :platform_admin_emails, prior_ops)
    end)

    # The held token is seated in two workspaces, as gyl's is: only the old
    # token itself administers both, so only it can revoke itself.
    {:ok, _} = FakeBox.start(%{@old => @old_id}, %{@old_id => ["acme", "other"]})
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
      admin_token_encrypted: Vault.encrypt(@old)
    )
    |> Repo.update!()
    |> BarkparkCloud.UrlClaimFixtures.claim_url_host!()
  end

  defp rotate(id, token) do
    conn(:post, "/v1/operator/barkparks/#{id}/admin-token/rotate", "")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp stored(bp), do: Registry.reveal_admin_token(Registry.get_barkpark(bp.id))

  defp assert_old_kept(bp, conn, code) do
    assert Jason.decode!(conn.resp_body)["error"] == code, conn.resp_body
    assert stored(bp) == {:ok, @old}
    assert FakeBox.live?(@old)
    refute FakeBox.live?("successor-secret-1")
    refute Repo.get_by(AuditEvent, target_id: bp.id, action: "barkpark.admin_token_rotated")
  end

  test "success: the successor is stored and the old token gets 401" do
    {team, token} = session(true)
    bp = box(team)

    conn = rotate(bp.id, token)
    assert conn.status == 200, conn.resp_body
    refute conn.resp_body =~ @old
    refute conn.resp_body =~ "successor-secret"

    assert %{
             "ok" => true,
             "rotated" => %{
               "old_token_id" => @old_id,
               "new_token_id" => "tok-successor-1",
               "label" => "barkpark cloud admin",
               "workspace" => "acme",
               "seats_not_carried" => ["other"],
               "old_token_status" => 401
             }
           } = Jason.decode!(conn.resp_body)

    assert stored(bp) == {:ok, "successor-secret-1"}
    refute FakeBox.live?(@old)
    assert FakeBox.live?("successor-secret-1")

    audit = Repo.get_by!(AuditEvent, target_id: bp.id, action: "barkpark.admin_token_rotated")
    assert audit.team_id == team.id
    assert audit.metadata["old_token_id"] == @old_id
    assert audit.metadata["new_token_id"] == "tok-successor-1"
    refute inspect(audit.metadata) =~ "secret"
  end

  test "a refused mint keeps the old token stored and working" do
    {team, token} = session(true)
    bp = box(team)
    FakeBox.fail(:mint)

    assert_old_kept(bp, rotate(bp.id, token), "mint_refused")
  end

  test "a successor that does not read admin is revoked and the old token kept" do
    {team, token} = session(true)
    bp = box(team)
    Application.put_env(:barkpark_cloud, :studio_link_http_client, __MODULE__.NotAdminSuccessor)

    assert_old_kept(bp, rotate(bp.id, token), "minted_token_not_admin")
  end

  test "a refused revoke puts the old token back and revokes the successor" do
    {team, token} = session(true)
    bp = box(team)
    FakeBox.fail({:revoke, @old_id})

    assert_old_kept(bp, rotate(bp.id, token), "revoke_refused")
  end

  test "a team owner who is not an operator is refused and nothing changes" do
    {team, token} = session(false)
    bp = box(team)

    conn = rotate(bp.id, token)
    assert conn.status == 403
    assert stored(bp) == {:ok, @old}
    assert FakeBox.live?(@old)
  end

  test "an unknown id is a 404" do
    {_team, token} = session(true)
    assert rotate(Ecto.UUID.generate(), token).status == 404
  end
end
