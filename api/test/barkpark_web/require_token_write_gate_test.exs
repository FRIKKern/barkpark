defmodule BarkparkWeb.RequireTokenWriteGateTest do
  @moduledoc """
  Fail-before protective test for task-a85afbbc0c4b1be3 — the `:require_token`
  census residue. A token minted `permissions: ["read"]` could MUTATE five flat
  routes that ride `[:api, :require_token]` with no write gate behind them.

  ## The mechanism

  `:require_token` was `RequireToken` + `PublicRead`. `PublicRead` clamps the
  tier BELOW `read` and no-ops for everything else, so between "a token exists"
  and the controller there was nothing at all for a `read` token. The sibling
  row (task-a87a3346b8ff736a) closed the `:token_root` plugin BUCKET the same
  way; this row closes the PIPELINE, which is where the residue lived:

      POST   /api/workspaces                          201, caller becomes OWNER
      POST   /api/workspaces/:workspace_slug/projects (already fenced — see below)
      POST   /v1/data/search/:dataset/reindex         enqueues a full-corpus rebuild
      POST   /v1/access                               writes a grant row
      DELETE /v1/access/:id                           retires a grant row

  ## What was ALREADY fixed, and why the test still carries it

  `WorkspaceController.create_project/2` calls
  `TenancyAuth.authorize(token, workspace.id, :write)` — the fix from
  `arpss-w10-bl-readonly-member-creates-projects`, which landed BEFORE this row
  was written. The census row inherited a stale description of that route. Its
  case below is therefore GREEN both before and after the mount gate, and it is
  labelled as such rather than counted as a catch: it certifies that the
  in-controller fence and the mount gate agree, and that the mount gate did not
  change its 403 into a 404 or a 500.

  Two routes the row's prose also named — `DELETE /api/workspaces/:slug` and
  `POST /api/playground` — were never in this population at all. Both sit on
  `[:api, :require_admin]`, which is why the row's TITLE says four and its body
  says five. The census-correction case at the bottom pins that by reading the
  router, so a future sweep cannot re-add them.

  ## Why the assertions are on STATE, not only on status

  The defect answered 2xx and the write landed. A gate that refuses AFTER the
  controller has written would still pass a status-only assertion, so every
  mutation case re-reads the store and asserts nothing moved.

  RED on origin/main (`POST /api/workspaces`, `POST …/reindex`, `POST /v1/access`
  and `DELETE /v1/access/:id` all answer 2xx for a `read` token); GREEN with
  `Plugs.RequireWriteForMutation` mounted in the pipeline.
  """

  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Access, Auth, Repo, TenancyFixtures}
  alias Barkpark.Tenancy
  alias BarkparkWeb.Plugs.RequireWriteForMutation

  @dataset "production"

  @router_path Path.expand("../../lib/barkpark_web/router.ex", __DIR__)

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()

    # Both tokens are bound to the SAME workspace and both get the membership
    # `Auth.create_token/5` writes, so nothing below can pass or fail for a
    # tenancy reason — the only variable is `permissions`.
    read = "req-token-gate-read-#{System.unique_integer([:positive])}"
    write = "req-token-gate-write-#{System.unique_integer([:positive])}"

    # `["read", "write"]`, not a bare `["write"]`: the read ladder is
    # `~w(read admin public-read)`, so a write-only token cannot confer even a
    # `read` capability through `POST /v1/access`. Refusing it there would be an
    # unrelated 403 that makes the not-over-confined arm below VACUOUS — it
    # would look like the gate biting when it is the capability ladder.
    {:ok, read_token} = Auth.create_token(read, "gate-read", @dataset, ["read"], ws.id)
    {:ok, _} = Auth.create_token(write, "gate-write", @dataset, ["read", "write"], ws.id)

    %{ws: ws, project: project, read: read, write: write, read_token: read_token}
  end

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Every refusal this gate emits must be the canonical envelope, not a bare
  # string — `{"error": {"code": …}}`. A 403 whose body is a naked message is a
  # different contract and breaks every SDK that switches on `error.code`.
  defp assert_forbidden_envelope!(resp, label) do
    assert resp.status == 403,
           "#{label} answered #{resp.status} for a read-only token: #{resp.resp_body}"

    body = Jason.decode!(resp.resp_body)

    assert is_binary(body["error"]["code"]),
           "#{label} refused without an ErrorResponse envelope: #{resp.resp_body}"

    body
  end

  # A grant that already exists, minted IN-PROCESS (never over HTTP) so the
  # DELETE probe is not vacuous.
  #
  # `Access.revoke/2` is grantor-or-admin. If the grant were minted by someone
  # else, the read-only token would be refused for an OWNERSHIP reason and the
  # case would pass identically with or without the write gate — a green that
  # proves nothing. The grantor here is therefore the read-only token ITSELF:
  # ownership is satisfied, so the ONLY thing left that can refuse the DELETE is
  # the write gate. Minted through the context (not `POST /v1/access`) because
  # after the fix that route is exactly what a read token can no longer reach.
  defp mint_grant_owned_by!(ws, grantor) do
    {:ok, %{grant: grant}} =
      Access.mint(grantor, %{
        "workspace_id" => ws.id,
        "grantee_email" => uniq("grantee") <> "@example.test",
        "capabilities" => ["read"]
      })

    grant
  end

  # ── The defect, route by route ────────────────────────────────────────────

  describe "a read-only token cannot mutate the :require_token surface" do
    test "POST /api/workspaces is refused and no workspace is created", %{
      conn: conn,
      read: read
    } do
      slug = uniq("gate-ws")

      resp =
        conn
        |> authed(read)
        |> post("/api/workspaces", Jason.encode!(%{slug: slug, name: "gate probe"}))

      assert_forbidden_envelope!(resp, "POST /api/workspaces")

      refute Tenancy.get_workspace_by_slug(slug),
             "the gate answered 403 but the workspace was created anyway — the " <>
               "refusal must land BEFORE create_workspace_with_owner/2"
    end

    test "POST /v1/data/search/:dataset/reindex is refused and enqueues nothing", %{
      conn: conn,
      read: read
    } do
      before = indexer_job_count()

      resp = conn |> authed(read) |> post("/v1/data/search/#{@dataset}/reindex")

      assert_forbidden_envelope!(resp, "POST /v1/data/search/#{@dataset}/reindex")

      assert indexer_job_count() == before,
             "the gate answered 403 but an IndexerWorker job was still enqueued — " <>
               "a full-corpus rebuild from the weakest credential"
    end

    test "POST /v1/access is refused and no grant row is written", %{
      conn: conn,
      read: read,
      ws: ws
    } do
      before = grant_count()

      body =
        Jason.encode!(%{
          workspace_id: ws.id,
          grantee_email: uniq("g") <> "@example.test",
          capabilities: ["read"]
        })

      resp = conn |> authed(read) |> post("/v1/access", body)

      assert_forbidden_envelope!(resp, "POST /v1/access")

      assert grant_count() == before,
             "the gate answered 403 but a grant row was still written"
    end

    test "DELETE /v1/access/:id is refused and the grant stays live", %{
      conn: conn,
      read: read,
      read_token: read_token,
      ws: ws
    } do
      grant = mint_grant_owned_by!(ws, read_token)

      resp = conn |> authed(read) |> delete("/v1/access/#{grant.id}")

      assert_forbidden_envelope!(resp, "DELETE /v1/access/#{grant.id}")

      assert is_nil(Access.get_grant(grant.id).revoked_at),
             "the gate answered 403 but the grant was revoked anyway"
    end

    # GREEN BEFORE AND AFTER — labelled, not counted. See the @moduledoc: the
    # in-controller `authorize(token, ws, :write)` already fenced this route
    # before the row was written. What this asserts is that the mount gate
    # AGREES with it rather than changing the answer.
    test "POST /api/workspaces/:slug/projects stays 403 (already fenced in-controller)",
         %{conn: conn, read: read, ws: ws} do
      slug = uniq("gate-proj")

      resp =
        conn
        |> authed(read)
        |> post(
          "/api/workspaces/#{ws.slug}/projects",
          Jason.encode!(%{slug: slug, name: "gate probe"})
        )

      assert_forbidden_envelope!(resp, "POST /api/workspaces/#{ws.slug}/projects")

      refute Enum.any?(Tenancy.list_projects(ws.id), &(&1.slug == slug)),
             "the project was created despite the 403"
    end

    test "every READ on the pipeline is byte-identical — GET is never gated", %{
      conn: conn,
      read: read
    } do
      resp = conn |> authed(read) |> get("/api/workspaces")

      assert resp.status == 200,
             "GET /api/workspaces answered #{resp.status} for a read token — the " <>
               "gate must pass safe methods through untouched"
    end
  end

  # ── NOT OVER-CONFINED: a write token still writes ─────────────────────────

  describe "a write token is unaffected" do
    test "POST /api/workspaces still creates", %{conn: conn, write: write} do
      slug = uniq("gate-ws-ok")

      resp =
        conn
        |> authed(write)
        |> post("/api/workspaces", Jason.encode!(%{slug: slug, name: "gate probe ok"}))

      assert resp.status == 201, "write token was refused: #{resp.status} #{resp.resp_body}"
      assert Tenancy.get_workspace_by_slug(slug)
    end

    test "POST /v1/access still mints", %{conn: conn, write: write, ws: ws} do
      body =
        Jason.encode!(%{
          workspace_id: ws.id,
          grantee_email: uniq("g") <> "@example.test",
          capabilities: ["read"]
        })

      resp = conn |> authed(write) |> post("/v1/access", body)

      assert resp.status == 201, "write token was refused: #{resp.status} #{resp.resp_body}"
    end

    test "POST /v1/data/search/:dataset/reindex still reaches the controller", %{
      conn: conn,
      write: write
    } do
      resp = conn |> authed(write) |> post("/v1/data/search/#{@dataset}/reindex")

      # The downstream outcome is deliberately NOT pinned: reindex enqueues an
      # Indx rebuild, so a 200-with-jobId and a canonical internal_error are
      # both legitimate depending on whether the worker is reachable here. What
      # is never legitimate is the write gate refusing a write token.
      refute resp.status == 403,
             "the write gate refused a WRITE token on reindex: #{resp.resp_body}"
    end

    test "the membership fence still bites a write token that is not a member", %{
      conn: conn,
      write: write
    } do
      other = TenancyFixtures.create_workspace!()

      resp =
        conn
        |> authed(write)
        |> post(
          "/api/workspaces/#{other.slug}/projects",
          Jason.encode!(%{slug: uniq("nope"), name: "nope"})
        )

      assert resp.status == 403,
             "a non-member write token got #{resp.status} — the membership check " <>
               "must still run after the write gate passes it: #{resp.resp_body}"
    end

    test "an unknown workspace slug is still 404, with no existence leak", %{
      conn: conn,
      write: write
    } do
      resp =
        conn
        |> authed(write)
        |> post(
          "/api/workspaces/#{uniq("no-such-ws")}/projects",
          Jason.encode!(%{slug: uniq("nope"), name: "nope"})
        )

      assert resp.status == 404, "unknown slug answered #{resp.status}: #{resp.resp_body}"
    end
  end

  # ── THE EXEMPTION: self-service survives the mount gate ───────────────────
  #
  # This is the reason a blanket pipeline gate was rejected the first time. If
  # either case below reds, read-only tokens have lost the ability to retire
  # themselves or to enter Studio, and the gate is over-confined.

  describe "self-service routes stay open to a read-only token" do
    test "DELETE /v1/auth/app-tokens/current still self-revokes", %{conn: conn, read: read} do
      resp = conn |> authed(read) |> delete("/v1/auth/app-tokens/current")

      assert resp.status == 200,
             "a read-only token could not self-revoke (#{resp.status}) — possession " <>
               "IS the authorization here and write-gating it strands the token: " <>
               resp.resp_body

      assert Jason.decode!(resp.resp_body)["revoked"] == true

      # Fail-closed proof: the same bearer is now rejected by :require_token.
      repeat = conn |> authed(read) |> delete("/v1/auth/app-tokens/current")
      assert repeat.status == 401
    end

    test "POST /v1/auth/login-tickets still mints a self-bound ticket", %{
      conn: conn,
      read: read
    } do
      resp = conn |> authed(read) |> post("/v1/auth/login-tickets", Jason.encode!(%{}))

      assert resp.status == 201,
             "a read-only token could not mint its OWN login ticket (#{resp.status}) — " <>
               "the ticket binds to the caller's own bearer and confers nothing new: " <>
               resp.resp_body

      assert is_binary(Jason.decode!(resp.resp_body)["ticket"])
    end

    # The three admin-bearer app-token routes are exempt for the OTHER reason:
    # the controller's `admin` check is strictly stronger than `:write`, and it
    # answers a non-admin bearer with the same generic 401 an INVALID bearer
    # gets. A 403 from the write gate would arrive first and announce "valid but
    # under-permissioned" — the tier oracle those routes exist to withhold.
    test "the admin app-token routes keep their no-tier-oracle 401, not a 403", %{
      conn: conn,
      read: read
    } do
      probes = [
        {"POST /v1/auth/app-tokens",
         fn c -> post(c, "/v1/auth/app-tokens", Jason.encode!(%{email: "x@example.test"})) end},
        {"DELETE /v1/auth/app-tokens",
         fn c -> delete(c, "/v1/auth/app-tokens", Jason.encode!(%{token: "nope"})) end},
        {"DELETE /v1/auth/app-tokens/:id",
         fn c -> delete(c, "/v1/auth/app-tokens/#{Ecto.UUID.generate()}") end}
      ]

      for {label, call} <- probes do
        resp = call.(authed(conn, read))

        assert resp.status == 401,
               "#{label} answered #{resp.status} for a read-only bearer — the write " <>
                 "gate must defer to the controller's stronger admin check here, or " <>
                 "the generic 401 becomes a tier oracle: #{resp.resp_body}"
      end
    end

    test "the ESCALATING login-ticket variant is still admin-only", %{conn: conn, read: read} do
      # The exemption must not become a hole: `user_email` JIT-provisions an
      # ACCOUNT, and that arm is gated on `admin` inside Auth.mint_login_ticket/2.
      resp =
        conn
        |> authed(read)
        |> post("/v1/auth/login-tickets", Jason.encode!(%{email: "someone@example.test"}))

      assert resp.status == 401, "read token minted a USER-shaped ticket: #{resp.resp_body}"
    end
  end

  # ── THE DURABLE GUARD: default CLOSED at the mount ────────────────────────

  describe "the gate is at the mount, so tomorrow's route is denied by default" do
    test "the :require_token pipeline itself runs the write gate, after the token check" do
      # BLOCK-scoped on `pipeline :require_token do … end`, not line-anchored:
      # inserting lines anywhere in router.ex cannot slide this assertion.
      # `Router.__routes__/0` cannot answer it — it carries no :pipe_through.
      block = pipeline_block!(":require_token")

      assert String.contains?(block, "RequireWriteForMutation"),
             "the :require_token pipeline does not run the write gate — every " <>
               "mutating route mounted on it is writable by a read-only token " <>
               "(task-a85afbbc0c4b1be3). Block:\n#{block}"

      assert offset_of!(block, "RequireToken)") < offset_of!(block, "RequireWriteForMutation"),
             "RequireToken must assign :api_token before the write gate reads it. " <>
               "Block:\n#{block}"
    end

    test "the gate refuses a route that does not exist yet, keyed on METHOD not on a path", %{
      read_token: read_token
    } do
      # A Phoenix router is compiled, so a genuinely new route cannot be added
      # from inside a test. What the acceptance criterion is really asking — "is
      # the verdict keyed on the METHOD, so a route nobody has written yet is
      # refused" — is answered by calling the mounted plug on a path that is not
      # in the router at all. If this ever passes the conn through, the gate has
      # acquired a route allow-list and stopped being default-closed.
      refused =
        :post
        |> Plug.Test.conn("/v1/a-route-nobody-has-written-yet")
        |> Plug.Conn.assign(:api_token, read_token)
        |> RequireWriteForMutation.call(RequireWriteForMutation.init([]))

      assert refused.halted, "the gate passed an unknown POST through for a read-only token"
      assert refused.status == 403

      # …and the same unknown path is untouched on a safe method, so the gate is
      # a write gate and not a blanket refusal.
      passed =
        :get
        |> Plug.Test.conn("/v1/a-route-nobody-has-written-yet")
        |> Plug.Conn.assign(:api_token, read_token)
        |> RequireWriteForMutation.call(RequireWriteForMutation.init([]))

      refute passed.halted
    end

    test "safe methods are exactly GET/HEAD/OPTIONS" do
      assert RequireWriteForMutation.safe_methods() == ~w(GET HEAD OPTIONS)
    end

    test "the exempt list is exactly the /v1/auth token-lifecycle surface" do
      # Asserted against the plug's own list so GROWING the hole is visible in a
      # diff this test reads, rather than in one it re-types. Adding an entry
      # here is a deliberate, reviewed act; that is the whole point of the list.
      assert RequireWriteForMutation.exempt_routes() == [
               {"DELETE", ["v1", "auth", "app-tokens", "current"]},
               {"POST", ["v1", "auth", "login-tickets"]},
               {"POST", ["v1", "auth", "app-tokens"]},
               {"DELETE", ["v1", "auth", "app-tokens"]},
               {"DELETE", ["v1", "auth", "app-tokens", :_]}
             ]
    end

    test "the `:_` segment matches exactly one segment — never zero, never a subtree" do
      # The one wildcard in the list is the `:id` of DELETE /v1/auth/app-tokens/:id.
      # If it ever matched greedily, everything under /v1/auth/app-tokens/ would
      # be exempt, and the list would have stopped being an enumeration.
      assert RequireWriteForMutation.exempt?("DELETE", ~w(v1 auth app-tokens abc))
      refute RequireWriteForMutation.exempt?("DELETE", ~w(v1 auth app-tokens abc def))
      refute RequireWriteForMutation.exempt?("POST", ~w(v1 auth app-tokens abc))
      refute RequireWriteForMutation.exempt?("DELETE", ~w(v1 auth))
    end
  end

  # ── THE CENSUS CORRECTION, pinned ─────────────────────────────────────────

  describe "the two routes the census row was wrong about" do
    test "DELETE /api/workspaces/:workspace_slug and POST /api/playground are :require_admin" do
      # The row's PROSE listed both as read-token-reachable; its TITLE (amended
      # to four) does not. Both have been admin-gated since long before the row
      # was filed, so they were never in this population. Pinned by reading the
      # router so a future sweep cannot re-add them to it — and so this test
      # reds if either is ever DOWNGRADED to :require_token.
      for {verb, path} <- [
            {"delete", "/workspaces/:workspace_slug"},
            {"post", "/playground"}
          ] do
        pipes = pipes_for_route!(verb, path)

        assert pipes =~ ":require_admin",
               "#{String.upcase(verb)} /api#{path} no longer rides :require_admin — " <>
                 "pipe_through: #{pipes}"
      end
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp router_source, do: File.read!(@router_path)

  # The full text of `pipeline <name> do … end`, matched on the block rather
  # than on a line number.
  defp pipeline_block!(name) do
    src = router_source()
    start = offset_of!(src, "pipeline #{name} do")
    rest = binary_part(src, start, byte_size(src) - start)
    stop = offset_of!(rest, "\n  end")
    binary_part(rest, 0, stop)
  end

  # The `pipe_through(...)` line governing the scope that declares `verb path`.
  # Walks BACKWARD from the route to the nearest preceding pipe_through, which
  # is the same attribution the census used — `Router.__routes__/0` carries no
  # :pipe_through key in this Phoenix version, so a route table cannot answer it.
  defp pipes_for_route!(verb, path) do
    src = router_source()
    at = offset_of!(src, ~s|#{verb}("#{path}"|)
    head = binary_part(src, 0, at)

    head
    |> String.split("\n")
    |> Enum.reverse()
    |> Enum.find(&String.contains?(&1, "pipe_through"))
    |> case do
      nil -> flunk("no pipe_through precedes #{verb} #{path} in router.ex")
      line -> String.trim(line)
    end
  end

  defp offset_of!(haystack, needle) do
    case :binary.match(haystack, needle) do
      {at, _} -> at
      :nomatch -> flunk("expected to find #{inspect(needle)}")
    end
  end

  defp grant_count, do: Repo.aggregate(Access.Grant, :count, :id)

  defp indexer_job_count do
    import Ecto.Query

    Repo.aggregate(
      from(j in "oban_jobs", where: j.worker == "Barkpark.Plugins.Indx.IndexerWorker"),
      :count,
      :id
    )
  end
end
