defmodule BarkparkCloud.BillingClientMirrorTest do
  @moduledoc """
  cch-w49-s3 — THE CROSS-LAYER MIRROR GUARD.
  cch-prod-limit-override-seam-unmirrored — extended to WHAT ACTUALLY RUNS.

  The Cloud console re-types a server-owned value as fact: `app.js`'s
  `PLAN_CATALOG` carries `instances: 1 / 3 / 10`, the same per-plan managed-
  instance ceiling `BarkparkCloud.Billing` actually enforces. Until this guard,
  nothing connected the two — the console could promise a ceiling the server
  refuses, and every existing test on both sides would stay green.

  BOTH SIDES ARE READ BY RUNNING, deliberately:

    * SERVER — `Billing.limits/0` is CALLED from this booted test BEAM, so what
      is compared is the value the enforcement path itself resolves. And
      `Billing.PlanLimits.resolve/0` is called too, which is the function
      `config/runtime.exs` installs those limits FROM in prod.
    * CLIENT — `priv/static/__preview__/__plan_catalog_dump.mjs` evaluates the
      SHIPPED `app.js` in a node:vm sandbox and prints `__bpTestHook.planCatalog`
      as JSON; this test spawns it with `System.cmd/3`.

  There is NO regex and NO `File.read!` over `app.js` source text anywhere in
  this file. A source scan is not a pin: it passes a refactor that keeps the
  bytes and changes the value, and it fails a reformat that changes nothing.
  (`docker-compose.yml` IS read as text, once — but only for a census of env var
  NAMES, never for a value. See THE SEAM CENSUS below.)

  ── THE HOLE THIS GUARD USED TO HAVE, AND HOW IT IS CLOSED ─────────────────

  This guard shipped declaring, in writing, that it compared COMMITTED DEFAULTS
  only — that `config/runtime.exs`'s `LIMIT_*` seam lives inside
  `if config_env() == :prod` and was therefore structurally invisible here. It
  called that acceptable for ONE stated reason: `cloud/docker-compose.yml`
  passed NO `LIMIT_*` at all, so the committed default WAS what ran.

  **That premise is false.** Commit `2c25288479` widened the compose environment
  block; `cloud/docker-compose.yml` now passes all four `LIMIT_*` names through
  to the container. The latent defect became live: an operator setting one in
  `cloud/.env` moves the server's real ceiling while the console's constant
  stays put, and nothing red.

  So the rule moved out of `runtime.exs` and into
  `BarkparkCloud.Billing.PlanLimits`, where it is CALLABLE. This guard now
  compares what actually runs, three ways:

    1. THE LIVE ARM — `PlanLimits.resolve/0` reads the real process
       environment. If a `LIMIT_*` is set wherever this guard runs, the
       comparison uses the OVERRIDDEN ceiling and reds against the console.
    2. THE OVERRIDE ARM — for each console tier, a SYNTHETIC environment that
       moves that tier's ceiling must make the mirror FAIL. This is the
       scenario that used to pass silently, asserted directly.
    3. THE SEAM CENSUS — the `LIMIT_*` names compose passes through must be
       exactly the ones `PlanLimits` models. This is what stops the guard going
       blind the same way again: the hole opened when an env seam appeared that
       the guard did not know about, and that exact edit now reds here.

  ── SCOPE. Quote this guard's green for exactly this much, and no more ──────

    1. It covers ONLY the `instances` numeral. Price is structurally
       uncoverable — no price amount exists server-side at all (pinned by the
       SCOPE test below). `trial_days` is a separate row and not mirrored here.
    2. It pins the CONSTANT, not the render. Whether the console ever PRINTS a
       ceiling to a user is a different question, owned by cch-w49-s1's
       absent-arm assertion over the rendered bytes in `__preview__/smoke.mjs`
       — which, as of that slice, requires the answer to be "never". The two
       are complements: `PLAN_CATALOG.instances` survives as the client half of
       THIS mirror and reaches no DOM.
    3. It cannot read an operator's `cloud/.env` — no CI job can. What it CAN do
       is red on the two things that are visible: a `LIMIT_*` present in the
       environment the guard runs in, and a `LIMIT_*` seam in compose that the
       server-side resolver does not model. An operator who sets a value in a
       file nobody commits still gets no CI signal; closing THAT needs the
       console to stop carrying the constant and read the ceiling from the
       server (the row's option (b)), which is a console change and not this
       slice.

  ── WHY THE PINNED KEY SET IS DECLARED BY NEITHER SIDE ─────────────────────

  `@pinned_plans` is written HERE, not derived from the client or the server.
  That is the whole reason this guard can lose in the DELETE direction: a guard
  that compares only the keys the client happens to declare goes GREEN when a
  tier — or a tier's `instances` key — is deleted, because the comparison
  quietly shrinks to nothing. Deleting a tier, deleting the key, or deleting the
  comparison itself all red here.
  """

  # async: false — the @default_limits assertion below temporarily clears this
  # app's :limits config to reach the fallback, and ExUnit runs sync cases alone.
  use ExUnit.Case, async: false

  alias BarkparkCloud.Billing
  alias BarkparkCloud.Billing.PlanLimits

  # The PINNED tier set the CONSOLE declares. Declared by NEITHER side (see the
  # moduledoc).
  @pinned_plans ~w(free supporter support_plus)

  # The PINNED override seam. Declared here for the same reason @pinned_plans is:
  # derived from `PlanLimits` alone, a deletion would shrink the census to
  # nothing and go green.
  @pinned_env_names ~w(LIMIT_FREE LIMIT_TRIAL LIMIT_SUPPORTER LIMIT_SUPPORT_PLUS)

  # A seam whose plan the console carries NO tier for. `trial` is the signup
  # grant; there is no trial card in `PLAN_CATALOG`, so moving `LIMIT_TRIAL`
  # cannot make the console lie. Pinned so the accounting stays honest: if the
  # console ever grows a trial tier, or a mirrored tier loses its card, the
  # coverage test below reds instead of the mirror quietly covering less.
  @unmirrored_seam_plans ~w(trial)

  defp client_catalog! do
    node = System.find_executable("node")

    # A guard that cannot run must RED, never skip. `.github/workflows/cloud.yml`
    # installs node with actions/setup-node@v4 rather than betting on the image.
    assert node,
           "node is not on PATH — the cross-layer mirror guard cannot read the client constant"

    script =
      [__DIR__, "..", "..", "priv", "static", "__preview__", "__plan_catalog_dump.mjs"]
      |> Path.join()
      |> Path.expand()

    assert File.exists?(script),
           "the client dump script is missing at #{script} — the client side cannot be read"

    {out, status} = System.cmd(node, [script], stderr_to_stdout: true)

    assert status == 0,
           "the client dump failed (exit #{status}) — the console's plan catalog could not be read by running: #{out}"

    Jason.decode!(out)
  end

  # The instrument REPORTS what it compared, and the META test below pins the
  # report itself — so deleting one side of the comparison shrinks the report
  # and reds by name, instead of silently comparing nothing.
  defp mirror_report do
    catalog = client_catalog!()
    server = Billing.limits()

    Enum.map(catalog, fn tier ->
      plan = Map.fetch!(tier, "plan")

      %{
        plan: plan,
        client_instances: Map.get(tier, "instances"),
        server_limit: Map.get(server, plan)
      }
    end)
  end

  # THE SAME MIRROR, against what the server would ACTUALLY enforce for `env` —
  # `PlanLimits.resolve/1` being the function `config/runtime.exs` installs the
  # prod limits from. Carries `:source` so the report shows whether each row's
  # ceiling came from the environment or from the committed default; the META
  # test pins that field, so dropping the environment arm shrinks the report.
  defp effective_report(env) do
    catalog = client_catalog!()
    effective = PlanLimits.resolve(env)
    overridden = PlanLimits.overridden(env)

    Enum.map(catalog, fn tier ->
      plan = Map.fetch!(tier, "plan")

      %{
        plan: plan,
        client_instances: Map.get(tier, "instances"),
        effective_limit: Map.get(effective, plan),
        source: if(plan in overridden, do: :env, else: :default)
      }
    end)
  end

  # THE LIVE ARM, and deliberately ARITY ZERO. `PlanLimits.resolve/0` reads the
  # real process environment; there is no parameter here for a synthetic map to
  # be threaded through, so the arm cannot be quietly pointed at `%{}` and go
  # back to comparing committed defaults. (Measured: when the live test called
  # `effective_report(env)` with an injectable argument, swapping that argument
  # for `%{}` left all 11 tests GREEN. The env-planting META test below is the
  # second lock on the same door.)
  defp live_report do
    catalog = client_catalog!()
    effective = PlanLimits.resolve()
    overridden = PlanLimits.overridden()

    Enum.map(catalog, fn tier ->
      plan = Map.fetch!(tier, "plan")

      %{
        plan: plan,
        client_instances: Map.get(tier, "instances"),
        effective_limit: Map.get(effective, plan),
        source: if(plan in overridden, do: :env, else: :default)
      }
    end)
  end

  # Billing.limits/0 with this app's configured :limits REMOVED, i.e. the
  # @default_limits fallback — the one value the mirror above can never reach,
  # because config/config.exs configures :limits in EVERY env and shadows the
  # module attribute.
  defp fallback_limits do
    previous = Application.get_env(:barkpark_cloud, Billing, [])
    Application.put_env(:barkpark_cloud, Billing, Keyword.delete(previous, :limits))

    try do
      Billing.limits()
    after
      Application.put_env(:barkpark_cloud, Billing, previous)
    end
  end

  # The `LIMIT_*` names cloud/docker-compose.yml passes through to the control
  # plane container — read from the `x-control-plane` anchor's environment list,
  # the same block scripts/env-census.py scopes to. NAMES ONLY: this never reads
  # a value, so it is a census, not the source scan the moduledoc forbids.
  defp compose_limit_names do
    path =
      [__DIR__, "..", "..", "docker-compose.yml"] |> Path.join() |> Path.expand()

    assert File.exists?(path),
           "cloud/docker-compose.yml is missing at #{path} — the seam census cannot be taken"

    lines = path |> File.read!() |> String.split("\n")

    start =
      Enum.find_index(lines, &String.starts_with?(&1, "x-control-plane:")) ||
        flunk(
          "cloud/docker-compose.yml has no `x-control-plane:` anchor — the census lost its block"
        )

    block =
      lines
      |> Enum.drop(start + 1)
      |> Enum.take_while(fn line -> not Regex.match?(~r/^[A-Za-z_-]/, line) end)

    names =
      block
      |> Enum.map(&Regex.run(~r/^\s*-\s*(LIMIT_[A-Z0-9_]+)/, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn [_, name] -> name end)

    # Non-vacuity: an anchor that slid, or a block scan that silently matched
    # nothing, must not read as "compose declares no seams".
    refute names == [],
           "the compose scan found NO LIMIT_* under x-control-plane — the block scan went blind, which is not the same as compose passing none"

    names
  end

  test "COMMITTED DEFAULTS: every console tier's instance ceiling equals the server's configured limit" do
    for row <- mirror_report() do
      refute is_nil(row.server_limit),
             "the console declares plan #{row.plan}, which the server has no ceiling for at all"

      assert row.client_instances == row.server_limit,
             "plan #{row.plan}: client says #{inspect(row.client_instances)}, server says #{inspect(row.server_limit)}"
    end
  end

  test "the console declares exactly the pinned tier set, each carrying an integer `instances` — deleting a tier or the key cannot shrink the comparison" do
    report = mirror_report()

    assert report |> Enum.map(& &1.plan) |> Enum.sort() == Enum.sort(@pinned_plans),
           "the console's tier set moved: #{inspect(Enum.map(report, & &1.plan))} vs pinned #{inspect(@pinned_plans)}"

    for row <- report do
      assert is_integer(row.client_instances),
             "plan #{row.plan} carries no integer `instances` on the client (got #{inspect(row.client_instances)})"
    end
  end

  test "META: the mirror actually compared BOTH sides of every pinned plan" do
    report = mirror_report()

    assert length(report) == length(@pinned_plans),
           "the mirror reported #{length(report)} rows for #{length(@pinned_plans)} pinned plans"

    for plan <- @pinned_plans do
      row = Enum.find(report, &(&1.plan == plan))
      assert row, "the mirror never reported plan #{plan}"

      assert Map.has_key?(row, :client_instances) and Map.has_key?(row, :server_limit),
             "the mirror reported plan #{plan} without both sides — the comparison itself was removed"
    end
  end

  test "THE FALLBACK IS MIRRORED TOO: Billing's @default_limits agrees with the configured map and with the console" do
    # WHY THIS EXISTS. config/config.exs configures :limits in every env, so it
    # shadows @default_limits and `Billing.limits/0` never reaches the fallback
    # under test — mutating @default_limits leaves the mirror above GREEN
    # (measured). This closes that hole from the other end: the fallback is read
    # by running, with the config cleared.
    fallback = fallback_limits()
    configured = Billing.limits()

    assert fallback == configured,
           "Billing's @default_limits has drifted from config/config.exs's :limits — fallback #{inspect(fallback)} vs configured #{inspect(configured)}"

    for row <- mirror_report() do
      assert row.client_instances == Map.get(fallback, row.plan),
             "plan #{row.plan}: client says #{inspect(row.client_instances)}, @default_limits says #{inspect(Map.get(fallback, row.plan))}"
    end
  end

  test "SCOPE: price is structurally uncoverable — the server holds no price amount at all, only integer ceilings" do
    # This test is deliberately SERVER-ONLY, and says why: there is nothing on
    # the client for it to compare against, because there is nothing on the
    # server to compare TO. `Billing.limits/0` holds integer ceilings and
    # nothing else; `STRIPE_PRICE_*` are Stripe price IDENTIFIERS, not amounts.
    # So no mirror over a price can ever exist, in either direction.
    #
    # It used to also assert that each client tier carried a "$…" display
    # string. That clause was REMOVED by review: it pinned the very fabrication
    # cch-w49-s1 deletes (a hand-typed $0/$69/$499 rendered as fact), so it
    # would have red the moment that slice merged and, worse, it read as this
    # guard endorsing the numeral. Whether the console carries a price is now
    # owned end-to-end by cch-w49-s1's absent-arm assertion over the RENDERED
    # bytes in `__preview__/smoke.mjs`, which is the surface that matters.
    server = Billing.limits()

    assert map_size(server) > 0, "the server's limits map is empty — nothing to scope"

    assert Enum.all?(Map.values(server), &is_integer/1),
           "the server's limits map holds only integer ceilings: #{inspect(server)}"
  end

  # ── cch-prod-limit-override-seam-unmirrored ───────────────────────────────

  test "WHAT ACTUALLY RUNS: every console tier matches the ceiling the LIVE environment resolves to" do
    # THE LIVE ARM. `PlanLimits.resolve/0` reads the real process environment —
    # the same call `config/runtime.exs` makes in prod. With no LIMIT_* set this
    # equals the committed default and agrees with the test above; with one set,
    # it is the OVERRIDDEN ceiling, and this reds while the committed-defaults
    # test above stays green. That gap is the whole defect, and it is now armed.
    report = live_report()

    for row <- report do
      refute is_nil(row.effective_limit),
             "the console declares plan #{row.plan}, which the resolver produces no ceiling for at all"

      assert row.client_instances == row.effective_limit,
             "plan #{row.plan}: the console promises #{inspect(row.client_instances)} but this environment resolves the server ceiling to #{inspect(row.effective_limit)} (source: #{row.source}). A LIMIT_* override moved the server and the console constant did not follow."
    end
  end

  test "THE OVERRIDE CASE REDS: moving any mirrored tier's LIMIT_* breaks the mirror, and only for that tier" do
    # THE ROW'S WHOLE VALUE. Before this, the scenario below passed silently:
    # the server ceiling moves, the console constant does not, and the guard
    # reported 0 failures. Proven per tier, against the value the CONSOLE
    # actually carries, so it cannot go vacuous on a hard-coded numeral.
    baseline = effective_report(%{})

    for {plan, env_name, _default} <- PlanLimits.overridable(), plan in @pinned_plans do
      console =
        baseline
        |> Enum.find(&(&1.plan == plan))
        |> then(fn row ->
          assert row,
                 "the console carries no tier for #{plan} — the override case has nothing to move against"

          row.client_instances
        end)

      moved = %{env_name => Integer.to_string(console + 1)}
      report = effective_report(moved)

      row = Enum.find(report, &(&1.plan == plan))
      assert row, "the mirror stopped reporting #{plan} under an override"

      assert row.source == :env,
             "#{env_name} was set but plan #{plan} still resolved from the committed default — the override arm is not wired"

      refute row.client_instances == row.effective_limit,
             "#{env_name}=#{console + 1} moved the server ceiling for #{plan} and the mirror did NOT notice — this is exactly the silent pass cch-prod-limit-override-seam-unmirrored was filed for"

      # ...and ONLY that tier. A guard that reds on everything is not reading
      # the seam, it is broken — that would pass the assertion above for the
      # wrong reason.
      for other <- report, other.plan != plan do
        assert other.client_instances == other.effective_limit,
               "moving #{env_name} also moved plan #{other.plan} — the override is not scoped to its own tier"

        assert other.source == :default,
               "moving #{env_name} marked plan #{other.plan} as environment-sourced too"
      end
    end
  end

  test "THE SEAM CENSUS: compose passes exactly the LIMIT_* names the server-side resolver models" do
    # THE ANTI-BLINDNESS MECHANISM. This guard went blind because an override
    # seam appeared in compose that it did not model (commit 2c25288479). That
    # same edit now reds here: a LIMIT_* added to compose without being modelled
    # in PlanLimits fails, and so does one modelled but not passed through
    # (which would be a seam the operator's .env can never actually reach).
    compose = compose_limit_names() |> Enum.sort()
    modelled = PlanLimits.env_names() |> Enum.sort()

    assert compose == modelled,
           "the LIMIT_* override seam has drifted: cloud/docker-compose.yml passes #{inspect(compose)}, BarkparkCloud.Billing.PlanLimits models #{inspect(modelled)}. Every name compose passes can move the server's ceiling; a name this guard does not model is a ceiling it cannot mirror."

    assert modelled == Enum.sort(@pinned_env_names),
           "the pinned override seam moved: #{inspect(modelled)} vs pinned #{inspect(@pinned_env_names)}"

    # The resolver's own literal System.get_env/1 reads must name exactly the
    # seams it declares. That duplication exists only because
    # scripts/env-census.py fails closed on a dynamic get_env site; this is what
    # keeps it from drifting.
    assert PlanLimits.env() |> Map.keys() |> Enum.sort() == modelled,
           "PlanLimits.env/0 reads #{inspect(PlanLimits.env() |> Map.keys() |> Enum.sort())} but declares #{inspect(modelled)} — a declared seam is not actually read, or a read seam is not declared"
  end

  test "COVERAGE ACCOUNTING: every override seam is either mirrored by a console tier or listed as unmirrored, with a reason" do
    # Counting seams is not counting what the mirror SEES. There are four
    # LIMIT_* seams and three console tiers; that difference must be declared,
    # not discovered later as another silent hole.
    seam_plans = PlanLimits.overridable() |> Enum.map(fn {plan, _n, _d} -> plan end)
    catalog_plans = mirror_report() |> Enum.map(& &1.plan)

    mirrored = Enum.filter(seam_plans, &(&1 in catalog_plans))
    unmirrored = Enum.reject(seam_plans, &(&1 in catalog_plans))

    assert Enum.sort(unmirrored) == Enum.sort(@unmirrored_seam_plans),
           "the set of override seams NO console tier mirrors changed: #{inspect(Enum.sort(unmirrored))} vs declared #{inspect(Enum.sort(@unmirrored_seam_plans))}. A newly unmirrored seam is a ceiling an operator can move with nothing watching."

    assert Enum.sort(mirrored) == Enum.sort(@pinned_plans),
           "the mirrored seam set moved: #{inspect(Enum.sort(mirrored))} vs the pinned console tiers #{inspect(Enum.sort(@pinned_plans))}"

    # And the console must not carry a tier with no server-side seam at all —
    # that would be a ceiling the console states and no operator can ever move,
    # which is a different lie but still one.
    for plan <- catalog_plans do
      assert plan in seam_plans,
             "the console declares tier #{plan}, which BarkparkCloud.Billing.PlanLimits has no ceiling for"
    end
  end

  test "PARITY: the resolver's committed defaults are the same numbers config.exs configures and Billing enforces" do
    # PlanLimits is a NEW place the numerals live. Without this it would be a
    # fourth silent copy (config.exs :limits, Billing's @default_limits,
    # PlanLimits, app.js) — the exact failure mode this whole guard exists for.
    assert PlanLimits.committed_defaults() == Billing.limits(),
           "BarkparkCloud.Billing.PlanLimits' committed defaults #{inspect(PlanLimits.committed_defaults())} have drifted from the configured limits #{inspect(Billing.limits())}"

    assert PlanLimits.committed_defaults() == fallback_limits(),
           "BarkparkCloud.Billing.PlanLimits' committed defaults have drifted from Billing's @default_limits fallback"
  end

  test "META: the effective report carries BOTH sides AND the source of every row" do
    # Same shape as the META test above, for the new arm. Dropping the
    # environment arm — resolving from the committed default and calling it
    # effective — shrinks this report and reds by name.
    report = effective_report(%{"LIMIT_SUPPORTER" => "7"})

    assert length(report) == length(@pinned_plans),
           "the effective mirror reported #{length(report)} rows for #{length(@pinned_plans)} pinned plans"

    for row <- report do
      assert Map.has_key?(row, :client_instances) and Map.has_key?(row, :effective_limit),
             "the effective mirror reported plan #{row.plan} without both sides"

      assert row.source in [:env, :default],
             "the effective mirror reported plan #{row.plan} with no ceiling source"
    end

    supporter = Enum.find(report, &(&1.plan == "supporter"))

    assert supporter.effective_limit == 7,
           "LIMIT_SUPPORTER=7 did not reach the effective ceiling (got #{inspect(supporter.effective_limit)}) — the report is not reading the environment at all"

    assert supporter.source == :env
  end

  test "META: the LIVE arm reads the PROCESS environment — planting a LIMIT_* reaches it" do
    # THE NON-VACUITY LOCK ON THE LIVE ARM. Everything else about the live test
    # is identical whether it resolves the process environment or a committed
    # default, because CI sets no LIMIT_* — so on its own it could silently stop
    # reading the environment and stay green. This plants a real value and
    # requires it to come out the other end.
    #
    # `System.put_env/2` is VM-global, so the previous value is SAVED and put
    # back — never just deleted. Deleting it would erase a real LIMIT_* set by
    # whoever is running this suite, and (measured) that silently disarmed the
    # live arm above whenever the seed ran this test first: an operator override
    # went back to reporting 0 failures, which is the exact defect this file was
    # extended to catch. This case is `async: false`, and no other test in this
    # repo reads LIMIT_*.
    previous = System.get_env("LIMIT_SUPPORTER")
    System.put_env("LIMIT_SUPPORTER", "4242")

    try do
      assert PlanLimits.env()["LIMIT_SUPPORTER"] == "4242",
             "PlanLimits.env/0 did not see a LIMIT_SUPPORTER planted in the process environment — it is not reading the real environment"

      row = Enum.find(live_report(), &(&1.plan == "supporter"))

      assert row,
             "the live mirror stopped reporting the supporter tier"

      assert row.effective_limit == 4242,
             "a LIMIT_SUPPORTER planted in the PROCESS environment did not reach the live mirror (got #{inspect(row.effective_limit)}) — the live arm has gone back to resolving a committed default, which is exactly the blindness cch-prod-limit-override-seam-unmirrored closed"

      assert row.source == :env,
             "the live mirror resolved the supporter ceiling from the environment but did not report it as environment-sourced"

      refute row.client_instances == row.effective_limit,
             "the console constant somehow equals 4242 — this test can no longer tell an override from agreement"
    after
      case previous do
        nil -> System.delete_env("LIMIT_SUPPORTER")
        value -> System.put_env("LIMIT_SUPPORTER", value)
      end
    end

    # And the environment is EXACTLY as it was: a leaked plant would poison every
    # later comparison, and a wrongly-cleared real override would disarm them.
    assert PlanLimits.env()["LIMIT_SUPPORTER"] == previous,
           "this test did not restore LIMIT_SUPPORTER (expected #{inspect(previous)}, got #{inspect(PlanLimits.env()["LIMIT_SUPPORTER"])})"
  end
end
