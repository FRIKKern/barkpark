defmodule BarkparkCloud.BillingClientMirrorTest do
  @moduledoc """
  cch-w49-s3 — THE CROSS-LAYER MIRROR GUARD.

  The Cloud console re-types a server-owned value as fact: `app.js`'s
  `PLAN_CATALOG` carries `instances: 1 / 3 / 10`, the same per-plan managed-
  instance ceiling `BarkparkCloud.Billing` actually enforces. Until this guard,
  nothing connected the two — the console could promise a ceiling the server
  refuses, and every existing test on both sides would stay green.

  BOTH SIDES ARE READ BY RUNNING, deliberately:

    * SERVER — `Billing.limits/0` is CALLED from this booted test BEAM, so what
      is compared is the value the enforcement path itself resolves.
    * CLIENT — `priv/static/__preview__/__plan_catalog_dump.mjs` evaluates the
      SHIPPED `app.js` in a node:vm sandbox and prints `__bpTestHook.planCatalog`
      as JSON; this test spawns it with `System.cmd/3`.

  There is NO regex and NO `File.read!` over `app.js` source text anywhere in
  this file. A source scan is not a pin: it passes a refactor that keeps the
  bytes and changes the value, and it fails a reformat that changes nothing.

  ── SCOPE. Quote this guard's green for exactly this much, and no more ──────

    1. It compares COMMITTED DEFAULTS. `config/runtime.exs`'s `LIMIT_*` seam
       lives inside `if config_env() == :prod`, so a production override is
       structurally invisible here — that seam is prod-only and this guard can
       never see it. It is stronger than that sounds only because
       `cloud/docker-compose.yml` passes NO `LIMIT_*` at all today, so the
       committed default IS what runs; one line in compose changes that, and
       this guard would not notice.
    2. It covers ONLY the `instances` numeral. Price is structurally
       uncoverable — no price amount exists server-side at all (pinned by the
       SCOPE test below). `trial_days` is a separate row and not mirrored here.
    3. It pins the CONSTANT, not the render. Whether the console ever PRINTS a
       ceiling to a user is a different question, owned by cch-w49-s1's
       absent-arm assertion over the rendered bytes in `__preview__/smoke.mjs`
       — which, as of that slice, requires the answer to be "never". The two
       are complements: `PLAN_CATALOG.instances` survives as the client half of
       THIS mirror and reaches no DOM.

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

  # The PINNED tier set. Declared by NEITHER side (see the moduledoc).
  @pinned_plans ~w(free supporter support_plus)

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

  test "COMMITTED DEFAULTS: every console tier's instance ceiling equals the server's configured limit (no prod LIMIT_* override is visible here)" do
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
end
