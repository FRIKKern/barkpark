defmodule BarkparkCloud.Notifications.TransportManifestTest do
  @moduledoc """
  cch-w52-s1 — THE EMAIL-TRANSPORT MANIFEST GUARD, BIDIRECTIONAL.

  The console's Notifications card offered a three-way segmented control whose
  third option was "API". The schema validated it, the plane Vault-encrypted an
  `api_key_encrypted` for it, and every non-admin member read `Transport: API`
  in a read-only definition list. Behind it: nothing. `deliver_alert/2` has an
  `smtp` clause and a catch-all, there is no Swoosh adapter beyond
  Local/Test/SMTP, and `config.exs` sets `:swoosh, :api_client, false`, which
  structurally forbids one. An "api" team's alert rode the PLATFORM mailer and
  the delivery row was written `sent` — the team was told its own provider
  carried mail it never saw.

  This guard states one rule — EVERY TRANSPORT THE CONSOLE OR THE SCHEMA OFFERS
  MUST HAVE A MECHANISM, AND EVERY MECHANISM MUST ANSWER TO AN OFFER — and it
  can lose four ways:

    * ARM 1, FORWARD (offer → mechanism), through the REAL dispatcher: an
      offered transport whose alert silently lands in the platform mailbox reds,
      BY TRANSPORT NAME. On unmodified `main` this arm was RED, naming `["api"]`.
    * ARM 2, CARRIED vs SILENTLY FELL BACK: the `smtp` transport must actually
      leave the platform adapter. Deleting the `transport: "smtp"` clause in
      `Notifications` reds this arm.
    * ARM 3, REVERSE (mechanism → offer): a `deliver_alert/2` clause head naming
      a transport nobody can select reds, BY TRANSPORT NAME.
    * ARM 4, CONSOLE ↔ SCHEMA: the console's `NOTIF_TRANSPORTS` and
      `EmailSettings.transports/0` must be the same set, in either direction.

  ── WHY ARM 1 IS NOT WRITTEN AS "PROVE api WAS CARRIED" ────────────────────

  Because it cannot be. To ExUnit, an "api" send and an "instance" send are
  BYTE-IDENTICAL — both produce `{captured = true, status "sent", kind "alert"}`
  through `Swoosh.Adapters.Test`. An arm asserting "the api transport is
  honoured" would have passed on the broken code, which is the vacuous green
  this epic exists to kill (charter D592). The discriminator available is the
  other way round: ONLY `"instance"` may land in the platform mailbox. A
  transport that offers its own egress and still lands there did not have one.

  ── WHY ARM 2 CAN TELL CARRIED FROM FALLEN-BACK (no production seam added) ──

  `Swoosh.Mailer.parse_config/4` merges the per-call `dynamic_config` LAST and
  `deliver/2` does `Keyword.fetch!(config, :adapter)`. So a CARRIED smtp send
  REPLACES `Swoosh.Adapters.Test` for that one call and never messages the test
  process; a silent fallback always does. The arm therefore asserts
  `refute_email_sent()` AND `status == "failed"`, and pins NO error text — the
  message ("The destination refused the connection.", `:econnrefused`, …) is
  host- and gen_smtp-version dependent. It makes a real TCP connect to
  127.0.0.1:1, which is instant, and that is the price of exercising the real
  dispatcher instead of a mock.

  ── SCOPE. Quote this guard's green for exactly this much ──────────────────

    1. ARM 1 proves each offered transport is not silently riding the platform
       mailer. It does NOT prove a transport's egress WORKS end-to-end — nobody
       can prove that without a live relay.
    2. ARM 3 reads clause heads out of the compiled module's `debug_info`. It is
       valid only under `MIX_ENV=test` (and dev): `mix release` strips beams by
       default and `mix.exs` sets no `strip_beams: false`. The arm therefore
       asserts the recovered clause list is NON-EMPTY before it looks for
       orphans — otherwise a stripped build would green on nothing.
    3. ARM 4 compares the console's offer LIST against the schema's. It says
       nothing about labels, ordering or what the picker renders.
  """

  # async: false — ARM 2 makes a real (refused) TCP connect and the arms assert
  # on the process mailbox; they stay serial so no other test's mail leaks in.
  use BarkparkCloud.DataCase, async: false

  import Swoosh.TestAssertions

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications
  alias BarkparkCloud.Notifications.{Delivery, EmailSettings}
  alias BarkparkCloud.Repo

  @password "correct-horse-battery"

  # A relay that is guaranteed to refuse: port 1 on loopback. The connect is
  # instant and never leaves the machine.
  @dead_relay_host "127.0.0.1"
  @dead_relay_port 1

  ## ── Fixtures ───────────────────────────────────────────────────────────

  # A team with exactly one member (so one dispatch = one email = one Delivery).
  defp team_with_member do
    n = System.unique_integer([:positive])

    {:ok, user} = Accounts.register_user(%{email: "user-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, _settings} = Notifications.ensure_settings(team)

    {team, user.email}
  end

  # Configure a transport AS FULLY AS IT CAN BE CONFIGURED, through the real
  # context (encryption boundary included). A transport with no configuration
  # surface at all gets the bare selection — which is precisely the shape of the
  # defect: the console let a team pick it and there was nothing else to fill in.
  defp select_transport(team, "smtp") do
    {:ok, s} =
      Notifications.update_settings(team, %{
        "transport" => "smtp",
        "smtp_host" => @dead_relay_host,
        "smtp_port" => @dead_relay_port,
        "smtp_encryption" => "none",
        "smtp_username" => "relay-user",
        "smtp_password" => "relay-pass",
        "from_address" => "alerts@example.com"
      })

    s
  end

  defp select_transport(team, transport) do
    {:ok, s} = Notifications.update_settings(team, %{"transport" => transport})
    s
  end

  # Did an email land in the PLATFORM mailbox (Swoosh.Adapters.Test)? Drains
  # whatever it finds so the next iteration starts clean.
  defp platform_mailbox_hit? do
    receive do
      {:email, _email} ->
        drain_mailbox()
        true
    after
      0 -> false
    end
  end

  defp drain_mailbox do
    receive do
      {:email, _email} -> drain_mailbox()
    after
      0 -> :ok
    end
  end

  ## ── ARM 1 — FORWARD: every OFFER has a MECHANISM ───────────────────────

  test "ARM 1 FORWARD: no transport EmailSettings offers silently rides the platform mailer" do
    transports = EmailSettings.transports()

    # Non-vacuity: an emptied vocabulary must not read as "nothing is unbacked".
    refute Enum.empty?(transports),
           "EmailSettings.transports/0 is EMPTY — an empty offer list can back nothing, and this " <>
             "arm would then iterate zero times and pass having compared nothing"

    assert "instance" in transports,
           "the platform transport is gone from the offer list — this arm's control case is missing"

    # Drive the REAL dispatcher once per offered transport. No grep, no literal
    # list: what is exercised is `Notifications.dispatch_event/3` itself.
    results =
      for transport <- transports do
        {team, _email} = team_with_member()
        select_transport(team, transport)

        drain_mailbox()
        assert :ok = Notifications.dispatch_event(team, :provision_failed, %{name: "prod"})

        {transport, platform_mailbox_hit?()}
      end

    assert length(results) == length(transports),
           "the arm exercised #{length(results)} of #{length(transports)} offered transports"

    # The CONTROL: "instance" IS the platform mailer, so it must land there. If
    # it does not, the harness itself is broken and every offender below would
    # be a false green.
    assert {"instance", true} in results,
           "the platform transport did NOT reach the test mailbox — the harness is not observing " <>
             "real dispatch, so this arm cannot distinguish anything (results: #{inspect(results)})"

    offenders =
      results
      |> Enum.filter(fn {transport, hit?} -> transport != "instance" and hit? end)
      |> Enum.map(&elem(&1, 0))

    assert offenders == [],
           "transports OFFERED by EmailSettings with NO mechanism behind them (the alert silently " <>
             "rode the platform mailer): #{inspect(offenders)}"
  end

  ## ── ARM 2 — CARRIED vs SILENTLY FELL BACK ──────────────────────────────

  test "ARM 2: a configured smtp transport LEAVES the platform adapter — a fallback would be caught" do
    {team, recipient} = team_with_member()
    select_transport(team, "smtp")

    drain_mailbox()
    assert :ok = Notifications.dispatch_event(team, :provision_failed, %{name: "prod"})

    # THE DISCRIMINATOR. A carried smtp send replaces Swoosh.Adapters.Test for
    # that call and never messages this process; a silent fallback always does.
    refute_email_sent()

    delivery = Repo.get_by!(Delivery, team_id: team.id, recipient: recipient)

    # The relay refuses, so the send FAILS — and a failure recorded honestly is
    # the whole point: the team is told, rather than shown a green "sent" for a
    # mail the platform quietly carried. NO error text is pinned here: the
    # wording is host- and gen_smtp-version dependent.
    assert delivery.status == "failed",
           "an smtp send to a refusing relay was recorded #{inspect(delivery.status)} — a " <>
             "non-failed row here means the alert fell back to the platform transport"
  end

  ## ── ARM 5 — THE ROW NAMES ITS CARRIER (cch-w52-s3) ─────────────────────

  # ARM 2 above proves an smtp send LEAVES the platform adapter. This arm proves
  # the delivery ROW says which one it left on — the observability half of the
  # same seam. It is a separate arm and not an extra assertion inside ARM 2
  # because it loses to a DIFFERENT defect: ARM 2 reds when the mechanism is
  # wrong, this reds when the mechanism is right and the RECORD is wrong.
  #
  # The two halves are asserted TOGETHER on purpose. A carrier that is a constant
  # is green against either half alone, and constant-ness is the exact failure
  # mode a `carrier` column invites (see the MUTATION note below). Only the pair
  # discriminates.
  test "ARM 5 CARRIER: a carried smtp send records team_smtp and a platform send records platform" do
    # CARRIED: the team's own relay took it (and refused it, which is ARM 2's
    # discriminator — the row is `failed`, and it is still a `team_smtp` row,
    # because the carrier records WHO CARRIED IT, not whether it arrived).
    {smtp_team, smtp_recipient} = team_with_member()
    select_transport(smtp_team, "smtp")

    drain_mailbox()
    assert :ok = Notifications.dispatch_event(smtp_team, :provision_failed, %{name: "prod"})

    carried = Repo.get_by!(Delivery, team_id: smtp_team.id, recipient: smtp_recipient)

    # PLATFORM: the same event, the same channel, the same builder — only the
    # transport differs. Before `carrier` these two rows were distinguishable by
    # NOTHING on the row itself.
    {platform_team, platform_recipient} = team_with_member()
    select_transport(platform_team, "instance")

    drain_mailbox()
    assert :ok = Notifications.dispatch_event(platform_team, :provision_failed, %{name: "prod"})

    platform = Repo.get_by!(Delivery, team_id: platform_team.id, recipient: platform_recipient)

    assert carried.carrier == "team_smtp",
           "a send the team's OWN relay carried was recorded carrier " <>
             "#{inspect(carried.carrier)} — the row cannot answer \"sent by what\""

    assert platform.carrier == "platform",
           "a send the PLATFORM mailer carried was recorded carrier " <>
             "#{inspect(platform.carrier)}"

    # NON-VACUITY / THE MUTATION THIS ARM EXISTS FOR: hard-coding the carrier to
    # any single constant satisfies exactly one of the two assertions above and
    # reds the other. Stating the inequality outright means the arm also loses if
    # both are somehow rewritten to the same value.
    refute carried.carrier == platform.carrier,
           "both sends recorded the SAME carrier — the value is a constant, not a measurement"

    # And the vocabulary is CLOSED, with no `api` member: cch-w52-s1 deleted that
    # transport, and a carrier column that re-mints the word would repeat the
    # crown defect one layer down.
    assert carried.carrier in Delivery.carriers()
    assert platform.carrier in Delivery.carriers()
    refute "api" in Delivery.carriers()
  end

  # The SILENT FALLBACK — the reason `deliver_alert/2` had to start RETURNING its
  # carrier rather than letting `record_delivery` re-derive one from
  # `settings.transport`. A team that SELECTED smtp and whose secrets will not
  # decrypt rides the PLATFORM mailer; a derivation from the settings row would
  # have written "team_smtp" and told that team its own relay carried mail it
  # never saw. Twin of the notifications_test case, kept here because this file
  # is the manifest for offer↔mechanism honesty.
  test "ARM 5 FALLBACK: an smtp team whose override cannot be built records platform, never team_smtp" do
    {team, recipient} = team_with_member()
    settings = select_transport(team, "smtp")

    # Corrupt the ciphertext THROUGH the repo, not through the context: the
    # context encrypts on write, so this is the only way to reach the state a
    # rotated/rekeyed Vault produces in production.
    {:ok, _} =
      settings
      |> Ecto.Changeset.change(%{smtp_host_encrypted: "not-a-valid-ciphertext"})
      |> Repo.update()

    drain_mailbox()
    assert :ok = Notifications.dispatch_event(team, :provision_failed, %{name: "prod"})

    delivery = Repo.get_by!(Delivery, team_id: team.id, recipient: recipient)

    assert delivery.carrier == "platform",
           "an smtp team whose override could NOT be built rode the platform mailer but recorded " <>
             "carrier #{inspect(delivery.carrier)} — the row asserts a relay that never ran"

    # It landed in the PLATFORM mailbox, which is the independent witness that
    # "platform" is a measurement of what happened rather than a guess.
    assert platform_mailbox_hit?(),
           "the fallback send did NOT reach the platform test mailbox — this case is not " <>
             "exercising the fallback at all, so its carrier assertion proves nothing"

    assert delivery.status == "sent"
  end

  ## ── ARM 3 — REVERSE: every MECHANISM answers to an OFFER ───────────────

  # `deliver_alert/2` stays `defp`. Its clause heads are recovered from the
  # compiled module's Elixir debug_info — valid under MIX_ENV=test/dev only,
  # because `mix release` strips beams by default and mix.exs sets no
  # `strip_beams: false` override.
  test "ARM 3 REVERSE: no deliver_alert clause answers to a transport nobody can select" do
    clauses = deliver_alert_clauses()

    # NON-EMPTY FIRST. A stripped-debug_info build (or a rename of
    # deliver_alert/2) otherwise yields orphans == [] and greens on nothing.
    assert clauses != [],
           "no deliver_alert/2 clauses could be recovered from " <>
             "#{inspect(BarkparkCloud.Notifications)}'s debug_info — this arm cannot see the " <>
             "dispatch mechanism at all, and MUST NOT read as 'no orphans'"

    literals =
      clauses
      |> Enum.flat_map(&transport_literals/1)
      |> Enum.uniq()

    assert literals != [],
           "the recovered deliver_alert/2 clauses pattern-match on NO transport literal at all " <>
             "(#{length(clauses)} clauses) — the extraction is not seeing clause heads"

    orphans = Enum.reject(literals, &(&1 in EmailSettings.transports()))

    assert orphans == [],
           "dispatch clauses for transports nobody can select: #{inspect(orphans)}"
  end

  # The Elixir clause heads of the private deliver_alert/2.
  defp deliver_alert_clauses do
    module = BarkparkCloud.Notifications
    Code.ensure_loaded!(module)

    with beam when is_list(beam) <- :code.which(module),
         {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(beam, [:debug_info]),
         {:ok, %{definitions: definitions}} <- backend.debug_info(:elixir_v1, module, data, []) do
      Enum.flat_map(definitions, fn
        {{:deliver_alert, 2}, _kind, _meta, clauses} -> clauses
        _ -> []
      end)
    else
      _ -> []
    end
  end

  # Every `transport: "…"` literal appearing in one clause's argument patterns.
  defp transport_literals({_meta, args, _guards, _body}) do
    {_ast, found} =
      Macro.prewalk(args, [], fn
        {:transport, value} = node, acc when is_binary(value) -> {node, [value | acc]}
        node, acc -> {node, acc}
      end)

    found
  end

  defp transport_literals(_other), do: []

  ## ── ARM 4 — CONSOLE ↔ SCHEMA ───────────────────────────────────────────

  # D593 permits reading a literal HERE AND ONLY HERE: the offer list is
  # JavaScript and the mechanism is Elixir, so this arm cannot run through
  # dispatch. It is still read BY RUNNING, never by regex — the shipped app.js
  # is evaluated in a node:vm sandbox (the recipe __app.test.mjs and
  # __plan_features_dump.mjs already use) and the value is taken off the same
  # `__bpTestHook` the console's own JS suite reads.
  @dump_js ~S"""
  const vm = require("node:vm");
  const fs = require("node:fs");

  const noop = () => {};
  const inertEl = {
    addEventListener: noop, removeEventListener: noop, setAttribute: noop,
    removeAttribute: noop,
    classList: { add: noop, remove: noop, toggle: noop, contains: () => false },
    style: {}, hidden: false, value: "", innerHTML: "", textContent: "",
    querySelector: () => null, querySelectorAll: () => [],
  };
  const storage = { getItem: () => null, setItem: noop, removeItem: noop };
  const hooks = {};
  const sandbox = {
    __bpTestHook(h) { Object.assign(hooks, h); },
    document: {
      readyState: "loading",
      addEventListener: noop, removeEventListener: noop,
      querySelector: () => null, querySelectorAll: () => [],
      getElementById: () => null, createElement: () => ({ ...inertEl }),
      documentElement: { ...inertEl, getAttribute: () => null },
      body: { ...inertEl, appendChild: noop },
    },
    window: {
      addEventListener: noop, removeEventListener: noop, open: () => null,
      matchMedia: () => ({ matches: false, addEventListener: noop }),
    },
    location: { hash: "", pathname: "/", search: "", origin: "http://localhost" },
    localStorage: storage,
    sessionStorage: storage,
    navigator: {},
    URL: URL,
    URLSearchParams: URLSearchParams,
    fetch: () => Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({}) }),
    EventSource: function () { return { addEventListener: noop, close: noop }; },
    setTimeout: noop, clearTimeout: noop, setInterval: () => 1, clearInterval: noop,
    console,
  };
  sandbox.globalThis = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(process.argv[1], "utf8"), sandbox);

  if (!Object.prototype.hasOwnProperty.call(hooks, "notifTransports")) {
    console.error("app.js did not export notifTransports on __bpTestHook — the console's email-transport offers are unreadable, and an unreadable offer list must never read as 'the console offers nothing unbacked'");
    process.exit(2);
  }
  if (!Array.isArray(hooks.notifTransports)) {
    console.error(`__bpTestHook.notifTransports is not an array (got ${typeof hooks.notifTransports})`);
    process.exit(3);
  }
  if (hooks.notifTransports.length === 0) {
    console.error("__bpTestHook.notifTransports is EMPTY — the console always renders a transport picker, so an empty list means the read is broken");
    process.exit(4);
  }
  if (!hooks.notifTransports.every((v) => typeof v === "string" && v.trim() !== "")) {
    console.error(`__bpTestHook.notifTransports carries a non-string or blank entry: ${JSON.stringify(hooks.notifTransports)}`);
    process.exit(5);
  }

  process.stdout.write(JSON.stringify(Array.from(hooks.notifTransports)));
  """

  test "ARM 4 CONSOLE↔SCHEMA: the console offers exactly the transports the schema knows" do
    console = console_transports!()
    schema = EmailSettings.transports()

    only_console = console -- schema
    only_schema = schema -- console

    assert only_console == [],
           "the console OFFERS #{inspect(only_console)}, which EmailSettings does not accept — a " <>
             "team picking one gets a validation error at best, and a transport with no mechanism " <>
             "at worst (console: #{inspect(console)}, schema: #{inspect(schema)})"

    assert only_schema == [],
           "EmailSettings accepts #{inspect(only_schema)}, which the console never offers — either " <>
             "wire it into NOTIF_TRANSPORTS or drop it from @transports (console: " <>
             "#{inspect(console)}, schema: #{inspect(schema)})"
  end

  defp console_transports! do
    node = System.find_executable("node")

    # A guard that cannot run must RED, never skip. `.github/workflows/cloud.yml`
    # installs node with actions/setup-node@v4 rather than betting on the image.
    assert node,
           "node is not on PATH — the console half of the transport manifest cannot be read"

    app_js =
      [__DIR__, "..", "..", "..", "priv", "static", "app.js"]
      |> Path.join()
      |> Path.expand()

    assert File.exists?(app_js), "the shipped console bundle is missing at #{app_js}"

    {out, status} = System.cmd(node, ["-e", @dump_js, app_js], stderr_to_stdout: true)

    assert status == 0,
           "reading the console's transport offers failed (exit #{status}) — the offer list could " <>
             "not be read BY RUNNING app.js: #{out}"

    Jason.decode!(out)
  end
end
