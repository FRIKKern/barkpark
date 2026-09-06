defmodule BarkparkCloud.Web.RouterSitesLastDeploymentCauseTest do
  @moduledoc """
  THE FLEET LIST MUST BE ABLE TO SAY WHY.

  `GET /v1/sites` embedded `last_deployment` as EXACTLY
  `{status, inserted_at, updated_at, trigger}` — so the one surface that shows
  every site at once, and therefore the only place a person notices several
  sites failing, could say THAT a deploy failed and never WHY. The reason was
  one endpoint away (`GET /v1/sites/:id/deployments` already projects a
  humanized `failure_reason` and a computed `failure_class`) and the summary
  surface dropped it.

  Four things are pinned here, and each is a way the fix could be wrong:

    1. THE CAUSE ARRIVES THROUGH THE LIST ROUTE. Every assertion below reads the
       LIST response. Never `bp` — the CLI's typed Go struct drops fields the API
       returns and has already produced one confident, WRONG finding on exactly
       this question.

    2. THE EMBED'S QUERY SELECTS WHAT THE CLASSIFIER READS.
       `DeployLedger.classify/1` reads `status`, `stage` AND the RAW
       `failure_reason`. A select carrying a subset classifies EVERY row
       `UNCLASSIFIED` while looking like it works — so the fixture carries TWO
       failed sites with DIFFERENT known classes, one reached through the reason
       alone (`BOX_BUSY_409`) and one that is unreachable without `stage`
       (`DOC_ID_EMPTY`, whose arm is `stage == "HEALTH" and …`). Drop either
       column from the select and this file reds.

    3. A SUCCESSFUL LAST DEPLOYMENT IS UNCHANGED. A `live` row renders explicit
       nulls on both new keys, so the list cannot pass by making every row carry
       a reason.

    4. NO SECRET WIDENS ITS AUDIENCE. A list is a WIDER audience than a per-site
       read. The refusal fixture's raw capture carries a colourised
       `api_key=…` — the exact `scrub`-blind shape (a CSI run parks an
       alphanumeric immediately left of the key) that `FailureCopy.humanize/1`
       defeats by stripping ANSI BEFORE redacting. The embed's string is asserted
       BYTE-IDENTICAL to the per-site route's, which is the strongest available
       statement that both surfaces share one boundary, and there is deliberately
       no `failure_reason_raw` on the list.

  The tenancy scope of `GET /v1/sites` is asserted UNCHANGED beside all of it:
  another team's failed site does not join the list because the list learned to
  name causes.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # A live credential, colourised. `\e[31m` ends in `m` — an ALPHANUMERIC
  # immediately left of `api_key`, which is what blinds the scrub's key clause
  # (its left edge is `(?<![A-Za-z0-9])`) until the ANSI is stripped first.
  @secret "SUPERSECRET0abcdefgh12345"
  @refusal_raw "the instance refused the deploy (HTTP 409): already_running " <>
                 "\e[31mapi_key=#{@secret}\e[0m"

  ## Fixtures

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp site_fixture(team, slug) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, site} = Registry.create_site(bp, %{name: "S #{n}", slug: slug})
    site
  end

  # A settled PRODUCTION deployment in whatever terminal state the caller names.
  defp deployment_fixture(site, attrs) do
    {:ok, d} = Registry.create_deployment(site, %{git_ref: "main", trigger: "manual"})

    d |> Ecto.Changeset.change(attrs) |> Repo.update!()
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

  defp list_rows(token) do
    conn = call(:get, "/v1/sites", token)
    assert conn.status == 200
    {conn, Map.new(json_body(conn)["sites"], fn r -> {r["slug"], r} end)}
  end

  describe "GET /v1/sites last_deployment carries the CAUSE" do
    setup do
      {user, team} = user_with_team()

      refused = site_fixture(team, "refused")
      health = site_fixture(team, "health")
      shipped = site_fixture(team, "shipped")

      deployment_fixture(refused, %{
        status: "failed",
        stage: "DEPLOY",
        failure_reason: @refusal_raw
      })

      deployment_fixture(health, %{
        status: "failed",
        stage: "HEALTH",
        failure_reason: "the bp-doc-id marker is empty"
      })

      deployment_fixture(shipped, %{status: "live"})

      %{token: login_token(user), team: team, refused: refused}
    end

    # C1 + C2, the reason arm: a KNOWN class reaches a reader through the LIST.
    test "a failed row names its class and its humanized reason on the list", %{token: token} do
      {_conn, rows} = list_rows(token)

      last = rows["refused"]["last_deployment"]

      # The fact, unchanged.
      assert last["status"] == "failed"
      assert last["trigger"] == "manual"
      assert last["inserted_at"]
      assert last["updated_at"]

      # The cause. `UNCLASSIFIED` here would be the silent subset-select bug —
      # the row would still look fine.
      assert last["failure_class"] == "BOX_BUSY_409"
      refute last["failure_class"] == "UNCLASSIFIED"
      assert last["failure_reason"] =~ "the instance refused the deploy (HTTP 409)"
    end

    # C2, the STAGE arm: a class no reason alone can reach. `DOC_ID_EMPTY`'s
    # only arm is `stage == "HEALTH" and …`, so a select that drops `stage`
    # answers `UNCLASSIFIED` here while the test above still passes.
    test "a class that needs `stage` is classified, not UNCLASSIFIED", %{token: token} do
      {_conn, rows} = list_rows(token)

      assert rows["health"]["last_deployment"]["failure_class"] == "DOC_ID_EMPTY"
    end

    # C3, the negative direction: the fix must not make every row carry a cause.
    test "a live last deployment renders explicit nulls, not an invented cause", %{token: token} do
      {_conn, rows} = list_rows(token)

      last = rows["shipped"]["last_deployment"]

      assert last["status"] == "live"
      assert Map.has_key?(last, "failure_class")
      assert last["failure_class"] == nil
      assert Map.has_key?(last, "failure_reason")
      assert last["failure_reason"] == nil
    end

    # C4: the SAME humanize/scrub boundary the per-site route uses. Asserted by
    # byte equality against `deployment_json/1`'s own output, plus the two
    # direct statements that make the equality mean something.
    test "the reason rides the per-site route's scrub boundary, byte for byte", %{
      token: token,
      refused: refused
    } do
      {conn, rows} = list_rows(token)

      last = rows["refused"]["last_deployment"]

      ladder = call(:get, "/v1/sites/#{refused.id}/deployments", token)
      assert ladder.status == 200
      per_site = hd(json_body(ladder)["deployments"])

      # ONE boundary, two surfaces.
      assert last["failure_reason"] == per_site["failure_reason"]
      assert last["failure_class"] == per_site["failure_class"]

      # And the boundary actually fired: the credential is redacted and the
      # terminal escapes are gone. (Under the wrong order — scrub THEN strip —
      # the CSI run blinds the key clause and this ships in cleartext.)
      assert last["failure_reason"] =~ "api_key=[redacted]"
      refute last["failure_reason"] =~ @secret
      refute last["failure_reason"] =~ "\e"

      # Non-vacuity: the stored row really does carry the secret and the ESC
      # bytes, so the assertions above are about the BOUNDARY, not the fixture.
      stored = Repo.get_by!(Deployment, site_id: refused.id)
      assert stored.failure_reason =~ @secret
      assert stored.failure_reason =~ "\e"

      # The list gets the REWRITE only — no raw twin beside it, and no build
      # internals (HONESTY LAW, charter D24) joined the embed.
      refute Map.has_key?(last, "failure_reason_raw")
      refute Map.has_key?(last, "console")
      refute Map.has_key?(last, "build_log_url")
      refute Map.has_key?(last, "content_rev")

      # Nothing anywhere in the whole list payload leaks it either.
      refute conn.resp_body =~ @secret
    end

    # C4, second half: the tenancy scope of GET /v1/sites is UNCHANGED.
    test "another team's failed site does not join the list", %{token: token} do
      {_other_user, other_team} = user_with_team()
      stranger = site_fixture(other_team, "stranger")

      deployment_fixture(stranger, %{
        status: "failed",
        stage: "HEALTH",
        failure_reason: "the bp-doc-id marker is empty"
      })

      {conn, rows} = list_rows(token)

      assert Enum.sort(Map.keys(rows)) == ["health", "refused", "shipped"]
      refute Map.has_key?(rows, "stranger")
      refute conn.resp_body =~ stranger.id
    end
  end
end
