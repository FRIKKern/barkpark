defmodule BarkparkCloud.LifecycleStateManifestTest do
  @moduledoc """
  cch-w54-s1 — THE (STATE, REASON) LIFECYCLE MANIFEST.

  The Cloud console paints an instance's lifecycle as a word in a pill and a
  sentence in a card. Nothing connected either to what the control plane
  actually DOES when it moves an instance into that state, so the console's word
  for a suspended box was "Stopped" and its card read "The server is stopped,
  not destroyed" — while the entire suspension mechanism is one UPDATE of three
  columns on the `barkparks` row (`suspended`, `suspended_reason`,
  `suspended_at`). After that write the control plane stops LOOKING at the box:
  the health sweep's checkable scope and the autoupdate candidate query both
  skip suspended rows. Nothing reaches the host. The schema says so in its own
  words — "a suspended box may still be perfectly reachable".

  NO CUSTOMER HAS SEEN THAT CARD. Prod carries ZERO suspended rows: 27 teams, 8
  barkparks, 22 subscriptions, all active. This guard hardens the register
  before its first customer rather than cleaning up after one, and nothing in
  this file should be read as a report of live harm.

  ## THE RULE, AND THE FOUR WAYS IT CAN LOSE

  A lifecycle state is painted with the word for a mechanism the plane can be
  shown to run. Concretely:

    * CROWN — for each `(state, reason)`, if NOTHING observed in that row's
      mechanism set can halt a host, the console's word for that state may not
      claim a halt. Reds by row, quoting the word and the observed set.
    * TAXONOMY — `@halting_classes` and `@non_halting_classes` are disjoint and
      each class is placed by WHAT IT REACHES. Reclassifying `:cp_flag` as
      halting (the cheap way to buy a green crown) reds here, by name.
    * PAINTED SET — the states the console can paint are pinned HERE, and the
      comparison loses in BOTH directions: a new painted state reds as an ADD, a
      state the fold can no longer reach reds as a STALE pin.
    * FENCE — the fence probe proves BY RUNNING which door suspension closes: it
      mints before the producer and again after it, and refuses to report a fence
      it cannot attribute. RETRACTED: this line used to read "proves that a
      suspended row is still served". That was true when this manifest was
      derived and is FALSE now — `Registry.mint_studio_link/2` grew a
      `%Barkpark{suspended: true}` clause answering `{:error, :suspended}`, so the
      probe observes a fence. What it does NOT observe is a fence on the HOST's
      traffic; see the split below.

  ## THE SPLIT: `:cp_access_fence` vs `:traffic_fence`

  A refusal is placed by WHAT IT REACHES, like every other class here.

    * `:cp_access_fence` (NON-halting) — the control plane refuses to mint or
      reveal a credential for a suspended row. The refusal fires inside Cloud,
      before any transport to the box; the box keeps serving its own traffic to
      everyone who already has a way in. This is the class the studio-link probe
      observes.
    * `:traffic_fence` (HALTING) — a block on the data plane itself: a Caddy route
      pulled, a proxy answering 402, anything that leaves the customer's server
      not serving.

  QUOTE THIS ONLY THIS FAR: `:traffic_fence` is a DECLARED-EMPTY class. NO probe
  in this file observes it, so it can only fail by someone deliberately labelling
  a mechanism into it — a strictly weaker guarantee than the `:cp_flag` and
  `:event` arms, which are read by running. It exists so that the day a real
  data-plane block is wired, the crown fires instead of inheriting this file's
  silence.

  ## KEYED ON (STATE, REASON), NEVER ON STATE ALONE

  Three rows share the state `stopped` and come from three different producers:

    | reason             | producer                                        |
    |--------------------|-------------------------------------------------|
    | `billing_lapsed`   | `Billing.cancel_subscription/1`                 |
    | `billing_past_due` | `Billing.mark_past_due/2`, grace already elapsed |
    | `quota_exceeded`   | `Billing.reconcile_plan_limit/1`                |

  Driven separately through those REAL entry points they come back with
  DIFFERENT observed mechanism sets — only the quota producer broadcasts, because
  only it suspends row-by-row (`suspend_one/2`) instead of one bulk `update_all`.
  A state-keyed manifest would let one producer's mechanisms vouch for another's,
  and could not lose when a producer's behaviour changed underneath it. The
  MECHANISM test below asserts the sets actually differ, so the (state, reason)
  key is load-bearing rather than decorative.

  ## BOTH SIDES ARE READ BY RUNNING

    * CLIENT — `priv/static/__preview__/__lifecycle_state_dump.mjs` evaluates the
      SHIPPED `app.js` in a node:vm sandbox and CALLS `lifecyclePill` over the
      CARTESIAN PRODUCT of the four fields `instanceLifecycle` reads, printing
      what the fold actually paints. It does not read the label map: that map
      declares SEVEN states while the fold can return only five (`archived` and
      `adopted` are labels no input reaches), so a guard that read it would pin
      two dead words. This test spawns the dump with `System.cmd/3` and REDS on
      any non-zero exit. There is no regex and no `File.read!` over `app.js` in
      this file.
    * SERVER — every mechanism is resolved against THIS booted BEAM: the flag by
      re-reading the row, the event by SUBSCRIBING before the producer runs, the
      fence by calling `Registry.mint_studio_link/2` before and after.

  ## SCOPE — quote this guard's green for exactly this much, and no more

    1. THE FENCE PROBE COVERS ONE ACCESS PATH: studio-link minting. It shows that
       Cloud DOES refuse to mint against a suspended row — a `:cp_access_fence`.
       RETRACTED: this paragraph used to read "It shows that Cloud does not refuse
       to mint against a suspended row"; that sentence is contradicted by
       `Registry.mint_studio_link/2` on main and is withdrawn rather than left
       standing next to a passing test. The probe still says nothing about the
       other doors into a box, and — because the instance transport is the
       `StudioLinkFakeHttpClient` double — nothing about whether the instance
       itself would answer.
    2. `:power` AND `:agent_command` RESOLVE AS DECLARATIVE ABSENCES. There is no
       caller to run: the Hetzner catalog declares a `:poweroff` verb that
       nothing under `cloud/lib` invokes, and `GET /v1/agent/commands` returns a
       queue with no source. This probe checks that no verb of either shape is
       exported, which means it CANNOT detect a silent gain the way the `:fence`
       probe can — a power call added inside an existing function would not
       change any export. If either scan stops finding an absence it reports
       INDETERMINATE and flunks, demanding the manifest be re-derived by hand.
       THIS PARAGRAPH IS LOAD-BEARING; do not delete it to make the green read
       larger than it is.
    3. It reads what the lifecycle fold RETURNS plus the one card the suspension
       path renders. Any other sentence in the console is out of its reach.
  """

  # async: true — every DB touch is inside the SQL sandbox, the `:pg` event
  # subscription is keyed on this process, and the HTTP double is owner-keyed by
  # pid, so nothing bleeds between concurrent tests.
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Billing, Events, Registry, Repo}
  alias BarkparkCloud.Registry.Vault
  alias BarkparkCloud.StudioLinkFakeHttpClient

  ## ── The taxonomy: mechanism classes, placed by WHAT THEY REACH ─────────

  # A class is HALTING if running it can leave the customer's server not serving.
  #   :traffic_fence — a block on the data plane itself (a Caddy route pulled, a
  #                    proxy answering 402). NOTHING observes this today; see the
  #                    moduledoc's declared-empty note before quoting its green.
  @halting_classes MapSet.new([:power, :traffic_fence, :agent_command])

  # A class is NON-HALTING if running it changes only what the CONTROL PLANE
  # knows, says, or hands out. Each member is here for a stated reason, asserted
  # below:
  #   :cp_flag         — a boolean in a Postgres row does not reach the host.
  #   :event           — an event is the control plane telling its own tabs what
  #                      it decided; the box is not a subscriber and never hears
  #                      it.
  #   :cp_access_fence — the control plane refuses to MINT or REVEAL a credential
  #                      for a suspended row (`mint_studio_link/2`,
  #                      `mint_app_token/2`). The refusal fires inside Cloud,
  #                      before any transport to the instance; the box keeps
  #                      serving its own traffic to everyone who already has a
  #                      way in. That is isolation of the control plane's own
  #                      doors, not a halt.
  @non_halting_classes MapSet.new([:cp_flag, :event, :cp_access_fence])

  # Words that assert the customer's server is not running. A state whose
  # observed mechanisms are all non-halting may not use one.
  @halt_words ~r/\bstopped\b|\bshut down\b|\bpowered off\b|\bpower(ed)? down\b|\bhalted\b|\bturned off\b|\boffline\b/i

  ## ── The rows: (state, reason) → the REAL producer that writes it ───────

  @rows [
    %{state: "stopped", reason: "billing_lapsed", producer: :cancel_subscription},
    %{state: "stopped", reason: "billing_past_due", producer: :grace_elapsed},
    %{state: "stopped", reason: "quota_exceeded", producer: :quota_reconcile}
  ]

  # The lifecycle states the console can paint, pinned HERE and by NEITHER side.
  # That is not style — it is the only reason the STALE direction can lose. A
  # guard that iterated whatever the dump emitted would pass at zero iterations
  # with the fold gutted.
  @painted_states MapSet.new(~w(decommissioned degraded live provisioning stopped))

  # Exported-function shapes that would mean a mechanism class stopped being an
  # absence. Deliberately broad: a false INDETERMINATE costs a re-derivation, a
  # false absence costs the guard's meaning.
  @power_verb ~r/power|poweroff|shutdown|reboot|halt_/
  @command_verb ~r/(enqueue|dispatch|send|queue|push)_command|command_(enqueue|dispatch|queue)/

  @password "correct-horse-battery"

  ## ── The client half ────────────────────────────────────────────────────

  defp console_dump! do
    node = System.find_executable("node")

    # A guard that cannot run must RED, never skip. `.github/workflows/cloud.yml`
    # installs node with actions/setup-node@v4 rather than betting on the image.
    assert node,
           "node is not on PATH — the lifecycle-state manifest cannot read what the console paints"

    script =
      :barkpark_cloud
      |> :code.priv_dir()
      |> Path.join("static/__preview__/__lifecycle_state_dump.mjs")

    assert File.exists?(script),
           "the client dump script is missing at #{script} — the painted lifecycle states cannot be read"

    {out, status} = System.cmd(node, [script], stderr_to_stdout: true)

    assert status == 0,
           "the console dump failed (exit #{status}) — what the console paints could not be read by running: #{out}"

    Jason.decode!(out)
  end

  ## ── Fixtures ───────────────────────────────────────────────────────────

  defp team_fixture do
    n = System.unique_integer([:positive])

    {:ok, user} = Accounts.register_user(%{email: "u-#{n}@example.com", password: @password})
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")

    team
  end

  # A registered box carrying the two things `mint_studio_link/2` needs: a
  # customer-facing url and a decryptable admin token. `admin_token_encrypted` is
  # NOT castable through `Barkpark.changeset/2` (only the provision-success
  # write may set it), so this seeds it the way the registry tests do — through
  # a bare `Ecto.Changeset.change/2`. `inserted_at` is stamped explicitly so the
  # quota reconciler's newest-first ordering is deterministic rather than
  # microsecond luck.
  defp live_box(team, age_days) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    born =
      DateTime.utc_now()
      |> DateTime.add(-age_days, :day)
      |> DateTime.truncate(:microsecond)

    bp
    |> Ecto.Changeset.change(
      url: "https://bp-#{n}.barkpark.cloud",
      host: "203.0.113.10",
      admin_token_encrypted: Vault.encrypt("instance-admin-token"),
      inserted_at: born
    )
    |> Repo.update!()
  end

  # A box with NO admin token — minting fails before any producer runs, which is
  # what the `:fence` probe's before/after discriminator exists to notice.
  defp tokenless_box(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})

    bp
    |> Ecto.Changeset.change(url: "https://bp-#{n}.barkpark.cloud", host: "203.0.113.10")
    |> Repo.update!()
  end

  # Seed the world each producer needs, and return {team, the box the producer
  # will suspend, the zero-arity function that RUNS the real producer}.
  defp seed(:cancel_subscription) do
    team = team_fixture()
    bp = live_box(team, 10)
    {:ok, sub} = Billing.subscribe(team, "supporter")

    {team, bp, fn -> {:ok, _} = Billing.cancel_subscription(sub) end}
  end

  defp seed(:grace_elapsed) do
    team = team_fixture()
    bp = live_box(team, 10)
    {:ok, sub} = Billing.subscribe(team, "supporter")

    # The REAL entry point, driven through the state that makes it enforce: a
    # past_due write whose grace anchor is already in the past. `mark_past_due/2`
    # calls the private `maybe_enforce/1` itself.
    elapsed = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:microsecond)

    {team, bp, fn -> {:ok, _} = Billing.mark_past_due(sub, %{grace_ends_at: elapsed}) end}
  end

  defp seed(:quota_reconcile) do
    team = team_fixture()

    # Two boxes BEFORE any subscription: with no active sub the create-time
    # ceiling does not fire, so the team can be put over its limit exactly the
    # way a DOWNGRADE puts it over. `free` allows one, so the NEWER box is the
    # single overflow row — and the ages are stamped, so "newer" is a fact.
    _older = live_box(team, 30)
    newer = live_box(team, 1)
    {:ok, _sub} = Billing.subscribe(team, "free")

    {team, newer, fn -> %{suspended: 1} = Billing.reconcile_plan_limit(team) end}
  end

  ## ── Observing one row's mechanisms BY RUNNING its producer ─────────────

  # Runs the producer ONCE with every observer already armed, and returns
  #
  #   %{observed: MapSet, flag: …, fence: {verdict, detail}, reason: …}
  #
  # `observed` holds only classes that actually FIRED. `:power` and
  # `:agent_command` are absences (see the moduledoc) and are reported
  # separately so a scan that stops finding an absence can flunk loudly instead
  # of quietly widening `observed`.
  defp observe(row) do
    {team, bp, run} = seed(row.producer)

    Events.subscribe(team.id)
    StudioLinkFakeHttpClient.program([])

    mint_before = Registry.mint_studio_link(bp)

    run.()

    reloaded = Registry.get_barkpark(bp.id)

    flag? = reloaded.suspended and reloaded.suspended_reason == row.reason
    event? = received_suspended_event?(bp.id)
    fence = fence_verdict(mint_before, reloaded)

    observed =
      [{:cp_flag, flag?}, {:event, event?}, {:cp_access_fence, elem(fence, 0) == :fence}]
      |> Enum.filter(&elem(&1, 1))
      |> Enum.map(&elem(&1, 0))
      |> MapSet.new()

    %{
      row: row,
      observed: observed,
      flag: flag?,
      fence: fence,
      mint_before: mint_before,
      reloaded: reloaded
    }
  end

  defp received_suspended_event?(barkpark_id) do
    receive do
      {:bpcloud_event, %{type: "barkpark.suspended", payload: %{barkpark_id: ^barkpark_id}}} ->
        true
    after
      100 -> false
    end
  end

  # THE BEFORE/AFTER DISCRIMINATOR. A one-shot "does minting fail now?" probe
  # scores a BROKEN PRECONDITION as a fence: an unseeded box fails with
  # `:no_admin_token` whether or not it is suspended, and a naive probe reports
  # `:fence OBSERVED` from that refusal. So minting must SUCCEED before the
  # producer runs, or this refuses to attribute anything.
  defp fence_verdict({:error, why}, _reloaded) do
    {:indeterminate,
     "minting already failed BEFORE the producer ran (#{inspect(why)}) — a refusal after it " <>
       "cannot be attributed to the state change, so no fence is claimed either way"}
  end

  defp fence_verdict({:ok, _link}, reloaded) do
    case Registry.mint_studio_link(reloaded) do
      {:ok, _link} ->
        # THIS IS NOW THE FAILURE BRANCH. Cloud refuses to mint against a
        # suspended row (`Registry.mint_studio_link/2`'s
        # `%Barkpark{suspended: true}` clause), so reaching here means that
        # refusal was deleted or weakened — not that all is well. The old text
        # ("Cloud does not refuse to hand out access…, so nothing fences traffic
        # away from it") is RETRACTED: it read as the expected outcome, and it
        # conflated the credential desk with the data plane.
        {:no_fence,
         "mint_studio_link SUCCEEDED against the suspended row — the control-plane access fence " <>
           "is GONE. Cloud is expected to answer {:error, :suspended} here; this says nothing " <>
           "about the host's own traffic either way"}

      {:error, why} ->
        {:fence,
         "mint_studio_link succeeded before the producer and refused after it (#{inspect(why)})"}
    end
  end

  # The two declarative absences, resolved off this booted BEAM's exports.
  defp absence(:power) do
    case exported_matching(Registry, @power_verb) do
      [] ->
        {:absent,
         "BarkparkCloud.Registry exports no power verb, so no suspension producer can call one"}

      found ->
        {:indeterminate, "a power verb now exists on BarkparkCloud.Registry: #{inspect(found)}"}
    end
  end

  defp absence(:agent_command) do
    case exported_matching(Registry, @command_verb) do
      [] ->
        {:absent,
         "BarkparkCloud.Registry exports no command-enqueue verb, and GET /v1/agent/commands " <>
           "serves a queue with no source, so no suspension producer can command the box"}

      found ->
        {:indeterminate,
         "a command-enqueue verb now exists on BarkparkCloud.Registry: #{inspect(found)}"}
    end
  end

  defp exported_matching(module, pattern) do
    Code.ensure_loaded!(module)

    module.__info__(:functions)
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(&Regex.match?(pattern, Atom.to_string(&1)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  ## ── The arms ───────────────────────────────────────────────────────────

  test "TAXONOMY: halting and non-halting classes are disjoint, and each is placed by what it reaches" do
    # THIS IS THE ARM THAT REDS WHEN SOMEONE BUYS A GREEN CROWN. Moving
    # `:cp_flag` into @halting_classes makes every crown row's obligation
    # discharge vacuously — and lands here, by name.
    assert MapSet.disjoint?(@halting_classes, @non_halting_classes),
           "a mechanism class cannot be both halting and non-halting; the overlap is " <>
             "#{inspect(MapSet.intersection(@halting_classes, @non_halting_classes) |> MapSet.to_list())}"

    assert MapSet.member?(@non_halting_classes, :cp_flag),
           ":cp_flag is NON-halting — a boolean in a Postgres row does not reach the host. " <>
             "Suspension writes suspended/suspended_reason/suspended_at and the control plane " <>
             "then stops LOOKING at the box; the box keeps serving. Moving this class is how a " <>
             "crown row gets a green it did not earn."

    assert MapSet.member?(@non_halting_classes, :event),
           ":event is NON-halting — an event is the control plane telling its own browser tabs " <>
             "what it decided. The instance is not a subscriber and never hears it."

    # THE SPLIT, and the reason it is a split rather than a reclassification.
    # `mint_studio_link/2` now answers {:error, :suspended} for a suspended row
    # (registry.ex, alongside `mint_app_token/2`'s identical arm). That refusal
    # is REAL and it is a security fence — but it is placed by WHAT IT REACHES,
    # like every other class here, and what it reaches is the control plane's own
    # credential desk. Folding it into @halting_classes wholesale would take all
    # three rows into the CROWN's else-branch and delete the `refute word =~
    # @halt_words` check outright — this epic's thesis killed by this epic's own
    # crown. So the access-path class is split in two, and only the half that
    # reaches the data plane is halting.
    assert MapSet.member?(@non_halting_classes, :cp_access_fence),
           ":cp_access_fence is NON-halting — Cloud refusing to mint or reveal a credential " <>
             "changes what the control plane HANDS OUT, not what the host serves. The refusal " <>
             "fires before any transport to the box, and the box keeps answering everyone who " <>
             "already has a way in. Moving this class into @halting_classes takes every crown " <>
             "row into the else-branch and deletes the halt-word check."

    assert MapSet.member?(@halting_classes, :traffic_fence),
           ":traffic_fence is halting — a block on the data plane leaves the customer's server " <>
             "not serving. NO probe observes it today (see the moduledoc); it is declared so a " <>
             "real data-plane block can only be labelled into a halting class."

    for class <- [:power, :agent_command] do
      assert MapSet.member?(@halting_classes, class),
             "#{inspect(class)} is halting — it reaches the host itself"
    end

    # Neither set may be emptied into the other's silence.
    assert MapSet.size(@halting_classes) == 3
    assert MapSet.size(@non_halting_classes) == 3
  end

  test "CROWN: no (state, reason) whose observed mechanisms cannot halt a host is painted as a halt" do
    dump = console_dump!()
    painted = Map.fetch!(dump, "suspended")
    word = Map.fetch!(painted, "label")
    detail = Map.fetch!(painted, "detail")

    for row <- @rows do
      obs = observe(row)

      assert obs.flag,
             "the #{row.producer} producer did not leave #{inspect(row.reason)} on the row — " <>
               "this manifest observed NOTHING and must not be read as agreement"

      halting = MapSet.intersection(obs.observed, @halting_classes)

      if MapSet.size(halting) == 0 do
        refute word =~ @halt_words,
               "the console paints (#{row.state}, #{row.reason}) as #{inspect(word)}, but the " <>
                 "only mechanisms this producer runs are " <>
                 "#{inspect(MapSet.to_list(obs.observed))} — none of which can stop a host. " <>
                 "#{elem(obs.fence, 1)}"

        refute detail =~ @halt_words,
               "the console's detail line for (#{row.state}, #{row.reason}) reads " <>
                 "#{inspect(detail)} — a halt claim with nothing behind it"
      else
        # If a halting mechanism ever IS observed, the word may legitimately
        # claim a halt — but the manifest must say WHICH mechanism earned it,
        # so nobody inherits the license silently.
        flunk(
          "(#{row.state}, #{row.reason}) now observes halting mechanisms " <>
            "#{inspect(MapSet.to_list(halting))}. That may be correct and may license the word " <>
            "#{inspect(word)} — but it is a change in what suspension DOES, so re-derive this " <>
            "manifest by hand rather than editing the assertion."
        )
      end
    end
  end

  test "MECHANISM: the three rows observe DIFFERENT sets, which is why the key is (state, reason)" do
    by_reason = Map.new(@rows, fn row -> {row.reason, observe(row).observed} end)

    lapsed = Map.fetch!(by_reason, "billing_lapsed")
    past_due = Map.fetch!(by_reason, "billing_past_due")
    quota = Map.fetch!(by_reason, "quota_exceeded")

    # The flag is the one thing all three share — it IS the state change.
    for {reason, set} <- by_reason do
      assert MapSet.member?(set, :cp_flag),
             "#{reason} observed no :cp_flag — its producer did not write the row"
    end

    # Only the quota producer broadcasts: it suspends row-by-row through
    # `suspend_one/2`, while both billing producers go through
    # `Registry.suspend_team_barkparks/2`'s single bulk `update_all`.
    assert MapSet.member?(quota, :event),
           "the quota producer no longer broadcasts barkpark.suspended — observed " <>
             "#{inspect(MapSet.to_list(quota))}"

    refute MapSet.member?(lapsed, :event),
           "billing_lapsed now broadcasts; the bulk suspend path changed shape"

    refute MapSet.member?(past_due, :event),
           "billing_past_due now broadcasts; the bulk suspend path changed shape"

    # THE POINT: a state-keyed manifest would collapse these into one row and let
    # the quota producer's event vouch for the billing producers' silence.
    refute MapSet.equal?(quota, lapsed),
           "all three producers now observe the SAME mechanisms — if that is genuinely true the " <>
             "key may be simplified, but until then a state-keyed manifest is a guard that " <>
             "cannot lose"
  end

  test "PAINTED SET: the states the console can paint are pinned, and the pin loses in BOTH directions" do
    dump = console_dump!()

    assert Map.fetch!(dump, "combos") > 0, "the dump drove no inputs at all"

    actual =
      dump
      |> Map.fetch!("painted")
      |> Enum.map(&Map.fetch!(&1, "state"))
      |> MapSet.new()

    refute MapSet.size(actual) == 0,
           "the console painted NOTHING — an unreadable console is a red"

    added = MapSet.difference(actual, @painted_states)
    stale = MapSet.difference(@painted_states, actual)

    assert MapSet.equal?(actual, @painted_states),
           "the console's painted lifecycle states drifted from this manifest.\n" <>
             "  painted but unpinned (ADD):   #{inspect(MapSet.to_list(added))}\n" <>
             "  pinned but unpaintable (STALE): #{inspect(MapSet.to_list(stale))}\n" <>
             "A new painted state needs a (state, reason) row here saying what the plane runs " <>
             "for it; a state the fold can no longer reach needs its pin deleted in the same " <>
             "commit, deliberately."

    # The label map declares more states than the fold can reach, which is why
    # the painted set is read by RUNNING. Stated as an assertion so the day the
    # dead labels are cleaned up, this note is forced to be revisited.
    declared = dump |> Map.fetch!("declared_labels") |> MapSet.new()

    assert MapSet.subset?(actual, declared),
           "the fold painted a state LIFECYCLE_PILL_LABEL does not declare: " <>
             "#{inspect(MapSet.difference(actual, declared) |> MapSet.to_list())}"

    assert MapSet.difference(declared, actual) |> MapSet.to_list() == ["adopted", "archived"],
           "the set of DECLARED-but-unpaintable labels changed. It was [adopted, archived] — " <>
             "two words no input can reach, which is the reason this guard calls the fold " <>
             "instead of reading the label map."
  end

  test "FENCE: the probe proves BY RUNNING that suspension fences the control plane's door, not the host" do
    obs = observe(%{state: "stopped", reason: "billing_lapsed", producer: :cancel_subscription})

    assert {:ok, _} = obs.mint_before,
           "the probe's precondition failed — minting must SUCCEED before the producer runs or " <>
             "nothing after it can be attributed"

    # …and the row it minted against IS suspended by the time the second mint
    # runs, or "against the suspended row" would be a sentence about nothing.
    assert obs.reloaded.suspended
    assert obs.reloaded.suspended_reason == "billing_lapsed"

    {verdict, detail} = obs.fence

    # THIS ARM IS THE ONE THAT WATCHES THE FENCE ITSELF. It was inverted when
    # `mint_studio_link/2` grew its `%Barkpark{suspended: true}` clause: before
    # that clause the probe reported :no_fence, and this arm asserted it. Deleting
    # or weakening that clause in cloud/lib now REDS here, by name — which is the
    # only reason the split below is safe to make.
    assert verdict == :fence,
           "the fence probe reported #{inspect(verdict)}: #{detail}. Cloud is expected to REFUSE " <>
             "to mint against a suspended row — if that refusal is gone, a suspension fence was " <>
             "deleted or weakened in cloud/lib, and this manifest must be re-derived by hand " <>
             "rather than by editing this assertion."

    assert detail =~ "refused after it"

    # ATTRIBUTION, not merely refusal. `fence_verdict/2` reports :fence for ANY
    # post-producer refusal, so a producer that also broke the row some other way
    # (`:not_live`, `:no_admin_token`) would score a fence this class did not
    # earn. The class is named for the suspension clause, so the reason is pinned
    # to it here — the probe's own moduledoc promise ("refuses to report a fence
    # it cannot attribute") is only kept if the attribution is asserted.
    assert detail =~ ":suspended",
           "the fence probe refused after the producer, but not with {:error, :suspended}: " <>
             "#{detail}. :cp_access_fence names the suspension clause specifically; a refusal " <>
             "for any other reason is a broken row, not the fence this class claims to observe."

    assert MapSet.member?(obs.observed, :cp_access_fence)

    # …and that observation stays on the NON-halting side. This is the split's
    # own tripwire: moving :cp_access_fence back into @halting_classes (the cheap
    # way to buy a green crown, now wearing a different name) reds HERE as well as
    # in TAXONOMY and CROWN.
    assert MapSet.disjoint?(obs.observed, @halting_classes),
           "the suspension producer now observes a HALTING mechanism " <>
             "#{inspect(MapSet.intersection(obs.observed, @halting_classes) |> MapSet.to_list())} " <>
             "— a credential refusal is not a halt, so either a real data-plane block was added " <>
             "or :cp_access_fence was reclassified to buy a green crown."
  end

  test "FENCE: a broken precondition reports INDETERMINATE, never a fence" do
    # THE DEFECT THIS ARM EXISTS FOR. A naive one-shot probe scored a box with no
    # admin token as FENCED: minting refused with `:no_admin_token` and the probe
    # read the refusal as suspension doing something. With the discriminator it
    # refuses to attribute anything.
    team = team_fixture()
    bp = tokenless_box(team)
    StudioLinkFakeHttpClient.program([])

    mint_before = Registry.mint_studio_link(bp)
    assert {:error, :no_admin_token} = mint_before

    {verdict, detail} = fence_verdict(mint_before, bp)

    assert verdict == :indeterminate,
           "a probe whose precondition failed must report INDETERMINATE, got #{inspect(verdict)}"

    assert detail =~ "minting already failed BEFORE the producer ran"
    assert detail =~ "no fence is claimed either way"
  end

  test "ABSENCES: :power and :agent_command are absent, and a scan that stops finding one flunks" do
    for class <- [:power, :agent_command] do
      case absence(class) do
        {:absent, detail} ->
          assert is_binary(detail) and detail != ""

        {:indeterminate, detail} ->
          flunk(
            "#{inspect(class)} is no longer a declarative absence: #{detail}. This manifest " <>
              "treats it as 'no caller exists to run', which is now unsafe — re-derive the " <>
              "(state, reason) rows by hand before touching this assertion."
          )
      end
    end
  end

  test "META: every row actually ran its producer, and the manifest observed something for each" do
    # Without this, gutting `observe/1` would leave a green suite that compared
    # nothing — the CROWN arm's obligation discharges on an EMPTY observed set.
    results = Enum.map(@rows, &observe/1)

    assert length(results) == length(@rows)

    for obs <- results do
      refute MapSet.size(obs.observed) == 0,
             "(#{obs.row.state}, #{obs.row.reason}) observed NOTHING — the producer did not run, " <>
               "or every observer is broken. An empty observed set must never read as agreement."

      assert obs.reloaded.suspended
      assert obs.reloaded.suspended_reason == obs.row.reason
      assert obs.reloaded.suspended_at, "the state change stamped no time"
    end

    # And the row set itself is non-empty and keyed on the pair.
    assert length(@rows) == 3
    assert Enum.uniq_by(@rows, &{&1.state, &1.reason}) == @rows
  end
end
