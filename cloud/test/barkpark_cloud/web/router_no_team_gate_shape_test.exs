defmodule BarkparkCloud.Web.RouterNoTeamGateShapeTest do
  @moduledoc """
  DRIVEN reachability for every inline no_team emitter in `router.ex`
  (cch-w40-bl). The row that ordered this conversion derived reachability from
  the SHAPE of each route (a `require_*` gate followed by a `cond` whose second
  arm tests `is_nil(current_team)`) and never drove one. Shape-derivation cannot
  tell a live arm from dead belt-and-braces: five of the fourteen literals sit
  behind a gate that ALREADY halts a teamless caller, so their arm can never be
  entered, and a conversion that treated all fourteen alike would have "fixed"
  five refusals no client can ever receive.

  So this suite drives each one with a real teamless session (or, for
  `GET /v1/events`, a real single-use SSE ticket) and asserts the wire answer:

    * NINE REACHABLE sites now answer the SHARED gate shape —
      `403 {"error":"forbidden","reason":"no_team","scope":"team"}` — the exact
      body `Auth.forbidden(conn, reason: "no_team", scope: "team")` emits from
      `gate_role/4` (auth.ex) and from `require_current_team_owner/1`. Before
      this suite's own commit they answered `422 {"error":"no_team"}`; the
      status flip is safe because the CLI half landed first (cch-w40-s4, PR
      #11711 — `cloud_rollback_cmd.go` and `cloud_update_cmd.go` read the CAUSE,
      `reason == "no_team" or code == "no_team"`, not the status).

    * FIVE DEAD sites are proven dead: the gate answers 403 no_team ITSELF, one
      clause before the inline arm could run, so the inline arms were deleted
      rather than converted. `POST /v1/providers`,
      `POST /v1/github/installations` and `POST /v1/github/repos` are gated by
      `Auth.require_team_admin/2 -> gate_role/4`; `POST /v1/billing/checkout`
      and `POST /v1/billing/portal` by `Auth.require_current_team_owner/1`.

  Every assertion is on the FULL decoded body, so a partial convergence (right
  status, missing `scope`) cannot pass.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  @gate_shape %{"error" => "forbidden", "reason" => "no_team", "scope" => "team"}

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "no-team-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  # A registered user with NO team membership at all, plus a live session token.
  defp teamless_session do
    user = user_fixture()
    {:ok, session} = Accounts.create_user_session_token(user)
    {user, session}
  end

  defp call(method, path, body \\ nil, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          method
          |> conn(path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp decode(conn), do: Jason.decode!(conn.resp_body)

  # One assertion helper so a site that drifts to a NEAR-miss (403 with no
  # `scope`, or 403 `{error: "no_team"}` flat) fails as loudly as a 422 would.
  defp assert_gate_shape(conn, where) do
    assert conn.status == 403, "#{where}: expected 403, got #{conn.status}: #{conn.resp_body}"
    assert decode(conn) == @gate_shape, "#{where}: body diverges from the gate shape"
  end

  describe "reachable inline emitters converge on the gate shape" do
    test "GET /v1/events (require_user_sse, ?ticket=)" do
      user = user_fixture()
      {:ok, ticket} = Accounts.create_sse_ticket(user)

      :get
      |> call("/v1/events?ticket=#{ticket}")
      |> assert_gate_shape("GET /v1/events")
    end

    test "POST /v1/fleet/supports (require_user_or_pat + inline team-admin cond)" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/fleet/supports", %{name: "support-1"}, session)
      |> assert_gate_shape("POST /v1/fleet/supports")
    end

    test "POST /v1/barkparks/:id/agent-key (require_user_or_pat + inline team-admin cond)" do
      {_u, session} = teamless_session()

      # The team arm precedes the id lookup, so any well-formed id reaches it.
      :post
      |> call(
        "/v1/barkparks/#{Ecto.UUID.generate()}/agent-key",
        %{key: String.duplicate("k", 24)},
        session
      )
      |> assert_gate_shape("POST /v1/barkparks/:id/agent-key")
    end

    test "GET /v1/deploy-ledger/census (require_user_or_pat + require_ability(\"read\"))" do
      {_u, session} = teamless_session()

      :get
      |> call("/v1/deploy-ledger/census", nil, session)
      |> assert_gate_shape("GET /v1/deploy-ledger/census")
    end

    test "GET /v1/notifications/settings (require_user)" do
      {_u, session} = teamless_session()

      :get
      |> call("/v1/notifications/settings", nil, session)
      |> assert_gate_shape("GET /v1/notifications/settings")
    end

    test "POST /v1/tokens (require_user)" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/tokens", %{name: "ci-key"}, session)
      |> assert_gate_shape("POST /v1/tokens")
    end

    test "POST /v1/sites (require_user)" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/sites", %{barkpark_id: Ecto.UUID.generate(), name: "site-1"}, session)
      |> assert_gate_shape("POST /v1/sites")
    end

    test "POST /v1/go-live (require_user_or_pat + inline team-admin cond)" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/go-live", %{name: "box-1"}, session)
      |> assert_gate_shape("POST /v1/go-live")
    end

    test "POST /v1/launch shares go_live/1's emitter" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/launch", %{name: "box-1"}, session)
      |> assert_gate_shape("POST /v1/launch")
    end

    test "POST /v1/resurrect (require_user)" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/resurrect", %{name: "box-1"}, session)
      |> assert_gate_shape("POST /v1/resurrect")
    end
  end

  describe "the deleted inline emitters were dead — the gate answers first" do
    test "POST /v1/providers is answered by require_team_admin -> gate_role" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/providers", %{kind: "hetzner", token: "t"}, session)
      |> assert_gate_shape("POST /v1/providers")
    end

    test "POST /v1/github/installations is answered by require_team_admin -> gate_role" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/github/installations", %{installation_id: 1}, session)
      |> assert_gate_shape("POST /v1/github/installations")
    end

    test "POST /v1/github/repos is answered by require_team_admin -> gate_role" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/github/repos", %{name: "r", template: "t"}, session)
      |> assert_gate_shape("POST /v1/github/repos")
    end

    test "POST /v1/billing/checkout is answered by require_current_team_owner" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/billing/checkout", %{plan: "pro"}, session)
      |> assert_gate_shape("POST /v1/billing/checkout")
    end

    test "POST /v1/billing/portal is answered by require_current_team_owner" do
      {_u, session} = teamless_session()

      :post
      |> call("/v1/billing/portal", %{}, session)
      |> assert_gate_shape("POST /v1/billing/portal")
    end
  end
end
