defmodule BarkparkCloud.Web.RouterTransportRedactionTest do
  @moduledoc """
  SECURITY / HYGIENE (transport-leak wave, D93) — the three deploy/upload
  TRANSPORT client echoes must never serialize an internal error term to the
  client. `Sites.Deploy.start_reported/1` is spec'd `{:error, term()}` (UNBOUNDED)
  and `read_artifact_body/2` wraps `Plug.Conn.read_body`'s error as `{:read,
  reason}`. Before the fix three sites echoed the raw term via `reason:
  inspect(reason)`:

    * `deploy_not_started` (box build, ~router.ex:12261)
    * `upload_failed`      (artifact read_body, ~router.ex:13923)
    * `deploy_not_started` (prebuilt upload,     ~router.ex:14006)

  Prod is BOUNDED (`TaskStarter` spawns `run/1` fire-and-forget and DISCARDS its
  rich terms; only a supervisor refusal — `{:error, {:error, :max_children}}` —
  or a `read_body` transport atom travels), so this is hygiene, not a live PII
  escape. Redacted anyway for defense-in-depth + starter-swap resilience: a config
  that installs a SYNCHRONOUS starter WOULD forward `run/1`'s rich terms. This
  wave introduces `transport_reason/1`, a bounded generic keyed on the error code,
  and belt-logs the full term via `Logger.error` at each router emit site.

  ## What is mutation-proven here, per site, through the RIGHT seam

  The `:site_deploy_starter` seam is PROCESS-LOCAL (`Process.put/2`), so these run
  `async: true` — they never swap the starter out from under a concurrent test.
  A `LeakyStarter` returns `{:error, <the process-local rich SENTINEL term>}` — a
  SYNCHRONOUS refusal, NOT `TaskStarter` (which discards the term, so a
  `TaskStarter`-based proof would be nil-stays-green: the sentinel never travels
  and the assertion passes vacuously on the UNFIXED tree too).

    * site 1 (box build)      — a `{:secret, SENTINEL, …}` rich term reaches the
      real POST /deploy route → 503 code preserved, sentinel ABSENT from
      resp_body, full term in `Logger.error`.
    * site 3 (prebuilt upload) — same rich term through the real artifact-upload
      route → 503 code preserved, sentinel absent, full term logged.
    * site 2 shape (`{:read, {:aws_key, SENTINEL, …}}`) — `read_body` cannot carry
      a rich term at runtime (its reason is always a transport atom), so there is
      NO route-level read-body injection seam; a route test on the upload_failed
      arm would be dishonest. The exact synthetic shape is driven through the
      deploy-starter seam instead — the only route that admits an arbitrary
      `{:error, term()}` — proving `transport_reason/1`'s bare `_` catch-all (the
      SAME clause the `{:read, …}` site uses) redacts `{:read, {:aws_key, …}}`
      fail-closed: generic out, `AKIA_…`/`aws_key` absent.

  Each proof asserts the error CODE present FIRST (non-vacuity — not a
  401/403/409/422 short-circuit), THEN the SENTINEL absent, THEN the full term in
  the log — and each REDS on revert-to-`inspect(reason)` (inspect would echo the
  whole term, sentinel and all, into resp_body).

  ## The P1 source tripwire

  `no `<code>` echoes an inspected term to the client` scans every `.ex` under
  `cloud/lib` for `(reason|detail|message|error):\\s*inspect\\(` and asserts ZERO
  (comment lines stripped). It REDS the instant any of the three sites is reverted
  to `inspect(reason)` — the durable class guard, not just these three lines.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn
  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_url "https://acme.barkpark.cloud"

  # The rich terms an unbounded starter / a swapped read path COULD forward. Each
  # carries a substring that must never reach the wire.
  @deploy_sentinel "SENTINEL_bpt_live_9f3xLEAK"
  @deploy_term {:secret, @deploy_sentinel, %{token: "bpt_live_9f3xLEAK", cus: "cus_abc"}}

  @read_sentinel "AKIA_SENTINEL_ROUTE2"
  @read_term {:read, {:aws_key, @read_sentinel, %{secret: "wJalrXUtnFEMI_LEAK"}}}

  @generic "the request could not be completed"

  ## Starter seam — a SYNCHRONOUS refusal that forwards a rich term (NOT TaskStarter)

  defmodule LeakyStarter do
    @moduledoc false
    @behaviour BarkparkCloud.Sites.Deploy.Starter

    # Reads the term from the CALLER's process dictionary — the route calls
    # `start/1` synchronously in the request (test) process, so this is visible
    # and stays process-local under `async: true`.
    @impl true
    def start(_deployment_id), do: {:error, Process.get(:leaky_term)}
  end

  ## Fixtures (mirror router_sites_test.exs)

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp user_with_team do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp live_barkpark(team) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
    )
    |> BarkparkCloud.Repo.update!()
  end

  defp static_site(bp) do
    n = System.unique_integer([:positive])

    {:ok, site} =
      Registry.create_site(bp, %{
        name: "Blog #{n}",
        slug: "blog-#{n}",
        kind: "static",
        framework: "astro",
        bootstrap_workspace: "acme",
        bootstrap_project: "blog",
        bootstrap_dataset: "production",
        read_token: "bpt_public_read"
      })

    site
  end

  defp prebuilt_site(bp) do
    {:ok, site} = Registry.update_site_settings(static_site(bp), %{prebuilt_enabled: true})
    site
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp call_binary(method, path, body, token) when is_binary(body) do
    conn(method, path, body)
    |> put_req_header("content-type", "application/octet-stream")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp sha256_hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp mint_prebuilt(site, token) do
    conn = call(:post, "/v1/sites/#{site.id}/deploy", %{source: "prebuilt"}, token)
    assert conn.status == 201
    json_body(conn)["deployment"]
  end

  ## ---------------------------------------------------------------------------
  ## Site 1 — box build (deploy_not_started, ~router.ex:12261)
  ## ---------------------------------------------------------------------------

  describe "site 1 (box build) — a rich starter refusal never reaches the client" do
    test "POST /v1/sites/:id/deploy → 503 deploy_not_started, sentinel redacted, full term logged" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      Process.put(:leaky_term, @deploy_term)
      Process.put(:site_deploy_starter, LeakyStarter)

      {conn, log} = with_log(fn -> call(:post, "/v1/sites/#{site.id}/deploy", %{}, token) end)

      # Non-vacuity FIRST: the code is preserved (Go cloudError / JS friendly()
      # key on it — zero UI regression) and we actually reached the emit site.
      assert conn.status == 503, "expected the deploy_not_started arm, got #{conn.status}"
      body = json_body(conn)
      assert body["error"] == "deploy_not_started"

      # THE SEAL: the rich term's sentinel appears NOWHERE in the client response.
      refute conn.resp_body =~ @deploy_sentinel
      assert body["reason"] == @generic

      # …while the full term IS in the server log (operators keep the diagnostic).
      assert log =~ "deploy_not_started (box build)"
      assert log =~ @deploy_sentinel
    end
  end

  ## ---------------------------------------------------------------------------
  ## Site 3 — prebuilt upload (deploy_not_started, ~router.ex:14006)
  ## ---------------------------------------------------------------------------

  describe "site 3 (prebuilt upload) — a rich starter refusal never reaches the client" do
    test "POST …/deployments/:id/artifact → 503 deploy_not_started, sentinel redacted, full term logged" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = prebuilt_site(bp)
      token = login_token(user)

      # The mint starts no driver (mint-then-upload, D86), so it still 201s.
      dep = mint_prebuilt(site, token)

      Process.put(:leaky_term, @deploy_term)
      Process.put(:site_deploy_starter, LeakyStarter)

      payload = :crypto.strong_rand_bytes(1024)
      sha = sha256_hex(payload)

      {conn, log} =
        with_log(fn ->
          call_binary(
            :post,
            "/v1/sites/#{site.id}/deployments/#{dep["id"]}/artifact",
            payload,
            token
          )
        end)

      assert conn.status == 503, "expected the deploy_not_started arm, got #{conn.status}"
      body = json_body(conn)
      assert body["error"] == "deploy_not_started"
      assert body["artifact_sha256"] == sha

      refute conn.resp_body =~ @deploy_sentinel
      assert body["reason"] == @generic

      assert log =~ "deploy_not_started (prebuilt upload)"
      assert log =~ @deploy_sentinel
    end
  end

  ## ---------------------------------------------------------------------------
  ## Site 2 shape — {:read, {:aws_key, SENTINEL, …}} (upload_failed, ~router.ex:13923)
  ##
  ## `read_body`'s reason is ALWAYS a bounded transport atom in prod, so there is
  ## no route-level read-body rich-term seam and a route test on the upload_failed
  ## arm would be dishonest. We drive the EXACT synthetic shape through the
  ## deploy-starter seam — the only route that admits an arbitrary `{:error,
  ## term()}` — proving `transport_reason/1`'s bare `_` catch-all (the SAME clause
  ## the upload_failed site uses) redacts it fail-closed.
  ## ---------------------------------------------------------------------------

  describe "site 2 shape — a {:read,{:aws_key,…}} term is redacted fail-closed by the shared catch-all" do
    test "the AKIA sentinel and aws_key tag never reach the client; generic out, full term logged" do
      {user, team} = user_with_team()
      bp = live_barkpark(team)
      site = static_site(bp)
      token = login_token(user)

      Process.put(:leaky_term, @read_term)
      Process.put(:site_deploy_starter, LeakyStarter)

      {conn, log} = with_log(fn -> call(:post, "/v1/sites/#{site.id}/deploy", %{}, token) end)

      assert conn.status == 503, "expected the deploy_not_started arm, got #{conn.status}"
      body = json_body(conn)
      assert body["error"] == "deploy_not_started"

      # The bare `_` catch-all fixed generic (fail-closed): the AWS key material
      # is gone from the wire.
      refute conn.resp_body =~ @read_sentinel
      refute conn.resp_body =~ "aws_key"
      assert body["reason"] == @generic

      # …and the full read-shaped term is on the server log.
      assert log =~ @read_sentinel
    end
  end

  ## ---------------------------------------------------------------------------
  ## P1 SOURCE TRIPWIRE (D95) — the durable class guard
  ## ---------------------------------------------------------------------------

  describe "P1 tripwire: no client echo inspects an internal term" do
    # This file lives at test/barkpark_cloud/web/, so `cloud/lib` is three levels
    # up — NOT two. A wrong depth resolves to a nonexistent dir, the wildcard
    # returns [], and the guard passes VACUOUSLY; the `files_scanned > 0` +
    # "router.ex present" assertions below make that failure loud.
    @lib Path.expand("../../../lib", __DIR__)
    # A `key: inspect(` echo into a client body. Deliberately NOT the `#{inspect}`
    # interpolation variant — that has 16 legit Logger call-sites (D95).
    @echo_re ~r/(reason|detail|message|error):\s*inspect\(/

    test "git grep `(reason|detail|message|error): inspect(` over cloud/lib returns ZERO" do
      files =
        @lib
        |> Path.join("**/*.ex")
        |> Path.wildcard()
        |> Enum.sort()

      # Anti-vacuity: a mis-resolved @lib would scan nothing and pass by default.
      assert length(files) > 50, "expected to scan cloud/lib — only saw #{length(files)} files"

      assert Enum.any?(files, &String.ends_with?(&1, "web/router.ex")),
             "cloud/lib/barkpark_cloud/web/router.ex must be in the scan set"

      offenders =
        files
        |> Enum.flat_map(fn path ->
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.with_index(1)
          # Strip full-line comments so the sentinel prose / doc examples that
          # NAME the anti-pattern do not trip the guard (console_reader_census
          # shows the hazard).
          |> Enum.reject(fn {line, _n} -> String.match?(line, ~r/^\s*#/) end)
          |> Enum.filter(fn {line, _n} -> Regex.match?(@echo_re, line) end)
          |> Enum.map(fn {line, n} -> "#{Path.relative_to(path, @lib)}:#{n}: #{String.trim(line)}" end)
        end)

      assert offenders == [],
             "a client echo serializes an internal term via inspect(...) — redact it with a " <>
               "bounded helper (transport_reason/1 / billing_reason/1 / cloudflare_reason/1) and " <>
               "Logger.error the full term server-side:\n" <> Enum.join(offenders, "\n")
    end
  end
end
