defmodule BarkparkCloud.Web.RouterSuspendedRefusalAuditTest do
  @moduledoc """
  cch-w59-bl — A REFUSED WRITE AGAINST A SUSPENDED BOX LEAVES A ROW.

  Before this slice, a refusal left exactly the trace of nobody doing anything.
  `Accounts.audit/3` is atomic with its mutation by design — `{:error, reason}`
  from the closure is `Repo.rollback(reason)`, no row — and a refusal IS that
  error tuple, so the refused path could not have written through it even if
  someone had tried. A suspended customer hammering the wire button and an idle
  account were indistinguishable in the audit register.

  WHAT IS PROVED HERE, and it is deliberately NOT "the helper looks right":
  every test below DRIVES a real request through `Router.call/2` and then READS
  THE TRACE BACK out of `audit_events` through `Accounts.list_audit_events/2` —
  the same operator-facing reader `GET /v1/audit` serves. A test that asserted
  on `audit_suspended_refusal/4`'s arguments would pass over a row that never
  committed; this one cannot.

  THE DECISION IS MADE ONCE (the c1 arm). One verb —
  `barkpark.suspended_refused` — for EVERY suspended refusal in the control
  plane, with the act carried as `metadata.route`. The last describe block is a
  SOURCE CENSUS that makes "once, for all of them" mechanical: it enumerates
  every suspended-refusal clause head in `router.ex` and fails unless each one
  is wired, and unless the population is exactly the ten this slice ruled on. An
  eleventh refusal site reds it, which is the whole point — a per-route decision
  would have made the next route's omission invisible.

  THE CONTROLS ARE PART OF THE PROOF, in both directions:

    * an UNSUSPENDED box driving the same route to a 200 writes NO
      `barkpark.suspended_refused` row, so the verb means "refused", not
      "traffic";
    * the refusal itself is UNCHANGED — same 409, same envelope, and
      `StudioLinkFakeHttpClient.requests() == []`, so the row is written from
      the plane's own knowledge and the audit write did not drag the credential
      onto a wire.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @admin_token "instance-admin-token-plaintext"
  @instance_url "https://prod.barkpark.cloud"
  @workspace "acme"
  @dataset "production"
  @site "https://acme-blog.vercel.app"
  @refusal_action "barkpark.suspended_refused"

  # The foreign twin's url. It CANNOT be `@instance_url`: `barkparks_url_unique_idx`
  # is a global unique index, so the url is the one field the DATABASE forces
  # apart between the in-team fixture and its foreign twin.
  @victim_url "https://victim.barkpark.cloud"

  @router_source Path.expand("../../../lib/barkpark_cloud/web/router.ex", __DIR__)

  # The eleven suspended-refusal clause heads, by the SHAPE each one has in
  # `router.ex`. Three shapes, because the refusal arrives three ways: a `cond`
  # leg on the row's own boolean, a `case` leg on a Registry error tuple, and a
  # `case` leg that pattern-matches the suspended row itself.
  @refusal_clause_heads [
    {~r/^\s*bp\.suspended( and [^-]*)? ->\s*$/,
     "a `cond` leg on the row's boolean (verify / self-update / rollback / instance-API :mutate)"},
    {~r/^\s*\{:error, :suspended\} ->\s*$/,
     "a `case` leg on a Registry `{:error, :suspended}` (studio-link / studio-signin / app-token / push-relay / site-url)"},
    {~r/^\s*%Barkpark\{team_id: tid, suspended: true\} = bp when tid == team\.id ->\s*$/,
     "a `case` leg matching the suspended row itself (credentials / bootstrap)"}
  ]

  # Equality, not a floor: a NEW suspended refusal that forgets the trace reds
  # here, and so does a deleted one (which would mean a refusal was loosened).
  @refusal_site_count 11

  ## Fixtures

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp user_with_team(role) do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, role)
    {:ok, session} = Accounts.create_user_session_token(user)
    {user, team, session}
  end

  defp bootstrapped_barkpark(team, attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          url: @instance_url,
          host: "203.0.113.10",
          admin_token_encrypted: Vault.encrypt(@admin_token),
          template: "blog-starter",
          bootstrap_workspace: @workspace,
          bootstrap_project: "default",
          bootstrap_dataset: @dataset,
          bootstrap_read_token_encrypted: Vault.encrypt("bp_read_secret")
        },
        attrs
      )
    )
    |> Repo.update!()
  end

  # The billing verdict exactly as `Billing.cancel_subscription/1` writes it.
  defp suspended_attrs do
    %{
      suspended: true,
      suspended_reason: "billing_lapsed",
      suspended_at: DateTime.utc_now(),
      last_verified_at: nil,
      verify_reachable: nil
    }
  end

  defp call(method, path, body, session) do
    conn =
      case method do
        :get -> conn(:get, path)
        _ -> conn(method, path, Jason.encode!(body))
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{session}")
    |> Router.call(@opts)
  end

  # THE READ-BACK. Not a `Repo.all(AuditEvent)` — this is the same reader the
  # console's audit feed is served from, scoped to the box, so a row this query
  # cannot see is a row the operator cannot see either.
  defp refusal_rows(team, bp) do
    team
    |> Accounts.list_audit_events(target_type: "barkpark", target_id: bp.id)
    |> Enum.filter(&(&1.action == @refusal_action))
  end

  # Whole-comment lines dropped, so a clause head quoted in prose cannot stand
  # in for one in code. Every regex below is anchored at the start of the line,
  # so a trailing `# …` comment on a code line is harmless.
  defp router_code_lines do
    @router_source
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
  end

  ## The trace

  describe "a refusal writes ONE queryable row, read back from the audit table" do
    test "POST /site-url on a suspended box: 409, no wire, and a row naming the act" do
      {user, team, session} = user_with_team("member")
      bp = bootstrapped_barkpark(team, suspended_attrs())

      assert refusal_rows(team, bp) == []

      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, session)

      # The refusal is untouched by this slice.
      assert conn.status == 409
      assert Jason.decode!(conn.resp_body) == %{"error" => "suspended"}
      assert StudioLinkFakeHttpClient.requests() == []

      # And it is now VISIBLE.
      assert [row] = refusal_rows(team, bp)
      assert row.action == @refusal_action
      assert row.target_type == "barkpark"
      assert row.target_id == bp.id
      assert row.actor_user_id == user.id
      assert row.metadata["route"] == "site-url"
      assert row.metadata["method"] == "POST"
      assert row.metadata["path"] == "/v1/barkparks/#{bp.id}/site-url"

      # The row is a fact about the plane, never a credential leak.
      refute inspect(row.metadata) =~ @admin_token
    end

    test "POST /studio-link on a suspended box: 409, no wire, and a row naming a DIFFERENT act" do
      {user, team, session} = user_with_team("member")
      bp = bootstrapped_barkpark(team, suspended_attrs())

      conn = call(:post, "/v1/barkparks/#{bp.id}/studio-link", %{}, session)

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"] == "suspended"
      assert StudioLinkFakeHttpClient.requests() == []

      assert [row] = refusal_rows(team, bp)
      assert row.action == @refusal_action
      assert row.actor_user_id == user.id
      assert row.metadata["route"] == "studio-link"
    end

    test "TWO different routes against the SAME box: two rows, one verb, two `route` values" do
      {_user, team, session} = user_with_team("owner")
      bp = bootstrapped_barkpark(team, suspended_attrs())

      assert call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, session).status == 409
      assert call(:post, "/v1/barkparks/#{bp.id}/self-update", %{}, session).status == 409

      rows = refusal_rows(team, bp)
      assert length(rows) == 2

      # ONE event name for both. This is the c1 decision, asserted rather than
      # described: an operator queries one verb and sees every attempt.
      assert Enum.uniq(Enum.map(rows, & &1.action)) == [@refusal_action]

      assert rows |> Enum.map(& &1.metadata["route"]) |> Enum.sort() ==
               ["self-update", "site-url"]
    end

    test "the instance-API :mutate tier refuses and names the CAPABILITY in `route`" do
      {_user, team, session} = user_with_team("owner")
      bp = bootstrapped_barkpark(team, suspended_attrs())

      conn =
        call(:post, "/v1/barkparks/#{bp.id}/api/webhooks", %{name: "hook"}, session)

      assert conn.status == 409
      assert Jason.decode!(conn.resp_body)["error"]["code"] == "suspended"
      assert StudioLinkFakeHttpClient.requests() == []

      assert [row] = refusal_rows(team, bp)
      assert row.metadata["route"] == "instance-api:webhook.create"
    end

    test "GET /credentials and GET /bootstrap — the REVEAL refusals leave rows too" do
      {_user, team, session} = user_with_team("owner")
      bp = bootstrapped_barkpark(team, suspended_attrs())

      assert call(:get, "/v1/barkparks/#{bp.id}/credentials", nil, session).status == 409
      assert call(:get, "/v1/barkparks/#{bp.id}/bootstrap", nil, session).status == 409

      rows = refusal_rows(team, bp)
      assert length(rows) == 2

      assert rows |> Enum.map(& &1.metadata["route"]) |> Enum.sort() ==
               ["bootstrap", "credentials"]

      assert Enum.all?(rows, &(&1.metadata["method"] == "GET"))
      refute Enum.any?(rows, &(inspect(&1.metadata) =~ @admin_token))
    end
  end

  ## The controls

  describe "CONTROLS — the verb means REFUSED, and the refusal is unchanged" do
    test "an UNSUSPENDED box driving the same route to 200 writes NO refusal row" do
      {_user, team, session} = user_with_team("member")
      bp = bootstrapped_barkpark(team)

      StudioLinkFakeHttpClient.program([
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               webhooks: [%{id: "wh_1", name: "bootstrap-revalidation", active: false}]
             })
         }},
        {:ok, %{status: 200, body: ~s({"webhook":{"id":"wh_1","active":true}})}}
      ])

      conn = call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, session)

      # The happy path is untouched — if this 409s, the guard has started
      # refusing boxes that are not suspended and the whole file is vacuous.
      assert conn.status == 200
      assert length(StudioLinkFakeHttpClient.requests()) == 2

      assert refusal_rows(team, bp) == []
    end

    test "the refusal row is written OUTSIDE the transaction that rolls back" do
      {_user, team, session} = user_with_team("owner")
      bp = bootstrapped_barkpark(team, suspended_attrs())

      # push-relay is the route whose success path runs through `Accounts.audit/3`
      # (the wrapper whose rollback is the whole reason this slice exists). Its
      # refusal returns the error tuple that wrapper rolls back on — so a row
      # visible here is proof the write does not ride that transaction.
      assert call(:post, "/v1/barkparks/#{bp.id}/push-relay", %{}, session).status == 409

      assert [row] = refusal_rows(team, bp)
      assert row.metadata["route"] == "push-relay"

      # And no SUCCESS row was invented: the act did not happen.
      all_actions =
        team
        |> Accounts.list_audit_events(target_type: "barkpark", target_id: bp.id)
        |> Enum.map(& &1.action)

      refute "barkpark.push_relay_provisioned" in all_actions
    end

    test "another team cannot read the row (it is team-scoped like every audit row)" do
      {_user, team, session} = user_with_team("owner")
      {_other_user, other_team, _other_session} = user_with_team("owner")
      bp = bootstrapped_barkpark(team, suspended_attrs())

      assert call(:post, "/v1/barkparks/#{bp.id}/site-url", %{url: @site}, session).status == 409

      assert [_row] = refusal_rows(team, bp)
      assert refusal_rows(other_team, bp) == []
    end
  end

  ## The tenancy guard ON the suspended arm — the clause nothing reached

  describe "TENANCY on the suspended arm — a FOREIGN suspended box is an unknown id" do
    # cch-w13 (task-578415f2b7050530). Both reveal routes refuse a suspended box
    # with
    #
    #     %Barkpark{team_id: tid, suspended: true} = bp when tid == team.id ->
    #
    # and the `when tid == team.id` on THAT clause is the only thing that stops
    # another team's suspended box from answering `409 suspended` — which would
    # leak both the id's existence and the victim team's billing state — and
    # from minting a `barkpark.suspended_refused` row carrying the CALLER's
    # team_id against a box the caller does not own.
    #
    # No fixture in this repo reached it. Every suspended-box test above builds
    # the box IN-TEAM, and every cross-team test elsewhere builds it
    # UNSUSPENDED, so the sibling `suspended: true` pattern matched first on
    # every input and the guard could be deleted in silence (MUTATION M6: the
    # full cloud suite stayed green but for the SOURCE CENSUS below, which reads
    # router.ex's TEXT and asserts nothing about behaviour).
    #
    # Each test below is the FOREIGN TWIN of the in-team 409 fixture in "GET
    # /credentials and GET /bootstrap — the REVEAL refusals leave rows too":
    # same builder, the SAME `suspended_attrs()` map (bound once, so even
    # `suspended_at` is identical), differing only in the team the row is
    # registered to. `name`/`slug`/`id` differ as a FORCED consequence of
    # `bootstrapped_barkpark/2`'s uniqueness, and `url` as a FORCED consequence
    # of the `barkparks_url_unique_idx` unique index (two rows CANNOT share a
    # url; run-proved — the first cut of these tests raised
    # `Ecto.ConstraintError` on exactly that index). None of the four is a
    # free choice and none is read by `when tid == team.id`, which reads
    # `team_id` and nothing else.

    test "GET /credentials — a FOREIGN suspended box answers 404, byte-identical to an unknown id" do
      {_user, team, session} = user_with_team("owner")
      {_victim, victim_team, _victim_session} = user_with_team("owner")

      attrs = suspended_attrs()
      in_team = bootstrapped_barkpark(team, attrs)
      foreign = bootstrapped_barkpark(victim_team, Map.put(attrs, :url, @victim_url))

      # PRECONDITION — the twin is a twin. If this drifts, a 404 below could be
      # explained by some field other than the one under test.
      assert foreign.suspended == in_team.suspended
      assert foreign.suspended_reason == in_team.suspended_reason
      assert foreign.suspended_at == in_team.suspended_at
      # FORCED, not chosen: `barkparks_url_unique_idx` forbids a shared url.
      assert foreign.url == @victim_url
      assert foreign.host == in_team.host
      assert foreign.template == in_team.template
      # The CIPHERTEXTS differ by construction — `Vault.encrypt/1` draws a fresh
      # IV per call, so equal bytes here would mean the vault was broken. The
      # PLAINTEXT is what the twin shares, and it is what the reveal would have
      # handed back had the guard let the request through.
      assert Vault.decrypt(foreign.admin_token_encrypted) == {:ok, @admin_token}
      assert Vault.decrypt(in_team.admin_token_encrypted) == {:ok, @admin_token}
      assert foreign.team_id == victim_team.id
      assert in_team.team_id == team.id

      # CONTROL — the guard's own arm still fires for the caller's own box, so a
      # 404 on the foreign twin is the GUARD refusing, not the arm being dead.
      mine = call(:get, "/v1/barkparks/#{in_team.id}/credentials", nil, session)
      assert mine.status == 409
      assert Jason.decode!(mine.resp_body)["error"] == "suspended"

      unknown = call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/credentials", nil, session)
      theirs = call(:get, "/v1/barkparks/#{foreign.id}/credentials", nil, session)

      assert theirs.status == 404
      assert theirs.status == unknown.status
      assert theirs.resp_body == unknown.resp_body
      assert Jason.decode!(theirs.resp_body) == %{"error" => "not_found"}

      # c2 — NO mis-attributed trail, on EITHER side of the fence. Team-scoped
      # reads, not `Repo.aggregate/3`: a global count would see other lanes' rows.
      assert refusal_rows(team, foreign) == []
      assert refusal_rows(victim_team, foreign) == []
    end

    test "GET /bootstrap — a FOREIGN suspended box answers 404, byte-identical to an unknown id" do
      {_user, team, session} = user_with_team("owner")
      {_victim, victim_team, _victim_session} = user_with_team("owner")

      attrs = suspended_attrs()
      in_team = bootstrapped_barkpark(team, attrs)
      foreign = bootstrapped_barkpark(victim_team, Map.put(attrs, :url, @victim_url))

      assert foreign.suspended == in_team.suspended
      assert foreign.suspended_reason == in_team.suspended_reason
      assert foreign.suspended_at == in_team.suspended_at
      assert foreign.bootstrap_workspace == in_team.bootstrap_workspace
      assert foreign.bootstrap_dataset == in_team.bootstrap_dataset
      # Ciphertext differs by construction (fresh IV per `Vault.encrypt/1`);
      # the secret the twin carries is the same one.
      assert Vault.decrypt(foreign.bootstrap_read_token_encrypted) == {:ok, "bp_read_secret"}
      assert Vault.decrypt(in_team.bootstrap_read_token_encrypted) == {:ok, "bp_read_secret"}
      assert foreign.team_id == victim_team.id
      assert in_team.team_id == team.id

      mine = call(:get, "/v1/barkparks/#{in_team.id}/bootstrap", nil, session)
      assert mine.status == 409
      assert Jason.decode!(mine.resp_body)["error"] == "suspended"

      unknown = call(:get, "/v1/barkparks/#{Ecto.UUID.generate()}/bootstrap", nil, session)
      theirs = call(:get, "/v1/barkparks/#{foreign.id}/bootstrap", nil, session)

      assert theirs.status == 404
      assert theirs.status == unknown.status
      assert theirs.resp_body == unknown.resp_body
      assert Jason.decode!(theirs.resp_body) == %{"error" => "not_found"}

      assert refusal_rows(team, foreign) == []
      assert refusal_rows(victim_team, foreign) == []
    end
  end

  ## The decision, made once — as a census rather than a sentence

  describe "SOURCE CENSUS — every suspended refusal in router.ex is wired" do
    test "the refusal population is exactly #{@refusal_site_count} clause heads" do
      lines = router_code_lines()

      found =
        for {regex, what} <- @refusal_clause_heads,
            line <- lines,
            Regex.match?(regex, line),
            do: what

      assert length(found) == @refusal_site_count,
             """
             Found #{length(found)} suspended-refusal clause heads in router.ex, expected #{@refusal_site_count}:

                 #{inspect(Enum.frequencies(found), pretty: true)}

             A NEW refusal site reds here on purpose: cch-w59-bl ruled the trace ONCE for all of
             them, so a new refusal has to join the ruling (wire `audit_suspended_refusal/4`
             and bump this count) rather than quietly shipping an untraced eleventh route.
             A DROP reds too — that would mean a refusal was deleted, which is a loosening.
             """
    end

    test "every refusal clause head is followed by the trace within its own clause" do
      lines = router_code_lines()
      indexed = Enum.with_index(lines)

      unwired =
        for {regex, what} <- @refusal_clause_heads,
            {line, i} <- indexed,
            Regex.match?(regex, line),
            body = Enum.slice(lines, (i + 1)..(i + 4)),
            not Enum.any?(body, &String.contains?(&1, "audit_suspended_refusal(")),
            do: {what, String.trim(line)}

      assert unwired == [],
             """
             These suspended-refusal clauses refuse WITHOUT leaving a trace:

                 #{inspect(unwired, pretty: true)}

             That is the exact defect cch-w59-bl closed: the plane knows a fact (someone tried
             to act on a suspended box) and tells nobody. Pipe the clause through
             `audit_suspended_refusal(conn, team, bp, "<route>")`, or — if this path genuinely
             must opt out — say why in a comment and exempt it here BY NAME.
             """
    end

    test "the trace verb is DECLARED in the closed audit vocabulary" do
      # Without this, every call site above would raise a changeset error at
      # runtime and the register would stay empty while the code looked wired.
      assert @refusal_action in BarkparkCloud.Accounts.AuditEvent.actions()
    end

    test "there are NO opt-outs today — the exemption list is empty and stated" do
      # Stated as a test rather than a comment so the next slice cannot add a
      # silent one: the criterion says opted-out paths must say why, and today
      # zero paths opt out. Ten refusal sites, ten traces.
      exempt = []

      assert exempt == [],
             "An opted-out suspended refusal must be named here WITH its reason, " <>
               "not left as an absence in the census above."
    end
  end
end
