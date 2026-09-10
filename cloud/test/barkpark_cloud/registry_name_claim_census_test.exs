defmodule BarkparkCloud.RegistryNameClaimCensus.Extract do
  @moduledoc """
  The Side-A extractor: the leg atoms `Registry.claim_leg/2` can return, read
  off the Elixir AST (`Code.string_to_quoted!/1`), never off a per-line regex.

  Why not a per-line regex. A `{:held, :<leg>, "<why>"}` tuple is only complete
  on ONE line when its `why` sentence is short. On today's tree four of the six
  legs wrap across lines, so a per-line regex that matches a complete tuple
  finds 2 of 6 — it is 67% blind, and blind SILENTLY. `single_line_legs/1`
  reproduces that blind reading so the test can quote both counts side by side,
  and `wrap_every_leg/1` rewrites the source so EVERY leg wraps: the AST still
  reads 6, the regex drops to 0.

  Bounded on purpose: this walks the ONE function `claim_leg/2` and collects
  the `{:held, leg, why}` tuples in source order. It does not follow calls, and
  it does not read the legs' predicates — see the census test's moduledoc for
  the honest limit that follows from that.
  """

  @doc "The `{:held, leg, _}` atoms `claim_leg/2` returns, in SOURCE ORDER."
  @spec legs(binary) :: [atom]
  def legs(source) when is_binary(source) do
    source
    |> fun_ast(:claim_leg, 2)
    |> held_atoms()
  end

  @doc """
  The blind reading: legs whose `{:held, :leg, "why"}` tuple happens to fit on
  a single line. Kept only so the test can quote what the naive check misses.
  """
  @spec single_line_legs(binary) :: [atom]
  def single_line_legs(source) when is_binary(source) do
    source
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/\{:held, :([a-z_]+), ".*"\}/, line) do
        [_, leg] -> [String.to_atom(leg)]
        nil -> []
      end
    end)
  end

  @doc "Rewrite `source` so every `{:held, …}` tuple wraps across lines."
  @spec wrap_every_leg(binary) :: binary
  def wrap_every_leg(source) when is_binary(source),
    do: String.replace(source, "{:held,", "{:held,\n")

  @doc "The integer value of a module attribute defined as `@name <int>`."
  @spec module_attr(binary, atom) :: integer | nil
  def module_attr(source, name) when is_binary(source) and is_atom(name) do
    {_, value} =
      source
      |> Code.string_to_quoted!(emit_warnings: false)
      |> Macro.prewalk(nil, fn
        {:@, _, [{^name, _, [v]}]} = node, _acc when is_integer(v) -> {node, v}
        node, acc -> {node, acc}
      end)

    value
  end

  @doc """
  The subscription statuses `provisioning_fqdn_claim/2` treats as LIVE, read
  out of the one SQL fragment inside that function (scoped to the function so
  an unrelated `subscriptions` query elsewhere cannot answer for it).
  """
  @spec live_subscription_statuses(binary) :: [binary]
  def live_subscription_statuses(source) when is_binary(source) do
    fragment =
      source
      |> fun_ast(:provisioning_fqdn_claim, 2)
      |> binaries()
      |> Enum.find(&(&1 =~ "FROM subscriptions s"))

    case fragment && Regex.run(~r/s\.status IN \(([^)]*)\)/, fragment) do
      [_, list] ->
        list |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.trim("'")))

      _ ->
        raise "no `s.status IN (…)` fragment inside provisioning_fqdn_claim/2"
    end
  end

  ## AST plumbing

  # The def/defp body for name/arity. `:when`-guarded heads are unwrapped: an
  # AST match that forgets to is silently blind to every guarded clause.
  defp fun_ast(source, name, arity) do
    {_, found} =
      source
      |> Code.string_to_quoted!(emit_warnings: false)
      |> Macro.prewalk(nil, fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          case head_sig(head) do
            {^name, ^arity} -> {node, body}
            _ -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    found || raise "#{name}/#{arity} not found — did it get renamed or deleted?"
  end

  defp head_sig({:when, _, [head | _]}), do: head_sig(head)
  defp head_sig({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp head_sig(_), do: nil

  defp held_atoms(ast) do
    {_, legs} =
      Macro.prewalk(ast, [], fn
        {:{}, _, [:held, leg, _]} = node, acc when is_atom(leg) -> {node, [leg | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(legs)
  end

  defp binaries(ast) do
    {_, bins} =
      Macro.prewalk(ast, [], fn
        b, acc when is_binary(b) -> {b, [b | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(bins)
  end
end

defmodule BarkparkCloud.RegistryNameClaimCensusTest do
  @moduledoc """
  A name-claim leg cannot be deleted, renamed, dead-coded or gutted without
  something reporting it.

  `Registry.provisioning_fqdn_claim/2` decides whether a hostname another
  tenant's box is still being dialled with can be handed to the next tenant —
  the predicate behind the live gyldendal cross-tenant transmission. Widening
  it is a one-line edit, and until this file nothing anywhere reported that its
  coverage had SHRUNK. Two rungs, because either alone is vacuous:

    * RUNG 1 (source census) — the leg atom SET and its hard-block-first ORDER,
      derived by AST walk, plus the three coverage CONSTANTS. Catches a leg
      deleted, renamed, or reordered, and catches the guard being GUTTED
      without a leg being deleted (7 days → 0, 24h → 1, `past_due` dropped).
    * RUNG 2 (behaviour) — one case per leg plus `:free`, because a DEAD-CODED
      leg passes a source census: `row.active_job and false ->` leaves rung 1
      fully green. Rung 1 proves the leg is written; rung 2 proves it fires.

  ## The honest limit

  This guards the leg SET, their ORDER, and the three constants — NOT a leg's
  own internal predicate. `row.has_admin_token` could be narrowed to
  `row.has_admin_token and row.something_else` and rung 1 stays green; rung 2
  catches it only if the behavioural fixture happens to violate the new
  conjunct. A leg can also be weakened at its SOURCE — the `select` that
  computes `has_admin_token` / `recent_sample` / `live_subscription` is not
  censused here. Those are the next rung, and they are not built.

  This guard has NO human reader. Nothing prints its result to an operator;
  it fires only in CI, only on a diff that touches these lines. So it has to be
  provable by mutation rather than by inspection — the three recipes below were
  RUN, and each is quoted with the failure it produced:

      MUTATION 1 (a leg deleted): delete the `row.has_admin_token ->` clause in
      registry.ex claim_leg/2. Rung 1 reds naming the released population
      ("rows the platform can still decrypt a live admin bearer token for"),
      and the :admin_credential behavioural case reds with `right: :free`.

      MUTATION 2 (a leg dead-coded): change `row.active_job ->` to
      `row.active_job and false ->`. Rung 1 stays FULLY GREEN — the atom is
      still written — and ONLY the :active_job behavioural case reds with
      `right: :free`. This is the proof that a source census alone is vacuous.

      MUTATION 3 (the guard gutted, no leg touched): drop `'past_due'` from the
      `s.status IN ('active','past_due')` fragment in provisioning_fqdn_claim/2.
      The live-status pin reds ALONE. The three constants are pinned in THREE
      SEPARATE tests on purpose: stacked in one body, the first failing assert
      shadows the other two, so a diff moving all three would report only one.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.RegistryNameClaimCensus.Extract
  alias BarkparkCloud.Usage.Sample

  @source Path.expand("../../lib/barkpark_cloud/registry.ex", __DIR__)

  # The declared legs, in the order claim_leg/2 must evaluate them, each with
  # the POPULATION it protects — the sentence a failure prints, because the
  # cost of deleting a leg is which rows stop being protected, not which atom
  # stops existing.
  @legs [
    {:admin_credential, "rows the platform can still decrypt a live admin bearer token FOR"},
    {:recent_usage_sample,
     "rows the usage sampler reached inside the window — proof of an in-flight platform→instance transmission"},
    {:active_subscription, "rows owned by a team on a live subscription — billed customers"},
    {:agent_reporting, "rows whose agent HAS phoned home at least once"},
    {:active_job, "rows with a pending/claimed provision job in flight"},
    {:within_grace, "rows younger than the abandonment window — still provisioning"}
  ]

  @expected_legs Enum.map(@legs, &elem(&1, 0))

  defp source, do: File.read!(@source)

  ## ─────────────────────────────────────────────────────────────────────────
  ## RUNG 1 — the source census
  ## ─────────────────────────────────────────────────────────────────────────

  describe "rung 1: the leg set" do
    test "is EXACTLY the six declared legs, hard-block-first, in order" do
      actual = Extract.legs(source())

      assert MapSet.new(actual) == MapSet.new(@expected_legs), set_message(actual)

      assert actual == @expected_legs,
             """
             claim_leg/2's legs are the right SET but the wrong ORDER.

               expected: #{inspect(@expected_legs)}
                 actual: #{inspect(actual)}

             Order is load-bearing: the two hard blocks (:admin_credential,
             :recent_usage_sample) are named FIRST so the refusal an operator
             reads names the leg they must consciously delete to widen the
             carve-out. A reorder changes which leg gets the blame.
             """
    end

    test "the AST extractor sees legs a per-line regex cannot (6 vs 2 today)" do
      src = source()

      assert length(Extract.legs(src)) == 6
      assert Extract.single_line_legs(src) == [:agent_reporting, :active_job]
    end

    test "EXTRACTOR MUTATION: wrap every leg → AST still 6, per-line regex 0" do
      wrapped = Extract.wrap_every_leg(source())

      assert Extract.legs(wrapped) == @expected_legs
      assert Extract.single_line_legs(wrapped) == []
    end
  end

  # Three separate tests on purpose — see MUTATION 3 in the moduledoc.
  describe "rung 1: the coverage constants" do
    test "the abandonment window is 7 days" do
      assert Extract.module_attr(source(), :abandoned_claim_after_days) == 7,
             "shrinking the abandonment window releases YOUNGER silent rows — rows that " <>
               "may still be mid-provision — to the next tenant"
    end

    test "the recent-sample window is 24 hours" do
      assert Extract.module_attr(source(), :recent_sample_window_hours) == 24,
             "shrinking the sample window releases rows the sampler reached RECENTLY, " <>
               "i.e. hosts the platform is demonstrably still transmitting to"
    end

    test "the live subscription statuses are active and past_due" do
      assert Extract.live_subscription_statuses(source()) == ["active", "past_due"],
             "dropping a status releases the names of PAYING customers; past_due is a " <>
               "billed customer with a failed charge, not a cancelled one"
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## RUNG 2 — one behavioural case per leg, plus :free
  ## ─────────────────────────────────────────────────────────────────────────

  describe "rung 2: every leg actually fires" do
    test ":admin_credential — a decryptable admin token holds the name" do
      team = team_fixture()
      ghost = ghost_row(team, "leg-credential.barkpark.cloud")
      ghost |> Ecto.Changeset.change(admin_token_encrypted: "ciphertext") |> Repo.update!()

      assert {:held, :admin_credential, why} =
               Registry.provisioning_fqdn_claim("leg-credential.barkpark.cloud")

      assert why =~ "decryptable admin token"
    end

    test ":recent_usage_sample — a sample inside the window holds the name" do
      team = team_fixture()
      ghost = ghost_row(team, "leg-sample.barkpark.cloud")

      Repo.insert!(%Sample{
        barkpark_id: ghost.id,
        envelope: %{"meters" => %{}},
        measured_at: DateTime.add(DateTime.utc_now(), -5, :minute)
      })

      assert {:held, :recent_usage_sample, why} =
               Registry.provisioning_fqdn_claim("leg-sample.barkpark.cloud")

      assert why =~ "sampled by the usage worker"
    end

    test ":active_subscription — a live subscription holds the name" do
      team = team_fixture()
      ghost_row(team, "leg-subscription.barkpark.cloud")
      Repo.insert!(%Subscription{team_id: team.id, plan: "supporter", status: "active"})

      assert {:held, :active_subscription, why} =
               Registry.provisioning_fqdn_claim("leg-subscription.barkpark.cloud")

      assert why =~ "live subscription"
    end

    test ":agent_reporting — a row that phoned home holds the name" do
      team = team_fixture()

      team
      |> ghost_row("leg-reporting.barkpark.cloud")
      |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
      |> Repo.update!()

      assert {:held, :agent_reporting, why} =
               Registry.provisioning_fqdn_claim("leg-reporting.barkpark.cloud")

      assert why =~ "phoned home"
    end

    # This leg had NO test of any kind before this file.
    test ":active_job — a provision job in flight holds the name" do
      team = team_fixture()
      ghost = ghost_row(team, "leg-job.barkpark.cloud")
      {:ok, _job} = Registry.enqueue_provision_job(ghost)

      assert {:held, :active_job, why} =
               Registry.provisioning_fqdn_claim("leg-job.barkpark.cloud")

      assert why =~ "in flight"
    end

    test ":within_grace — a young silent row holds the name" do
      bp = barkpark_fixture(team_fixture())

      bp
      |> Ecto.Changeset.change(url: "https://leg-grace.barkpark.cloud")
      |> Repo.update!()

      assert {:held, :within_grace, why} =
               Registry.provisioning_fqdn_claim("leg-grace.barkpark.cloud")

      assert why =~ "abandonment window"
    end

    # Carries the two boundary NEGATIVES that moved here from
    # registry_attach_domain_test.exs (a sample outside the window, a cancelled
    # subscription): neither is a live leg, so this row is a genuine ghost.
    test ":free — a row no leg holds releases the name, sample and status OUTSIDE the sets" do
      team = team_fixture()
      ghost = ghost_row(team, "leg-free.barkpark.cloud")

      Repo.insert!(%Sample{
        barkpark_id: ghost.id,
        envelope: %{"meters" => %{}},
        measured_at: DateTime.add(DateTime.utc_now(), -49, :hour)
      })

      Repo.insert!(%Subscription{team_id: team.id, plan: "supporter", status: "canceled"})

      assert :free = Registry.provisioning_fqdn_claim("leg-free.barkpark.cloud")
    end
  end

  ## ─────────────────────────────────────────────────────────────────────────
  ## RUNG 3 — the leg REACHES A HUMAN, and the operator sentence does not
  ## (dr-w26-bl-claim-leg-refusal-reaches-no-human)
  ## ─────────────────────────────────────────────────────────────────────────

  # One holder per leg, keyed by the leg it is built to fire. The hosts are
  # distinct so the six can be built inside one test without colliding.
  @leg_holders %{
    admin_credential: "disclosure-credential.barkpark.cloud",
    recent_usage_sample: "disclosure-sample.barkpark.cloud",
    active_subscription: "disclosure-subscription.barkpark.cloud",
    agent_reporting: "disclosure-reporting.barkpark.cloud",
    active_job: "disclosure-job.barkpark.cloud",
    within_grace: "disclosure-grace.barkpark.cloud"
  }

  describe "rung 3: provisioning_fqdn_claim_disclosure/2 renders every leg for the caller" do
    # Side A again: the leg set is read off `claim_leg/2`'s AST, not typed here.
    # A leg added to the predicate with no caller-facing sentence reds THIS arm
    # rather than silently rendering the generic fallback on the wire.
    test "the render is TOTAL over the legs the predicate can return" do
      assert Enum.sort(Extract.legs(source())) == Enum.sort(Map.keys(@leg_holders)),
             """
             `claim_leg/2` returns #{inspect(Extract.legs(source()))} but the caller-facing
             render is exercised for #{inspect(Map.keys(@leg_holders))}. A leg with no
             caller sentence still reaches the wire as an atom, and its `detail` falls
             back to the generic line — write it one, and add it here.
             """
    end

    test "each leg lands on the disclosure map with a caller sentence of its own" do
      details =
        for {leg, host} <- @leg_holders, into: %{} do
          team = team_fixture()
          ghost = hold(leg, team, host)

          assert {:held, ^leg, why} = Registry.provisioning_fqdn_claim(host)

          disclosure = Registry.provisioning_fqdn_claim_disclosure(host)

          assert disclosure.claim_leg == Atom.to_string(leg),
                 "#{leg}: the disclosure map carried #{inspect(disclosure.claim_leg)}"

          # THE FENCE. The operator sentence opens `row <uuid>` and three legs
          # characterise the holder further; the caller is routinely another
          # team, so none of that may cross the wire.
          assert why =~ ghost.id
          refute disclosure.detail =~ ghost.id
          refute disclosure.detail =~ ghost.team_id
          refute disclosure.detail =~ "row "
          refute disclosure.detail == why

          {leg, disclosure.detail}
        end

      # Not one sentence six times: a render that collapsed every leg onto the
      # fallback would satisfy every assertion above.
      assert length(Enum.uniq(Map.values(details))) == map_size(details),
             "two legs render the SAME sentence, so the leg is not doing any work: " <>
               inspect(details)
    end

    test "a name no leg holds contributes NO keys — the refusal stays bare" do
      team = team_fixture()
      ghost_row(team, "disclosure-free.barkpark.cloud")

      assert :free = Registry.provisioning_fqdn_claim("disclosure-free.barkpark.cloud")
      assert Registry.provisioning_fqdn_claim_disclosure("disclosure-free.barkpark.cloud") == %{}
    end

    test "self_id excludes the asking row, so a re-attach discloses nothing" do
      team = team_fixture()

      mine =
        team
        |> ghost_row("disclosure-mine.barkpark.cloud")
        |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
        |> Repo.update!()

      assert %{claim_leg: "agent_reporting"} =
               Registry.provisioning_fqdn_claim_disclosure("disclosure-mine.barkpark.cloud")

      assert Registry.provisioning_fqdn_claim_disclosure(
               "disclosure-mine.barkpark.cloud",
               mine.id
             ) == %{}
    end
  end

  # Build a row that holds `host` on exactly `leg`. Every one but `:within_grace`
  # starts from `ghost_row/2` (old and silent), so the leg under construction is
  # the only thing keeping the claim.
  defp hold(:admin_credential, team, host) do
    team
    |> ghost_row(host)
    |> Ecto.Changeset.change(admin_token_encrypted: "ciphertext")
    |> Repo.update!()
  end

  defp hold(:recent_usage_sample, team, host) do
    ghost = ghost_row(team, host)

    Repo.insert!(%Sample{
      barkpark_id: ghost.id,
      envelope: %{"meters" => %{}},
      measured_at: DateTime.add(DateTime.utc_now(), -5, :minute)
    })

    ghost
  end

  defp hold(:active_subscription, team, host) do
    ghost = ghost_row(team, host)
    Repo.insert!(%Subscription{team_id: team.id, plan: "supporter", status: "active"})
    ghost
  end

  defp hold(:agent_reporting, team, host) do
    team
    |> ghost_row(host)
    |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp hold(:active_job, team, host) do
    ghost = ghost_row(team, host)
    {:ok, _job} = Registry.enqueue_provision_job(ghost)
    ghost
  end

  # The one leg a ghost row cannot carry: it fires on YOUTH, so the row must be
  # fresh rather than 30 days old.
  defp hold(:within_grace, team, host) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(url: "https://" <> host)
    |> Repo.update!()
  end

  ## Fixtures

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  # The silence-only "ghost" shape: url squats `host`, the agent never phoned
  # home, the row is older than the abandonment window, no jobs. Every leg
  # under test is added to THIS shape, one at a time.
  defp ghost_row(team, host) do
    team
    |> barkpark_fixture()
    |> Ecto.Changeset.change(
      url: "https://" <> host,
      inserted_at: DateTime.add(DateTime.utc_now(), -30, :day)
    )
    |> Repo.update!()
  end

  ## Failure copy

  defp set_message(actual) do
    missing = @expected_legs -- actual
    added = actual -- @expected_legs

    """
    claim_leg/2's leg SET has changed.

    #{released(missing)}#{unreviewed(added)}
      expected: #{inspect(@expected_legs)}
        actual: #{inspect(actual)}

    A deleted or renamed leg RELEASES a population of hostnames to the next
    tenant. If that is intended, change @legs here in the same commit and say
    in the message which population you are releasing.
    """
  end

  defp released([]), do: ""

  defp released(missing) do
    lines =
      Enum.map_join(missing, "\n", fn leg ->
        "      * #{inspect(leg)} — releases #{Keyword.fetch!(@legs, leg)}"
      end)

    "    LEGS GONE — the names these rows hold become claimable:\n#{lines}\n\n"
  end

  defp unreviewed([]), do: ""

  defp unreviewed(added) do
    "    LEGS ADDED, unreviewed by this census: #{inspect(added)}\n\n"
  end
end
