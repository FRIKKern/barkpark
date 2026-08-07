defmodule BarkparkCloud.SoldCapabilityManifestTest do
  @moduledoc """
  cch-w50-s1 — THE SOLD-CAPABILITY MANIFEST GUARD.

  The Cloud console's plan card renders `planFeatures(tier)` as a ✓-ticked list
  directly above a button that POSTs `/v1/billing/checkout`. Those bullets are
  SOLD: a user reads them as things this control plane does. Until this guard,
  nothing connected a bullet to anything that runs — the console shipped "Daily
  backups" (zero backup workers, zero crontab rows, no wired BackupProbe, a
  remote verb shelling a `make` target that does not exist) and "Priority
  support" / "Standard support" (no route, address, inbox, SLA, docs page or
  nav link anywhere in the plane) for as long as the card existed, with every
  test on both sides green.

  This guard states one rule and can lose four ways when it is broken:

    * ADD — a bullet with no `@sold` row reds, BY BULLET TEXT.
    * BACKING (cron) — a `{:cron, Module}` signal whose crontab row or module
      is gone reds, BY SIGNAL NAME.
    * BACKING (route) — a `{:route, …}` signal whose route stops answering
      reds, BY SIGNAL NAME.
    * DELETE — an `@sold` row that no tier claims reds as a STALE PIN.

  ── BOTH SIDES ARE READ BY RUNNING ─────────────────────────────────────────

    * CLIENT — `priv/static/__preview__/__plan_features_dump.mjs` evaluates the
      SHIPPED `app.js` in a node:vm sandbox and CALLS `planFeatures(tier)` per
      catalog tier (it does not read a constant), printing
      `[{plan, bullets, note}]`; this test spawns it with `System.cmd/3` and
      REDS on any non-zero exit. There is NO regex and NO `File.read!` over
      `app.js` source text in this file.
    * SERVER — every signal resolves on THIS booted BEAM. A cron signal is
      resolved from `Application.get_env(:barkpark_cloud, Oban)[:plugins]` —
      the crontab the application itself is configured with — not by scanning
      `config/config.exs` as text. The route signal is resolved by DISPATCHING
      the route through `BarkparkCloud.Web.Router`, because `Plug.Router`
      exposes no route introspection: a route can only be proven by calling it.

  ── WHY THE ROUTE SIGNAL HAS A 200 ARM ─────────────────────────────────────

  `/v1/tls/ask` answers 404 for an unregistered host. `Plug.Router`'s
  FALLTHROUGH is also 404. So a probe that only asserts "404 for a host we did
  not register" stays GREEN with the route DELETED — it would be proving the
  fallthrough, not the gate. The discriminator is the 200 arm: the same request
  must flip 404 → 200 once `Registry.set_custom_host/2` claims the host. Both
  arms run, in that order, in one test.

  ── WHY THE SOLD SET IS PINNED HERE, DECLARED BY NEITHER SIDE ──────────────

  `@sold` is written in THIS file. That is not style — it is the only reason
  the DELETE direction can lose. An ADD-only guard iterates the bullets the
  client happens to emit, so emptying `planFeatures` shrinks the comparison to
  ZERO ITERATIONS and the guard passes vacuously (measured: charter D564).
  Because every `@sold` row must also be CLAIMED by some tier's emitted
  bullets, deleting a capability from the console reds here until the pin is
  deleted too — deliberately, so a deletion is a decision someone records
  rather than a silent shrink. This mirrors `billing_client_mirror_test.exs`'s
  `@pinned_plans`.

  ── SCOPE. Quote this guard's green for exactly this much, and no more ─────

    1. A `{:cron, Module}` signal proves TWO things: a crontab row naming that
       module is present in the app's configured Oban plugins, and the module
       LOADS. It proves NOTHING about what the worker does. A worker whose
       `perform/1` returns `:ok` without acting keeps this guard green, and so
       does a COMPOUND rename that moves the module and its crontab row
       together. This guard certifies "this capability names one signal that
       exists and runs on a schedule", never "this capability works".
    2. The `{:route, :tls_ask_gate}` signal proves the gate answers 404 → 200
       across a real registration. It proves nothing about Caddy actually
       calling it, nor about a certificate ever being issued.
    3. It reads what `planFeatures` RETURNS, not what any screen renders. That
       is deliberate: the free-owner upsell card renders in ZERO of the
       committed preview scenarios and `support_plus` appears in none, so a
       render-layer arm would be vacuous today. Hosting the guard over the
       function means no fixture can blind it. The rendered-bytes question is a
       separate, later slice.
    4. It covers the plan card's BULLETS (plus a narrow forbidden-claim pin on
       the tier NOTES, which are prose sold on the same card). Any other
       marketing sentence elsewhere in the console is out of its reach.
  """

  # async: true — every DB touch below is inside the SQL sandbox, and the
  # config reads are pure.
  use BarkparkCloud.DataCase, async: true

  import Plug.Test

  alias BarkparkCloud.{Accounts, Registry}
  alias BarkparkCloud.Web.Router

  @router_opts Router.init([])

  @password "correct-horse-battery"

  # THE PINNED SOLD SET. Declared by NEITHER side (see the moduledoc).
  #
  # Each key is a bullet the console sells; each value is the NON-EMPTY list of
  # signals that back it. A capability that can name no signal does not belong
  # on a card above a checkout button — it belongs deleted, which is what
  # cch-w50-s1 did to "Daily backups" and to the support ternary.
  @sold %{
    "Automated provisioning & updates" => [
      # config/config.exs crontab: {"*/5 * * * *", AutoupdateRolloutWorker}
      {:cron, BarkparkCloud.Workers.AutoupdateRolloutWorker},
      # config/config.exs crontab: {"17 * * * *", UpdateStatusWorker}
      {:cron, BarkparkCloud.Workers.UpdateStatusWorker}
    ],
    "Custom domains with automatic TLS" => [
      # GET /v1/tls/ask — Caddy's on-demand ACME gate, proven by dispatch.
      {:route, :tls_ask_gate}
    ]
  }

  # Claims a plan card must never make in prose either. "Daily backups" was
  # deleted from the bullets in the same commit that deleted "Priority support
  # and more capacity." from the support_plus NOTE — the note renders as
  # <p class="tier-note"> on the same card, so leaving it would have shipped
  # the identical claim one line up.
  @forbidden_note_claims ~r/backups?|priority|24\/7|\bSLA\b/i

  ## ── The client half ────────────────────────────────────────────────────

  defp client_rows! do
    node = System.find_executable("node")

    # A guard that cannot run must RED, never skip. `.github/workflows/cloud.yml`
    # installs node with actions/setup-node@v4 rather than betting on the image.
    assert node,
           "node is not on PATH — the sold-capability manifest guard cannot read the console's bullets"

    script =
      [__DIR__, "..", "..", "priv", "static", "__preview__", "__plan_features_dump.mjs"]
      |> Path.join()
      |> Path.expand()

    assert File.exists?(script),
           "the client dump script is missing at #{script} — the sold bullets cannot be read"

    {out, status} = System.cmd(node, [script], stderr_to_stdout: true)

    assert status == 0,
           "the client dump failed (exit #{status}) — the console's sold bullets could not be read by running: #{out}"

    Jason.decode!(out)
  end

  # Every DISTINCT bullet the console sells, across all tiers, with the tiers
  # that sell it — so a red can say WHERE.
  defp sold_bullets do
    rows = client_rows!()

    assert rows != [], "the client dump returned no tiers at all — there is nothing to check"

    Enum.reduce(rows, %{}, fn row, acc ->
      plan = Map.fetch!(row, "plan")

      Enum.reduce(Map.fetch!(row, "bullets"), acc, fn bullet, inner ->
        Map.update(inner, bullet, [plan], &[plan | &1])
      end)
    end)
  end

  ## ── The server half: signals resolved BY RUNNING ───────────────────────

  # The crontab the APPLICATION is configured with, read off this booted BEAM.
  # Not a scan of config/config.exs: a text scan passes when the row is moved
  # into a comment and fails on a reformat.
  defp configured_crontab do
    plugins = Application.get_env(:barkpark_cloud, Oban)[:plugins] || []

    Enum.find_value(plugins, [], fn
      {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
      _ -> nil
    end)
  end

  defp cron_workers do
    configured_crontab()
    |> Enum.map(fn
      {_schedule, worker} -> worker
      {_schedule, worker, _opts} -> worker
    end)
    |> MapSet.new()
  end

  # Resolve one signal to {:ok, detail} | {:error, why}. `ctx` carries the
  # fixtures the route arm needs, built once per test that needs it.
  defp resolve({:cron, worker}, _ctx) do
    cond do
      not MapSet.member?(cron_workers(), worker) ->
        {:error, "no crontab row schedules #{inspect(worker)} in the app's configured Oban plugins"}

      not Code.ensure_loaded?(worker) ->
        {:error, "#{inspect(worker)} is scheduled but the module does not load"}

      true ->
        {:ok, "scheduled + loadable: #{inspect(worker)}"}
    end
  end

  defp resolve({:route, :tls_ask_gate}, _ctx) do
    domain = "cch-w50-s1-#{System.unique_integer([:positive])}.barkpark.cloud"
    bp = live_barkpark()

    before = call(:get, "/v1/tls/ask?domain=#{domain}").status

    if before != 404 do
      {:error, "GET /v1/tls/ask answered #{before} for an UNREGISTERED host (expected 404)"}
    else
      case Registry.set_custom_host(bp, domain) do
        {:ok, _} ->
          after_status = call(:get, "/v1/tls/ask?domain=#{domain}").status

          if after_status == 200 do
            {:ok, "GET /v1/tls/ask flipped 404 → 200 across registration of #{domain}"}
          else
            # THE DISCRIMINATOR. Plug.Router's fallthrough is 404 too, so only
            # this arm can tell a live gate from a deleted route.
            {:error,
             "GET /v1/tls/ask answered #{after_status} for a REGISTERED host (expected 200) — " <>
               "the on-demand TLS gate is not answering, so nothing backs automatic TLS"}
          end

        other ->
          {:error, "could not register #{domain} to exercise the gate: #{inspect(other)}"}
      end
    end
  end

  ## ── Fixtures (the attach-domain test's shape) ──────────────────────────

  defp live_barkpark do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "user-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    {:ok, _} = Registry.upsert_health(bp, %{host: "203.0.113.10"})

    Registry.get_barkpark(bp.id)
  end

  defp call(method, path), do: Router.call(conn(method, path), @router_opts)

  ## ── The four directions ────────────────────────────────────────────────

  test "ADD: every bullet the console sells carries a manifest row" do
    for {bullet, plans} <- sold_bullets() do
      assert Map.has_key?(@sold, bullet),
             "the console sells #{inspect(bullet)} (tiers: #{Enum.join(Enum.sort(plans), ", ")}) " <>
               "but NOTHING in this plane is named as backing it. Either name a signal for it in " <>
               "@sold, or stop selling it — a ✓ above a checkout button is a promise."
    end
  end

  test "DELETE: every manifest row is still claimed by some tier — an emptied planFeatures reds as a stale pin" do
    # WHY THIS TEST EXISTS AT ALL. The ADD test above iterates the bullets the
    # client emits, so with planFeatures returning [] it passes at ZERO
    # iterations — vacuously green while the console sells nothing. This test
    # is the other direction, and it is only possible because @sold is pinned
    # here rather than derived from either side.
    sold = sold_bullets()

    assert map_size(@sold) > 0, "the manifest is EMPTY — an empty manifest can back nothing"

    for {bullet, signals} <- @sold do
      assert Map.has_key?(sold, bullet),
             "@sold pins #{inspect(bullet)} but NO tier sells it any more (the console emits: " <>
               "#{inspect(Map.keys(sold))}). If the capability was deleted on purpose, delete " <>
               "its pin in the same commit; if planFeatures was emptied or broke, this is the red."

      assert signals != [],
             "@sold pins #{inspect(bullet)} with NO signals — a row that names nothing backs nothing"
    end
  end

  test "BACKING: every signal behind every sold bullet resolves on this booted BEAM" do
    for {bullet, signals} <- @sold, signal <- signals do
      case resolve(signal, %{}) do
        {:ok, _detail} ->
          :ok

        {:error, why} ->
          flunk(
            "signal #{inspect(signal)} backing #{inspect(bullet)} does NOT resolve: #{why}"
          )
      end
    end
  end

  test "META: the manifest actually resolved every signal, and named the kinds it can resolve" do
    # Without this, deleting the body of resolve/2's cron clause (or the whole
    # BACKING loop) would leave a green suite that compared nothing.
    resolved =
      for {bullet, signals} <- @sold, signal <- signals do
        {:ok, detail} = resolve(signal, %{})
        {bullet, signal, detail}
      end

    assert length(resolved) == @sold |> Map.values() |> List.flatten() |> length(),
           "the manifest reported #{length(resolved)} resolutions for #{length(List.flatten(Map.values(@sold)))} signals"

    kinds = resolved |> Enum.map(fn {_b, {kind, _}, _d} -> kind end) |> Enum.uniq() |> Enum.sort()

    assert kinds == [:cron, :route],
           "the manifest resolved signal kinds #{inspect(kinds)} — both a scheduled worker and a " <>
             "dispatched route must be exercised, or one resolver is dead code"

    for {_bullet, _signal, detail} <- resolved do
      assert is_binary(detail) and detail != "", "a signal resolved with no detail to report"
    end
  end

  test "the TLS gate's 200 arm is the discriminator: a 404-only probe would green on a deleted route" do
    # Stated as its own test so the property is visible without reading
    # resolve/2: the gate is proven by a FLIP, not by a refusal.
    assert {:ok, detail} = resolve({:route, :tls_ask_gate}, %{})
    assert detail =~ "404 → 200"
  end

  test "the tier NOTES sell nothing the bullets are not allowed to sell" do
    # The support_plus note used to read "Priority support and more capacity."
    # and rendered as <p class="tier-note"> on the same card. Deleting the
    # bullet and leaving the note ships the same claim one line up.
    for row <- client_rows!() do
      note = Map.get(row, "note")

      if is_binary(note) do
        refute note =~ @forbidden_note_claims,
               "tier #{Map.fetch!(row, "plan")}'s note sells an unbacked capability: #{inspect(note)}"
      end
    end
  end
end
