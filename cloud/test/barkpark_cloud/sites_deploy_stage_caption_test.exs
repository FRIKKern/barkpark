defmodule BarkparkCloud.SitesDeployStageCaptionTest do
  @moduledoc """
  cch-w27-s2 — A DEPLOY THAT FAILED TOLD THE RAIL ONE CAUSE AND THE ROW ANOTHER,
  AND THE SSE CHANNEL SHIPPED THE UNREDACTED BYTES.

  `Sites.Deploy.fail/2` writes the IDENTICAL reason to `failure_reason` and to
  `detail`, and the six-stage rail is seeded from the failed stage's console
  `detail`. `Web.Router.deployment_json/1` humanized only `failure_reason`, so ONE
  string reached a person as TWO different causes seconds apart: the
  `.deploy-rail-fail` caption they were watching said `FATAL: 401 Unauthorized …`
  while the settled row that replaced it said "The hosting provider rejected our
  credentials." Two of the three real shapes share no word at all.

  And `broadcast_stage/2` shipped `stage.detail` RAW onto the
  `site.deploy.stage` SSE channel, which `Events.broadcast/3` forwards verbatim —
  so the HTTP console entry redacted a bearer token while the SSE frame for the
  SAME bytes carried it live. No leak to a screen is claimed or proven here; this
  is a secret-BOUNDARY hole, and it is booked as one.

  Both are closed by ONE fold, `Sites.Deploy.stage_caption/2`, applied at all
  three display boundaries (the SSE payload, `deployment_json/1`'s `console`,
  `site_deployment_json/3`'s `stages`). The two arms are INDEPENDENT: reverting
  the `failed` arm reds the parity tests alone, reverting the other arm reds the
  redaction tests alone.

  ## The corpus is DERIVED, never hand-authored (standing test, clause 4)

  Both strings wave 26 committed for this rail (`RAIL_FAIL_KIND_DETAIL`,
  `RAIL_FAIL_CRUEL_DETAIL`) pass through `FailureCopy.humanize/1` UNCHANGED — so
  a rail-vs-row guard built on them agrees for the wrong reason and is green by
  construction. `derived_classifying_detail/0` below reads the producer
  (`build_failure_reason()`'s FATAL arm in `deploy/site-deploy.sh`) out of the
  shell at test time and cross-checks it against the fixture committed in
  `scenarios.mjs`, so neither end can drift without this file going red.
  """
  use BarkparkCloud.DataCase, async: true

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Events, FailureCopy, Registry}
  alias BarkparkCloud.Registry.{Deployment, Vault}
  alias BarkparkCloud.Sites
  alias BarkparkCloud.Sites.FakeBoxRelay
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"
  @instance_url "https://acme.barkpark.cloud"

  # A credential shape the scrub's Bearer clause owns, with a value no
  # `@prose_value` stop-word can be — see `failure_copy.ex`'s pattern table.
  @live_token "sk-live-9Xq2LmT4vB7nR1zC8kW5"

  ## ---------------------------------------------------------------------------
  ## THE DERIVED CORPUS
  ## ---------------------------------------------------------------------------

  defp repo_file!(rel) do
    path = Path.expand(rel, File.cwd!())
    File.read!(path)
  end

  # `build_failure_reason()` (deploy/site-deploy.sh:1939, and its byte-identical
  # node twin) tries `grep -a 'FATAL' <build-log> | tail -1` FIRST. The FATAL line
  # the script's own header documents as the real BUILD reason — and that its e2e
  # asserts onto the stage line — is read out of the shell here rather than typed.
  defp producer_fatal_line do
    shell = repo_file!("../deploy/site-deploy.sh")

    [[_, line]] =
      Regex.scan(~r/echo "(FATAL: 401 Unauthorized[^"]*)" >&2/, shell)

    line
  end

  # emit()'s normalisation (deploy/lib/site-deploy-common.sh:55) in Elixir:
  # tabs/newlines/quotes → space, squeeze runs, trim, cut. The same fold
  # `railEmitDetail()` applies in scenarios.mjs.
  defp emit_detail(stem, cut \\ 240) do
    stem
    |> String.replace(~r/[\n\r\t"]/, " ")
    |> String.replace(~r/ +/, " ")
    |> String.trim()
    |> String.slice(0, cut)
  end

  # The string literals of one `export const NAME = …;` in scenarios.mjs,
  # concatenated — the JS side's committed fixture, read rather than restated.
  defp scenarios_const(name) do
    js = repo_file!("priv/static/__preview__/scenarios.mjs")
    [[_, body]] = Regex.scan(~r/#{name} =(.*?);\n/s, js)

    body
    |> then(&Regex.scan(~r/"([^"]*)"/, &1))
    |> Enum.map_join("", fn [_, lit] -> lit end)
    |> emit_detail()
  end

  defp derived_classifying_detail, do: emit_detail(producer_fatal_line())

  ## ---------------------------------------------------------------------------
  ## Fixtures
  ## ---------------------------------------------------------------------------

  defp user_with_team do
    n = System.unique_integer([:positive])
    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
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
      admin_token_encrypted: Vault.encrypt("instance-admin-token")
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

  defp setup_site do
    {user, team} = user_with_team()
    bp = live_barkpark(team)
    site = static_site(bp)
    {:ok, token} = Accounts.create_user_session_token(user)
    {site, bp, token}
  end

  # The user-facing read of ONE deployment: `site_deployment_json/3` — the only
  # response that carries `failure_reason`, the `console` the rail seeds from AND
  # the `stages` bar in the same payload, which is exactly what "one story" means.
  defp rendered_deployment(site, d, token) do
    conn = conn(:get, "/v1/sites/#{site.id}/deployments/#{d.id}")
    conn = put_req_header(conn, "authorization", "Bearer #{token}")
    conn = Router.call(conn, @opts)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["deployment"]
  end

  defp console_entry(dep, stage), do: Enum.find(dep["console"], &(&1["stage"] == stage))
  defp stage_row(dep, stage), do: Enum.find(dep["stages"], &(&1["name"] == stage))

  # A one-poll box report in which every stage is done and `overrides` names the
  # detail of the ones under test. `FakeBoxRelay.walk/2` hard-codes "<STAGE> ok",
  # so a test that needs a REMOTE capture in a non-failed stage builds its own.
  defp poll_with_details(overrides, url) do
    stages =
      Enum.map(Sites.Deploy.stages(), fn name ->
        %{
          "name" => name,
          "status" => "done",
          "detail" => Map.get(overrides, name, "#{name} ok")
        }
      end)

    {:ok, 200, %{"state" => "succeeded", "stages" => stages, "url" => url}}
  end

  defp significant_words(s) do
    s
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.filter(&(String.length(&1) > 3))
    |> MapSet.new()
  end

  ## ---------------------------------------------------------------------------
  ## THE PRECONDITION: the fixture must be able to produce the defect
  ## ---------------------------------------------------------------------------

  describe "the corpus (standing test, clause 4)" do
    test "the classifying detail is the shell producer's own FATAL line, and scenarios.mjs carries the same bytes" do
      derived = derived_classifying_detail()

      assert derived =~ "FATAL: 401 Unauthorized"

      assert derived == scenarios_const("RAIL_FAIL_CLASSIFYING_DETAIL"),
             """
             the committed preview fixture drifted from its producer:
               producer (deploy/site-deploy.sh) = #{derived}
               scenarios.mjs                    = #{scenarios_const("RAIL_FAIL_CLASSIFYING_DETAIL")}
             """
    end

    test "it CLASSIFIES — and BOTH strings wave 26 committed for this rail do not, which is why they could never have caught this" do
      derived = derived_classifying_detail()

      # The new fixture moves under humanize/1: there IS a class to disagree about.
      refute FailureCopy.humanize(derived) == FailureCopy.scrub(derived),
             "the classifying fixture does not classify — the guard below would be green by construction"

      # CO-UPDATED by task-fda5b6f19f1e06c9. This capture no longer lands on the
      # anonymous credential arm: `@site_read_token_rejected` claims it FIRST and
      # names the token and the fix. The discrimination clause above is
      # untouched — the fixture still has to CLASSIFY for this guard to mean
      # anything; only the sentence it classifies to moved.
      assert FailureCopy.humanize(derived) ==
               "This site's Barkpark read token was rejected, so the build couldn't fetch its content. Mint a fresh read token for the site in Barkpark, save it on the site, then deploy the site again."

      # task-877bfc465162e104 WIRED THAT SENTENCE INTO A SCENARIO, so the JS side
      # now commits BOTH ends of the fold: `RAIL_FAIL_CLASSIFYING_DETAIL` (the
      # capture) and `RAIL_FAIL_CLASSIFIED_CAPTION` (what the wire delivers, and
      # what `.deploy-rail-fail` paints). The preview fixture is the ONLY place
      # the classified string is committed outside this file, and a preview that
      # renders a caption the control plane would never send is a preview that
      # certifies nothing — so it is read out of scenarios.mjs and recomputed
      # here rather than trusted.
      assert FailureCopy.humanize(derived) == scenarios_const("RAIL_FAIL_CLASSIFIED_CAPTION"),
             """
             the committed preview caption drifted from the fold that produces it:
               humanize/1 = #{FailureCopy.humanize(derived)}
               scenarios.mjs (RAIL_FAIL_CLASSIFIED_CAPTION) = #{scenarios_const("RAIL_FAIL_CLASSIFIED_CAPTION")}
             """

      # …and the wave-26 pair does NOT move. A rail-vs-row parity assertion built
      # on either one passes whether the fix exists or not.
      for name <- ~w(RAIL_FAIL_KIND_DETAIL railCruelStem) do
        fixture = scenarios_const(name)

        assert FailureCopy.humanize(fixture) == fixture,
               "#{name} classifies now — it was the green-by-construction control; re-derive this file"
      end
    end
  end

  ## ---------------------------------------------------------------------------
  ## THE PERSON BODY: one failure, one cause, on every surface
  ## ---------------------------------------------------------------------------

  describe "cch-w27-s2: the rail and the row tell ONE story" do
    test "a BUILD that dies on the producer's FATAL line names ONE cause on the SSE rail, the console seed, the stage bar and the row" do
      {site, bp, token} = setup_site()
      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      raw = derived_classifying_detail()
      class = FailureCopy.humanize(raw)

      :ok = Events.subscribe(site.team_id)
      FakeBoxRelay.program(polls: [FakeBoxRelay.failed_at("BUILD", raw)])

      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      # 1. THE LIVE RAIL. `app.js` `recordDeployStage` takes `payload.detail`
      #    verbatim into the ledger, and `renderDeployRail` paints the failed
      #    stage's ledger detail as `.deploy-rail-fail`. This frame IS the caption.
      assert_receive {:bpcloud_event,
                      %{
                        type: "site.deploy.stage",
                        payload: %{stage: "BUILD", status: "failed", detail: rail_caption}
                      }}

      assert rail_caption == class

      dep = rendered_deployment(site, d, token)

      # 2. THE ROW a person reads seconds later, when the rail unmounts.
      assert dep["failure_reason"] == class

      # 3. THE CONSOLE SEED — `deployRailLedgerFromConsole` rebuilds the same
      #    ledger from this key on a refresh, so a reload must not re-introduce
      #    the divergence the SSE frame just avoided.
      assert console_entry(dep, "BUILD")["detail"] == class

      # 4. THE STAGE BAR the CLI streams.
      assert stage_row(dep, "BUILD")["detail"] == class
    end

    test "the divergence was real — and the class now names the SAME credential the raw names" do
      {site, bp, token} = setup_site()
      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      raw = derived_classifying_detail()

      FakeBoxRelay.program(polls: [FakeBoxRelay.failed_at("BUILD", raw)])
      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      stored = Repo.get(Deployment, d.id)
      stored_entry = Enum.find(stored.console, &(&1["stage"] == "BUILD"))

      # The DB keeps the raw bytes — this fix is a DISPLAY fold, not a data
      # rewrite; ops recovery and the logs are untouched.
      assert stored_entry["detail"] == raw
      assert stored.failure_reason == raw

      dep = rendered_deployment(site, d, token)

      # RE-POINTED by task-fda5b6f19f1e06c9, and the inversion is the POINT.
      # Wave 27 measured the contradiction as DISJOINTNESS: the class named a
      # hosting provider the raw capture never mentions, so sharing no word was
      # exactly the defect. The site-token clause makes the class name the SAME
      # credential the raw names, so AGREEMENT is now the guard, and a class that
      # went back to sharing nothing would be naming a different subject again.
      class_words = significant_words(dep["failure_reason"])

      assert MapSet.subset?(MapSet.new(["read", "token"]), class_words),
             "the class stopped naming the credential the raw capture names — re-derive the corpus"

      refute MapSet.disjoint?(significant_words(raw), class_words),
             "the class shares no word with the raw capture — it is naming a different subject again"

      # …and it is still a CLASS, not the raw echoed back: the fold still folds.
      refute dep["failure_reason"] == raw
    end

    test "the raw capture is NOT destroyed — it survives verbatim in the console LINE the build console prints" do
      {site, bp, token} = setup_site()
      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      raw = derived_classifying_detail()

      FakeBoxRelay.program(polls: [FakeBoxRelay.failed_at("BUILD", raw)])
      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      dep = rendered_deployment(site, d, token)
      entry = console_entry(dep, "BUILD")

      # `deployConsoleHtml` renders `line` and nothing else; the console is open
      # by default while a deploy is active, i.e. exactly while the rail is on
      # screen. Charter D310: the class goes where a person looks first, the
      # capture stays one element down — both, never either.
      assert entry["line"] =~ raw
      refute entry["line"] == entry["detail"]
    end

    test "a detail that does NOT classify still reaches the rail verbatim — the fold names a cause, it never invents one" do
      {site, bp, token} = setup_site()
      {:ok, d} = Sites.Deploy.enqueue(site, bp)
      ordinary = scenarios_const("RAIL_FAIL_KIND_DETAIL")

      :ok = Events.subscribe(site.team_id)
      FakeBoxRelay.program(polls: [FakeBoxRelay.failed_at("HEALTH", ordinary)])

      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      assert_receive {:bpcloud_event,
                      %{
                        type: "site.deploy.stage",
                        payload: %{stage: "HEALTH", status: "failed", detail: caption}
                      }}

      assert caption == ordinary

      dep = rendered_deployment(site, d, token)
      assert console_entry(dep, "HEALTH")["detail"] == ordinary
      assert dep["failure_reason"] == ordinary
    end
  end

  ## ---------------------------------------------------------------------------
  ## THE SECRET BOUNDARY: booked as hygiene, not as a person body
  ## ---------------------------------------------------------------------------

  describe "cch-w27-s2: the SSE channel stops bypassing the secret scrub" do
    test "a token-bearing detail on a RUNNING stage is redacted in the SSE frame, exactly as it already was over HTTP" do
      {site, bp, token} = setup_site()
      {:ok, d} = Sites.Deploy.enqueue(site, bp)

      capture =
        "pushing release to the box failed once and retried: " <>
          "curl -H 'Authorization: Bearer #{@live_token}' https://acme.barkpark.cloud/v1/site-deploy"

      :ok = Events.subscribe(site.team_id)

      FakeBoxRelay.program(
        polls: [
          poll_with_details(%{"STAGE" => capture}, "#{@instance_url}/sites/#{site.slug}/")
        ]
      )

      assert {:ok, :live} = Sites.Deploy.run(d.id)

      assert_receive {:bpcloud_event,
                      %{
                        type: "site.deploy.stage",
                        payload: %{stage: "STAGE", status: "done", detail: pushed}
                      }}

      refute pushed =~ @live_token,
             "the SSE frame carried a live credential the HTTP twin of the same bytes redacts"

      assert pushed =~ "[redacted]"

      # BOTH channels, one payload of bytes: the HTTP boundary agrees, and the DB
      # still holds the raw capture for ops.
      dep = rendered_deployment(site, d, token)
      entry = console_entry(dep, "STAGE")
      refute entry["detail"] =~ @live_token
      refute entry["line"] =~ @live_token

      assert Enum.find(Repo.get(Deployment, d.id).console, &(&1["stage"] == "STAGE"))["detail"] =~
               @live_token
    end

    test "a token-bearing detail on a FAILED stage is redacted too — classification cannot open a hole the scrub closed" do
      {site, bp, _token} = setup_site()
      {:ok, d} = Sites.Deploy.enqueue(site, bp)

      capture = "boot probe refused: Authorization: Bearer #{@live_token}"

      :ok = Events.subscribe(site.team_id)
      FakeBoxRelay.program(polls: [FakeBoxRelay.failed_at("HEALTH", capture)])

      assert {:ok, :failed} = Sites.Deploy.run(d.id)

      assert_receive {:bpcloud_event,
                      %{
                        type: "site.deploy.stage",
                        payload: %{stage: "HEALTH", status: "failed", detail: caption}
                      }}

      refute caption =~ @live_token
      assert caption =~ "[redacted]"
    end
  end
end
