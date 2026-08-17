defmodule BarkparkCloud.Web.RouterSitesDestroyFailuresTest do
  @moduledoc """
  cloud-console-hardening W68 — the DELETE /v1/sites/:id failure arms that CANNOT
  live in `router_sites_test.exs`, because that file is `async: true` and both
  tests here mutate process-global state:

    * the FK-REGRESSION 500 flips a live constraint with in-sandbox DDL
      (precedent: `content_publish_test.exs` "the whole TABLE is gone" — the
      sandbox rolls the ALTER back), and

    * the TEARDOWN TIMEOUT swaps `:site_box_relay` to the REAL
      `BoxRelay.HTTP` via `Application.put_env` — `FakeBoxRelay` replaces the
      whole of `teardown/2` including `await_teardown/3`, so NO test driving the
      fake can ever reach the 30s arm. The box is faked one seam lower, at the
      transport (`StudioLinkFakeHttpClient`), which is exactly where production
      loses a box that accepted the teardown and never finished it.

  THE FAST PATH: the timeout test spends its entire point — `await_teardown/3`'s
  real 30_000ms budget, ~601 polls, measured ~30.7s wall — so it is tagged
  `:slow`. Keep it out of a fast local loop with `mix test --exclude slow`; the
  cloud CI gate (and this slice's own gate command) runs the file whole.
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, StudioLinkFakeHttpClient}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.Sites.FakeBoxRelay
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @instance_url "https://acme.barkpark.cloud"
  @instance_admin_token "instance-admin-token-plaintext"

  ## Fixtures — the minimal subset of `router_sites_test.exs`'s (that module's
  ## are defp and unreachable from here).

  defp user_with_team do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{
        email: "destroy-#{n}@example.com",
        password: "correct-horse-battery"
      })

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp live_barkpark(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      url: @instance_url,
      host: "203.0.113.10",
      git_commit: "abc123",
      admin_token_encrypted: Vault.encrypt(@instance_admin_token)
    )
    |> Repo.update!()
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
        read_token: "bpt_public_read_xyz"
      })

    site
  end

  defp login_token(user) do
    {:ok, token} = Accounts.create_user_session_token(user)
    token
  end

  defp call(method, path, token) do
    conn(method, path)
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## ── THE FK-REGRESSION 500 (typed: registration_not_removed) ────────────────
  ##
  ## Loosen ONE cascade to RESTRICT and deleting the site row is refused by the
  ## database AFTER the box teardown already disarmed the Caddy route — the
  ## INVERSE ORPHAN. W70 S2 (D848/D856) made this HONEST: `Registry.delete_site/1`
  ## now RESCUES the `Ecto.ConstraintError{type: :foreign_key}` and returns
  ## `{:error, :foreign_key_constraint, constraint}`, and the router's `:ok` arm
  ## answers a TYPED `500 registration_not_removed` naming the constraint and
  ## both halves. So `delete_site/1` returns and `Router.call/2` returns — the
  ## test is now a PLAIN conn read, not the raise-expecting crash-envelope idiom
  ## it flipped from. `conn.status` is readable again.

  test "a cascade FK loosened to RESTRICT is a typed 500 registration_not_removed AFTER the box teardown — the inverse orphan, both halves stated" do
    {user, team} = user_with_team()
    bp = live_barkpark(team)
    site = static_site(bp)
    token = login_token(user)

    # A real artifact row, so the RESTRICT below has something to refuse over.
    {:ok, dep} = Registry.create_deployment(site, %{build_id: "fkregressbuild01"})

    Repo.insert!(%Registry.SiteArtifact{
      site_id: site.id,
      deployment_id: dep.id,
      sha256: String.duplicate("a", 64),
      byte_size: 3,
      bytes: <<1, 2, 3>>
    })

    # The in-sandbox DDL flip (precedent: content_publish_test.exs's in-sandbox
    # ALTER TABLE) — rolled back with the sandbox transaction, so no other test
    # ever sees it. This is the exact mutation `site_cascade_census_test.exs`
    # reds on structurally; this test is the BEHAVIOURAL half.
    Repo.query!("ALTER TABLE site_artifacts DROP CONSTRAINT site_artifacts_site_id_fkey")

    Repo.query!(
      "ALTER TABLE site_artifacts ADD CONSTRAINT site_artifacts_site_id_fkey " <>
        "FOREIGN KEY (site_id) REFERENCES sites(id) ON DELETE RESTRICT"
    )

    FakeBoxRelay.program(teardown: {:ok, 200, %{"status" => "torn_down"}})

    conn = call(:delete, "/v1/sites/#{site.id}", token)

    # The typed answer: a 500 that NAMES the outcome instead of a bare
    # server_error crash envelope.
    assert conn.status == 500
    body = json_body(conn)
    assert body["ok"] == false
    assert body["error"] == "registration_not_removed"

    # The detail states BOTH halves and names the blocking constraint — never
    # the raw multi-line ConstraintError.message.
    assert body["detail"] =~ "torn down"
    assert body["detail"] =~ "still registered"
    assert body["detail"] =~ "site_artifacts_site_id_fkey"

    # The inverse orphan, both halves measured: the box WAS told to tear down…
    assert Enum.any?(FakeBoxRelay.calls(), fn
             {:teardown, p} -> p.slug == site.slug
             _ -> false
           end)

    # …and the registration SURVIVES — that is the whole point of the refusal.
    refute Registry.get_site(site.id) == nil
  end

  ## ── THE TEARDOWN TIMEOUT (422, ~30.7s) ─────────────────────────────────────
  ##
  ## The box ACCEPTS the teardown (202) and then never reports `state: "done"`.
  ## The real `BoxRelay.HTTP.await_teardown/3` spends its whole 30_000ms budget
  ## polling (measured 601 polls), then mints `{:ok, 504, timeout-copy}` — which
  ## `Sites.Deploy.teardown/2` maps like every other `{:ok, 400..599}`: to a
  ## 422. There is NO route-visible 504; asserting one would pin an arm that
  ## does not exist. What the caller must get is the honest 422 whose copy says
  ## the teardown was not CONFIRMED — and a row that survives, because a box
  ## that may still be serving must never be deregistered.

  @tag :slow
  @tag timeout: 120_000
  test "a box that accepts the teardown and never finishes it is a 422 after the 30s budget, and the row survives" do
    # The REAL relay at the box seam; the box faked one seam lower, at the
    # transport. Restored in on_exit so the async:false ordering guarantees no
    # other file ever sees the swap.
    prev = Application.get_env(:barkpark_cloud, :site_box_relay)
    Application.put_env(:barkpark_cloud, :site_box_relay, BarkparkCloud.Sites.BoxRelay.HTTP)
    on_exit(fn -> Application.put_env(:barkpark_cloud, :site_box_relay, prev) end)

    {user, team} = user_with_team()
    bp = live_barkpark(team)
    site = static_site(bp)
    token = login_token(user)

    # Path-keyed: the POST (start) is answered 202 started; every GET poll gets
    # the same body, whose "state" is never "done" — so `await_teardown/3` polls
    # until its budget is gone.
    StudioLinkFakeHttpClient.program(%{
      "/v1/admin/site-deploy" => {:ok, %{status: 202, body: ~s({"status":"started"})}}
    })

    started = System.monotonic_time(:millisecond)
    conn = call(:delete, "/v1/sites/#{site.id}", token)
    elapsed_ms = System.monotonic_time(:millisecond) - started

    assert conn.status == 422
    body = json_body(conn)
    assert body["ok"] == false
    assert body["error"] == "teardown_failed"

    # The transport's own timeout sentence, verbatim — never rollback prose,
    # never "deploy".
    assert body["detail"] =~ "the instance did not confirm the teardown in time"
    refute body["detail"] =~ "roll back"
    refute body["detail"] =~ "deploy"

    # The budget was really spent: this is the 30s arm, not an early refusal.
    assert elapsed_ms >= 30_000

    # More than one poll actually went over the (fake) wire.
    polls =
      Enum.count(StudioLinkFakeHttpClient.requests(), fn req ->
        req.method == :get and String.contains?(req.url, "/v1/admin/site-deploy")
      end)

    assert polls > 100

    refute Registry.get_site(site.id) == nil
  end
end
