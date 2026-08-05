defmodule BarkparkCloud.Web.CrashEnvelopeCensusTest do
  @moduledoc """
  cch-w30-s5 — THE CRASH PATH ANSWERS IN THE SAME ENVELOPE AS EVERY OTHER ROUTE.

  WHAT WAS BROKEN, measured at L1 against a booted control plane on origin/main
  (`mix run --no-halt`, Bandit on :4100, `curl -w 'http_code=%{http_code}
  size_download=%{size_download} content_type=[%{content_type}]'`):

      malformed JSON body   → http_code=400 size_download=0 content_type=[]
      content-type text/plain → http_code=415 size_download=0 content_type=[]
      20 MB body            → http_code=413 size_download=0 content_type=[]

  ZERO BYTES and NO content-type on all three, while every ordinary answer is a
  flat JSON envelope (`401 {"error":"unauthorized"}`, `404 {"error":"not_found"}`).
  `Plug.Parsers` sits BEFORE `plug(:dispatch)`, so a parse fault needs no route
  defect at all, and nothing in the tree installed a `Plug.ErrorHandler`.

  WHY THE ASSERTION HERE IS "BODY + CONTENT-TYPE", NEVER "status == 500": Bandit
  already honours `Plug.Exception.plug_status`, so the STATUS was right on every
  arm. A guard asserting `status == 500` would be GREEN BY CONSTRUCTION and
  would have proved nothing. The invariant that was actually violated is the
  empty body with no content-type — which is exactly what `api()` in app.js
  turns into `{}` (it parses only `application/json`), sending the console down
  the caller's validation-shaped fallback: "Check the details and try again."
  about a fault the person had no part in.

  HOW THE RESPONSE IS CAPTURED WITHOUT A SOCKET: `Plug.ErrorHandler` responds
  and then RE-RAISES (so Bandit still logs the crash), so `Router.call/2` raises
  even when the envelope was sent perfectly. A `register_before_send/2` callback
  installed on the conn BEFORE the call survives into `handle_errors/2` — it is
  the same conn — and forwards the fully-populated status/headers/body to the
  test process. NO callback firing is precisely the origin/main zero-byte class,
  and that is what `:no_response` below means: the mutation proof (deleting
  `use Plug.ErrorHandler` from the router) turns every census row into
  `:no_response`.

  SIDE A IS DERIVED, NOT HAND-MAINTAINED: the route population is parsed out of
  the router's own `get|post|put|patch|delete "…"` declarations (177 today, of
  which 119 carry a body). A route added tomorrow is censused tomorrow; a hand
  list would have frozen at today's tree.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @router_source Path.join(__DIR__, "../../lib/barkpark_cloud/web/router.ex")
                 |> Path.expand()

  # Verbs Plug.Parsers actually parses (parsers.ex `@methods`). A GET can never
  # enter the parse-fault class — which is a FACT the census asserts below, not
  # an excuse for skipping them.
  @body_verbs ~w(post put patch delete)

  ## ── side A: the route population, derived from the router's own source ──

  defp declared_routes do
    @router_source
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^  (get|post|put|patch|delete) "([^"]+)"/, line) do
        [_, verb, path] -> [{verb, path}]
        nil -> []
      end
    end)
  end

  # `:param` / `*glob` segments get a concrete stand-in so the request is a real
  # one. It does not matter whether it MATCHES — the parse fault fires before
  # dispatch — but a real-shaped path keeps the census honest about what a
  # person's browser would send.
  defp concrete(path) do
    path
    |> String.split("/")
    |> Enum.map(fn
      ":" <> _ -> "00000000-0000-0000-0000-000000000000"
      "*" <> _ -> "census"
      seg -> seg
    end)
    |> Enum.join("/")
  end

  ## ── side B: what a forced fault actually answers ──

  defp fault(verb, path, content_type, body) do
    parent = self()

    conn =
      conn(String.to_atom(verb), concrete(path), body)
      |> put_req_header("content-type", content_type)
      |> register_before_send(fn c ->
        send(parent, {:crash_response, c.status, c.resp_headers, c.resp_body})
        c
      end)

    try do
      sent = Router.call(conn, @opts)
      {:returned, sent.status, sent.resp_headers, sent.resp_body}
    rescue
      _ ->
        receive do
          {:crash_response, status, headers, body} -> {:crash, status, headers, body}
        after
          0 -> :no_response
        end
    end
  end

  # THE invariant: a non-empty body carrying a flat `error` string, and a
  # content-type app.js will actually parse. Returns the decoded envelope.
  defp assert_envelope!({:crash, status, headers, body}, expected_status, where) do
    assert status == expected_status, "#{where}: status #{status}, expected #{expected_status}"

    ct = for({"content-type", v} <- headers, do: v) |> List.first()

    assert ct && String.contains?(ct, "application/json"),
           "#{where}: content-type is #{inspect(ct)} — app.js parses ONLY application/json, " <>
             "so anything else reaches the console as {} and renders blame copy"

    assert byte_size(body) > 0, "#{where}: ZERO-BYTE body — the origin/main defect"

    decoded = Jason.decode!(body)

    assert is_binary(decoded["error"]),
           "#{where}: `error` must be a FLAT string (app.js keys on data.error); got " <>
             inspect(decoded["error"])

    decoded
  end

  defp assert_envelope!(other, _expected_status, where) do
    flunk("""
    #{where}: no JSON envelope was sent — got #{inspect(other)}.

    `:no_response` is the origin/main defect verbatim: the request raised, the
    adapter closed the socket, and the caller received zero bytes with no
    content-type. Install/keep `use Plug.ErrorHandler` on the router.
    """)
  end

  ## ── the census ──

  test "side A: the route population is derived from the router, not a hand list" do
    routes = declared_routes()

    assert length(routes) > 150,
           "parsed only #{length(routes)} routes — the derivation regex has drifted from the source"

    body_routes = Enum.filter(routes, fn {verb, _} -> verb in @body_verbs end)

    # Printed so a reviewer can hold it beside
    #   grep -cE '^  (get|post|put|patch|delete) "' lib/barkpark_cloud/web/router.ex
    IO.puts(
      "\n[cch-w30-s5 census] routes declared: #{length(routes)} " <>
        "(body-carrying: #{length(body_routes)}, get: #{length(routes) - length(body_routes)})"
    )

    assert length(body_routes) > 100
  end

  test "every body-carrying route answers a malformed body with the JSON envelope" do
    routes = declared_routes() |> Enum.filter(fn {v, _} -> v in @body_verbs end)

    for {verb, path} <- routes do
      env =
        fault(verb, path, "application/json", "{")
        |> assert_envelope!(400, "#{verb} #{path} (malformed JSON)")

      assert env["error"] == "malformed_body"
      assert is_binary(env["request_id"]) and env["request_id"] != ""
    end
  end

  test "every body-carrying route answers an unparseable content-type with the JSON envelope" do
    routes = declared_routes() |> Enum.filter(fn {v, _} -> v in @body_verbs end)

    for {verb, path} <- routes do
      env =
        fault(verb, path, "text/plain", "hello")
        |> assert_envelope!(415, "#{verb} #{path} (text/plain)")

      assert env["error"] == "unsupported_media_type"
    end
  end

  test "an oversized body answers 413 in the envelope instead of a reset connection" do
    # The person-REACHABLE trigger (unlike the malformed-JSON arm, which the
    # console cannot produce: api() always sends JSON.stringify(body)). Default
    # Plug.Parsers :length is 8 MB.
    oversized = String.duplicate("x", 9_000_000)

    env =
      fault("post", "/v1/tokens", "application/json", oversized)
      |> assert_envelope!(413, "POST /v1/tokens (9 MB body)")

    assert env["error"] == "request_too_large"
  end

  test "GET routes are accounted for: they cannot enter the parse-fault class at all" do
    # Plug.Parsers only parses POST/PUT/PATCH/DELETE, so the 58 GETs are outside
    # this fault class by construction — proved, not assumed: a GET carrying the
    # same malformed body answers its ORDINARY envelope (401, unauthenticated),
    # never the crash path.
    gets = declared_routes() |> Enum.filter(fn {v, _} -> v == "get" end)
    assert length(gets) > 40

    result = fault("get", "/v1/me", "application/json", "{")

    assert {:returned, 401, _headers, body} = result
    assert Jason.decode!(body)["error"] == "unauthorized"
  end

  ## ── the 500 arm: a REAL raise on a REAL route ──

  test "a genuine raise inside a route answers 500 in the envelope, not zero bytes" do
    # Forcing technique per auth_onboarding_error_test.exs: a per-test BEFORE
    # UPDATE trigger inside this test's own sandboxed transaction raises a REAL
    # Postgres unique_violation. `Team.onboarding_changeset/2` declares NO
    # constraints, so Ecto CANNOT degrade it into `{:error, changeset}` — it
    # raises `Ecto.ConstraintError`, i.e. exactly the uncaught-raise class that
    # used to leave the person staring at a validation-shaped error message.
    {user, _team} = user_with_team()
    token = login_token(user)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION barkpark_test_force_team_raise()
    RETURNS trigger AS $$
    BEGIN
      RAISE unique_violation USING CONSTRAINT = 'teams_census_no_such_constraint';
    END;
    $$ LANGUAGE plpgsql;
    """)

    Repo.query!("""
    CREATE TRIGGER barkpark_test_force_team_raise_trg
    BEFORE UPDATE ON teams
    FOR EACH ROW EXECUTE FUNCTION barkpark_test_force_team_raise();
    """)

    parent = self()

    conn =
      conn(:post, "/v1/onboarding", Jason.encode!(%{action: "advance", step: "instance"}))
      |> put_req_header("content-type", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")
      |> register_before_send(fn c ->
        send(parent, {:crash_response, c.status, c.resp_headers, c.resp_body})
        c
      end)

    result =
      try do
        sent = Router.call(conn, @opts)
        {:returned, sent.status, sent.resp_headers, sent.resp_body}
      rescue
        _ ->
          receive do
            {:crash_response, s, h, b} -> {:crash, s, h, b}
          after
            0 -> :no_response
          end
      end

    case result do
      {:returned, status, _, body} ->
        # The route handled it without raising — then it must STILL be an
        # envelope (this is what the pre-existing fix on this route did).
        assert status >= 400
        assert is_binary(Jason.decode!(body)["error"])

      other ->
        env = assert_envelope!(other, 500, "POST /v1/onboarding (forced DB raise)")
        assert env["error"] == "server_error"
        assert is_binary(env["request_id"])
    end
  end

  test "the echoed request id is a bounded token, never the caller's bytes verbatim" do
    # x-request-id is REFLECTED into a response header and the JSON body, so a
    # hostile value must not survive. A boring token is honoured (the front's
    # id and our log line agree); anything else is replaced by a minted one.
    {:crash, _, headers, body} =
      fault_with_header("post", "/v1/tokens", "text/plain", "x", "caddy-abc.123_XY")

    assert Jason.decode!(body)["request_id"] == "caddy-abc.123_XY"
    assert {"x-request-id", "caddy-abc.123_XY"} in headers

    {:crash, _, _headers, body} =
      fault_with_header("post", "/v1/tokens", "text/plain", "x", "bad value\r\nx-evil: 1")

    id = Jason.decode!(body)["request_id"]
    refute String.contains?(id, "evil")
    assert id =~ ~r/\A[0-9a-f]{16}\z/
  end

  defp fault_with_header(verb, path, content_type, body, request_id) do
    parent = self()

    conn =
      conn(String.to_atom(verb), concrete(path), body)
      |> put_req_header("content-type", content_type)
      |> put_req_header("x-request-id", request_id)
      |> register_before_send(fn c ->
        send(parent, {:crash_response, c.status, c.resp_headers, c.resp_body})
        c
      end)

    try do
      sent = Router.call(conn, @opts)
      {:returned, sent.status, sent.resp_headers, sent.resp_body}
    rescue
      _ ->
        receive do
          {:crash_response, s, h, b} -> {:crash, s, h, b}
        after
          0 -> :no_response
        end
    end
  end

  ## fixtures (mirrors auth_onboarding_error_test.exs)

  @password "correct-horse-battery"

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "census-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {Accounts.get_user(user.id), team}
  end

  defp login_token(user) do
    conn =
      conn(:post, "/v1/auth/login", Jason.encode!(%{email: user.email, password: @password}))
      |> put_req_header("content-type", "application/json")

    Router.call(conn, @opts).resp_body |> Jason.decode!() |> Map.get("token")
  end
end
