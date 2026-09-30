defmodule BarkparkCloud.Web.RouterInternalPerimeterTest do
  @moduledoc """
  dr-w24-bl-internal-write-route-is-publicly-reachable — the SECOND FACTOR in
  front of the `/v1/internal/*` fleet-ops surface.

  MEASURED on prod (the row): an unauthenticated POST from a laptop to
  `https://barkpark.cloud/v1/internal/platform-deliveries` answered **401, not
  404**. The family is reachable from the open internet and the shared
  `WORKER_TOKEN` is the only thing between it and the delivery record — a
  single-secret perimeter with no second factor.

  `:fence_internal_surface` adds the NETWORK factor in the app: a caller whose
  resolved client IP is outside `:internal_allowed_cidrs` gets a 404, decided
  BEFORE any token compare, so an off-net scanner learns neither that the route
  exists nor whether its bearer was right.

  §1 pins the UNCONFIGURED case: the fence fails CLOSED. A deleted key 404s the
  family rather than waving it through, and the ONLY thing that reopens it is the
  NAMED opt-out `:any` (what dev/test ship, so nothing local changes). The
  prod-must-declare half is pinned in `internal_perimeter_test.exs`.

  §2 is the mutation-visible core: with the list armed, an on-net caller with the
  worker token still gets through and an off-net caller with the SAME VALID TOKEN
  gets 404. Delete the `plug(:fence_internal_surface)` line and §2's off-net
  assertions red (they see 200/401, the pre-fix behaviour).

  §3 proves the fence is a PREDICATE, not an enumeration: it is derived by
  grepping every `/v1/internal/*` match clause out of router.ex and asserting the
  fence covers all of them. A route added tomorrow is covered with nothing to
  update — and if someone narrows the fence to a list, this reds.

  §4 pins the matcher itself (prefix arithmetic, v4/v6 family separation,
  malformed remote_ip) and §5 pins that a NON-internal path is untouched while
  the fence is armed.

  `async: false` — `:internal_allowed_cidrs` is process-global Application
  config.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  @router_source Path.join([
                   __DIR__,
                   "..",
                   "..",
                   "..",
                   "lib",
                   "barkpark_cloud",
                   "web",
                   "router.ex"
                 ])
                 |> Path.expand()

  # An on-net range and an address inside it; an address deliberately outside.
  @allowed [{{203, 0, 113, 0}, 24}]
  @on_net {203, 0, 113, 7}
  @off_net {198, 51, 100, 9}

  # The one route the filing NAMES. The full family is DERIVED in §3.
  @filed_route {"POST", "/v1/internal/platform-deliveries"}

  setup do
    prior_cidrs = Application.get_env(:barkpark_cloud, :internal_allowed_cidrs)
    prior_worker = Application.get_env(:barkpark_cloud, :worker_token)

    on_exit(fn ->
      restore(:internal_allowed_cidrs, prior_cidrs)
      restore(:worker_token, prior_worker)
    end)

    Application.put_env(:barkpark_cloud, :worker_token, "worker-secret-for-perimeter-test")
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark_cloud, key)
  defp restore(key, value), do: Application.put_env(:barkpark_cloud, key, value)

  defp call(method, path, from_ip, opts \\ []) do
    conn =
      conn(method, path, opts[:body] || "")
      |> Map.put(:remote_ip, from_ip)
      |> put_req_header("content-type", "application/json")

    conn =
      case opts[:bearer] do
        nil -> conn
        token -> put_req_header(conn, "authorization", "Bearer " <> token)
      end

    Router.call(conn, @opts)
  end

  defp worker, do: Application.get_env(:barkpark_cloud, :worker_token)

  # Every `/v1/internal/*` match clause declared in router.ex, DERIVED from the
  # source. A snapshot list here would go stale the next time a route is added —
  # exactly the failure this fence is shaped to avoid.
  defp declared_internal_routes do
    Regex.scan(
      ~r/^\s{2}(get|post|put|patch|delete)\s+"(\/v1\/internal\/[^"]*)"/m,
      File.read!(@router_source)
    )
    |> Enum.map(fn [_, verb, path] -> {String.upcase(verb), path} end)
    |> Enum.uniq()
  end

  # `:id` / `:name` segments cannot be sent as literals; substitute something
  # syntactically valid. The fence runs before :match, so the value is irrelevant
  # to what is being proved — only the path PREFIX matters.
  defp concretize(path) do
    path
    |> String.split("/")
    |> Enum.map(fn
      ":" <> _ -> "00000000-0000-0000-0000-000000000000"
      seg -> seg
    end)
    |> Enum.join("/")
  end

  describe "§1 unconfigured — the fence fails CLOSED" do
    test "a deleted :internal_allowed_cidrs 404s the family instead of waving it through" do
      Application.delete_env(:barkpark_cloud, :internal_allowed_cidrs)

      {method, path} = @filed_route

      # The row's prod measurement was 401 — "this route exists, wrong token".
      # An absent perimeter config must NOT reproduce that: a perimeter that
      # defaults open when nobody configured it is not a perimeter.
      assert call(method, path, @off_net).status == 404
    end

    test "an EMPTY list admits nobody — not everybody" do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, [])

      {method, path} = @filed_route
      assert call(method, path, @off_net, bearer: worker()).status == 404
      assert call(method, path, @on_net, bearer: worker()).status == 404
    end

    test "a config value of an unexpected shape refuses rather than opens" do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, "203.0.113.0/24")

      {method, path} = @filed_route
      assert call(method, path, @on_net, bearer: worker()).status == 404
    end

    test ":any is the NAMED opt-out — the dev/test default, and the only way back to main's behaviour" do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, :any)

      {method, path} = @filed_route

      # Exactly the row's prod measurement, reproduced on purpose: with the
      # network factor explicitly declined, an unauthenticated caller gets 401.
      assert call(method, path, @off_net).status == 401
    end

    test "the shipped config default IS that opt-out, so dev and test are unchanged" do
      # Control on the paragraph above: if config.exs ever ships a LIST, every
      # existing /v1/internal test in this suite starts 404ing and this says why.
      assert Application.get_env(:barkpark_cloud, :internal_allowed_cidrs) == :any
    end
  end

  describe "§2 armed — the network factor" do
    setup do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, @allowed)
      :ok
    end

    test "an OFF-NET caller holding the VALID worker token is 404'd" do
      {method, path} = @filed_route

      conn = call(method, path, @off_net, bearer: worker(), body: ~s({"deliveries":[]}))

      assert conn.status == 404
      assert conn.resp_body == ~s({"error":"not_found"})
    end

    test "an OFF-NET unauthenticated caller is 404'd — not 401, so nothing is announced" do
      {method, path} = @filed_route

      # This is the exact inversion of the row's prod measurement.
      assert call(method, path, @off_net).status == 404
    end

    test "the refusal is decided BEFORE the token compare — a wrong bearer and a right one look identical off-net" do
      {method, path} = @filed_route

      wrong = call(method, path, @off_net, bearer: "definitely-not-the-worker-token")
      right = call(method, path, @off_net, bearer: worker())

      assert wrong.status == 404
      assert right.status == 404
      assert wrong.resp_body == right.resp_body
    end

    test "an ON-NET caller is NOT refused by the fence — it reaches the token gate" do
      {method, path} = @filed_route

      # No bearer: the fence lets it through, `require_worker` then 401s. The
      # point is that the status is 401 (a token verdict) and not 404 (a network
      # verdict) — the fence is not blanket-blocking the surface.
      assert call(method, path, @on_net).status == 401
    end

    test "an ON-NET caller with the worker token gets PAST both gates" do
      {method, path} = @filed_route

      conn = call(method, path, @on_net, bearer: worker(), body: ~s({"deliveries":[]}))

      # Whatever the handler decides (2xx, 4xx on payload, 503 pre-migration), it
      # is NOT the fence's 404 and NOT the auth 401.
      refute conn.status == 404
      refute conn.status == 401
    end
  end

  describe "§3 coverage — a predicate, not a list" do
    setup do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, @allowed)
      :ok
    end

    test "the router declares a non-trivial /v1/internal/* family" do
      # Control: if this grep silently matched nothing, the sweep below would be
      # vacuously green.
      routes = declared_internal_routes()
      assert length(routes) >= 20, "derived only #{length(routes)} internal routes"
      assert @filed_route in routes
    end

    test "EVERY declared /v1/internal/* route is 404'd off-net, including ones this test never named" do
      offenders =
        for {method, path} <- declared_internal_routes(),
            conn = call(method, concretize(path), @off_net, bearer: worker()),
            conn.status != 404,
            do: {method, path, conn.status}

      assert offenders == [], "off-net callers reached: #{inspect(offenders)}"
    end
  end

  describe "§4 the matcher" do
    test "prefix arithmetic — the boundaries of a /24" do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, @allowed)
      {method, path} = @filed_route

      assert call(method, path, {203, 0, 113, 0}, bearer: worker()).status != 404
      assert call(method, path, {203, 0, 113, 255}, bearer: worker()).status != 404
      assert call(method, path, {203, 0, 114, 0}, bearer: worker()).status == 404
      assert call(method, path, {203, 0, 112, 255}, bearer: worker()).status == 404
    end

    test "a /32 admits exactly one address" do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, [{{203, 0, 113, 7}, 32}])
      {method, path} = @filed_route

      assert call(method, path, {203, 0, 113, 7}, bearer: worker()).status != 404
      assert call(method, path, {203, 0, 113, 8}, bearer: worker()).status == 404
    end

    test "families do not cross — a v6 caller is not admitted by a v4 range" do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, @allowed)
      {method, path} = @filed_route

      assert call(method, path, {0, 0, 0, 0, 0, 0xFFFF, 0xCB00, 0x7107}, bearer: worker()).status ==
               404
    end

    test "a v6 range admits a v6 caller and refuses a v4 one" do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, [
        {{0x2001, 0xDB8, 0, 0, 0, 0, 0, 0}, 32}
      ])

      {method, path} = @filed_route

      assert call(method, path, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}, bearer: worker()).status != 404
      assert call(method, path, {0x2001, 0xDB9, 0, 0, 0, 0, 0, 1}, bearer: worker()).status == 404
      assert call(method, path, @on_net, bearer: worker()).status == 404
    end

    test "a garbage remote_ip matches nothing — fail closed" do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, @allowed)
      {method, path} = @filed_route

      assert call(method, path, nil, bearer: worker()).status == 404
    end
  end

  describe "§5 blast radius" do
    setup do
      Application.put_env(:barkpark_cloud, :internal_allowed_cidrs, @allowed)
      :ok
    end

    test "a NON-internal path is untouched by an armed fence" do
      # /up is the control-plane liveness probe and must answer from anywhere.
      assert call("GET", "/up", @off_net).status in [200, 503]
    end

    test "the sibling worker surface /v1/admin/* is NOT fenced by this plug" do
      # Scope statement, not an endorsement: this row is about /v1/internal/*.
      # If /v1/admin/* is later brought inside the fence, this test is the place
      # that says so out loud.
      conn = call("GET", "/v1/admin/autoupdate", @off_net)
      assert conn.status != 404
    end
  end
end
