defmodule BarkparkCloud.PromiseActorManifestTest do
  @moduledoc """
  cch-w55-s4 — THE PROMISE-ACTOR REGISTER.

  The console renders sentences about a FUTURE ACT: "your instances are paused
  after the grace period", "your plan stays active until the end of the billing
  period", "your trial ends on …". Each such sentence is a promise that
  something WILL happen on a day nobody is watching. This register pins, per
  promise, the only three things that can make one true:

    * CLOCK  — does anything reach that day at all?
    * ACTOR  — does something RUN on it?
    * EFFECT — can that actor produce the effect the copy names?

  Key: `{reason, transition}`. The PAIR is load-bearing: one reason (`trial`)
  contributes a DISCHARGED row and an UNSUPPORTED row, so this register proves
  it DISCRIMINATES rather than merely agreeing with itself. A register keyed on
  the bare reason would be false on its own fixture, and there is an arm below
  that asserts exactly that.

  ── HOW EACH COLUMN IS READ ────────────────────────────────────────────────

  Every verdict is resolved BY RUNNING on this booted BEAM. Nothing here is
  transcribed prose.

    * CLOCK is read off `Application.get_env(:barkpark_cloud, Oban)[:plugins]`
      — the crontab the application is CONFIGURED with — never off the text of
      `config/config.exs`. The full read is compared by EQUALITY against
      `@scheduled_crontab` pinned in this file. Equality, not a
      `/Billing|Dunning|Grace/` name heuristic: a real enforcement worker named
      `ArrearsWorker` walks straight through a heuristic, and the register would
      stay green claiming ABSENT while the clock had in fact arrived. Under
      equality, ANY added row reds here naming the row verbatim — which works
      even when the named module does not exist, because a crontab entry is
      just a term in config.

    * ACTOR on the DISCHARGED row is the REAL producer, run
      (`perform_job(TrialExpiryWorker, %{})` under Oban `:manual`) with an
      observer pre-armed on an EFFECT ROW — a `ProvisionJob` with
      `kind: "deprovision"`. A cron probe MAY NOT be labelled ACTOR (charter
      D635): "a crontab row names this module and the module loads" survives a
      `perform/1` gutted to a bare `:ok`. Measured in this epic —
      `AutoupdateRolloutWorker.perform/1` neutered to `:ok` left
      `sold_capability_manifest_test.exs` at 6/6 green while the
      effect-observing worker test went 9/11. So a cron row is CLOCK evidence
      and only CLOCK evidence; ACTOR always costs a run.

    * ACTOR on an ABSENCE row is not "unverified" — it is resolved too. The
      `billing_past_due` promise's only enforcement branch is reached from a
      single call site, and the same delivery that could fire it re-anchors the
      grace window forward, so the arm DRIVES that path and observes that no
      box is ever suspended by it.

    * EFFECT asserts what a suspension actually IS: one `Repo.update_all` in
      `suspend_team_barkparks/2` touching exactly four columns, observed as the
      set of fields that change on a real row. The only `poweroff` anywhere in
      `cloud/lib` is an uncalled catalog entry in `registry/hetzner_catalog.ex`
      — asserted by reading the tree, not described here.

  ── SCOPE. Quote this register's green for exactly this much ───────────────

    1. A green certifies, per row: "this promised act HAS / HAS NOT a clock, a
       scheduled actor, and a producible effect." It NEVER certifies that the
       billing system is correct, that the copy is well worded, or that the
       effect is the right one to have.
    2. An `:absent` clock verdict is only as strong as the crontab equality pin
       above it. It says "no configured schedule reaches this day", not "no
       code anywhere could ever run".
    3. A `:flag_only` effect verdict is a statement about the CONTROL PLANE: a
       row's flags flip and the dashboard and agent gate honour them. Whether
       any machine is physically stopped is out of its reach — the same
       boundary `Registry.delete_barkpark/1` documents.
    4. The rows here are the promises this wave read. A promise the console
       makes that has no row is simply unexamined; this register cannot see it.
       That is what the ADD direction of `sold_capability_manifest_test.exs`
       does for the plan card's bullets, and it is deliberately NOT duplicated
       here — this file is a sibling guard, not an extension of that one.
  """

  # async: true — every DB touch is inside the SQL sandbox, the config reads are
  # pure, and Oban runs in :manual mode (config/test.exs) so perform_job/2 runs
  # the worker synchronously inside this test's own transaction.
  use BarkparkCloud.DataCase, async: true
  use Oban.Testing, repo: BarkparkCloud.Repo

  alias BarkparkCloud.{Accounts, Billing, Registry, Repo}
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Registry.{Barkpark, ProvisionJob}
  alias BarkparkCloud.Workers.TrialExpiryWorker

  @password "correct horse battery staple"

  # THE CRONTAB, PINNED HERE AND COMPARED BY EQUALITY. Declared by neither the
  # console nor the config: that is the only reason an ABSENT clock verdict can
  # lose. Fourteen rows today.
  @scheduled_crontab [
    {"* * * * *", BarkparkCloud.Workers.StaleProvisionJobReaper},
    {"* * * * *", BarkparkCloud.Workers.DeviceAuthReaper},
    {"* * * * *", BarkparkCloud.Workers.OAuthStateReaper},
    {"* * * * *", BarkparkCloud.Workers.SseTicketReaper},
    {"* * * * *", BarkparkCloud.Workers.OAuthExchangeReaper},
    {"* * * * *", BarkparkCloud.Workers.StaleDeploymentReaper},
    {"* * * * *", BarkparkCloud.Health.StalenessWorker},
    {"0 * * * *", BarkparkCloud.Workers.TrialExpiryWorker},
    {"17 * * * *", BarkparkCloud.Workers.UpdateStatusWorker},
    {"*/5 * * * *", BarkparkCloud.Workers.AutoupdateRolloutWorker},
    {"7,22,37,52 * * * *", BarkparkCloud.Workers.UsageSamplerWorker},
    {"30 3 * * *", BarkparkCloud.Workers.AgentRetentionWorker},
    {"0 6 * * *", BarkparkCloud.Workers.DailyDigestWorker},
    {"41 * * * *", BarkparkCloud.Sites.TemplateFreshnessWorker}
  ]

  # THE REGISTER. Each key is a promise the console makes about a future act;
  # each value names how its three columns are RESOLVED (not what they are —
  # the resolvers below decide that by running).
  @register %{
    # The grace-period promise. The only branch that could keep it
    # (`maybe_enforce/1`) has ONE call site, inside `mark_past_due/2`, reachable
    # only from the Stripe `invoice.payment_failed` arm — and that same call
    # re-anchors the grace window to now+3d when the webhook passes no attrs,
    # which it never does. The one event that could fire the branch is the one
    # that pushes it out of reach.
    {"billing_past_due", :suspend_on_grace_elapse} => %{
      clock: :crontab_absent,
      actor: {:unreachable, :grace_reanchors_on_every_delivery},
      effect: {:flag_only, :suspend_update_all}
    },

    # Immediate self-serve cancel. A REAL non-admin write path: POST
    # /v1/billing/cancel with at_period_end: false → request_cancel/2 →
    # cancel_subscription/1, gated by team ownership + password only.
    {"billing_lapsed", :cancel_immediate} => %{
      clock: :synchronous,
      actor: {:synchronous_call, :request_cancel_immediate},
      effect: {:flag_only, :suspend_update_all}
    },

    # "Your plan stays active until the end of the billing period." Nothing in
    # this plane reaches that boundary: no crontab row, nothing local reads
    # `cancel_at_period_end` to decide entitlement, and for a paid plan the
    # named boundary has NO STORED VALUE at all.
    {"billing_lapsed", :cancel_at_period_end} => %{
      clock: {:external_only, :stripe},
      actor: :none_local,
      effect: {:unread, :cancel_at_period_end}
    },

    # The downgrade ceiling. Synchronous off the plan transition, no clock.
    {"quota_exceeded", :downgrade_suspend} => %{
      clock: :synchronous,
      actor: {:synchronous_call, :reconcile_plan_limit},
      effect: {:flag_only, :suspend_update_all}
    },

    # THE POSITIVE CONTROL — DISCHARGED. Hourly clock, real producer run, and
    # the effect it names is observed on an effect row.
    {"trial", :expire_teardown} => %{
      clock: {:crontab_row, TrialExpiryWorker, "0 * * * *"},
      actor: {:producer_run, :teardown_enqueued},
      effect: {:produced, :deprovision_job}
    },

    # THE SPLIT CONTROL — UNSUPPORTED, and it shares the `trial` reason with the
    # row above. Same clock, same actor, DIFFERENT effect: the console's
    # "you'll drop to the free plan" has no writer anywhere — the worker never
    # touches the Subscription row's plan.
    {"trial", :land_on_free} => %{
      clock: {:crontab_row, TrialExpiryWorker, "0 * * * *"},
      actor: {:producer_run, :teardown_enqueued},
      effect: {:absent, :free_plan_write}
    }
  }

  ## ── Fixtures ───────────────────────────────────────────────────────────

  defp team_with_owner do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.register_user(%{email: "promise-#{n}@example.com", password: @password})

    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    team
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  defp trial_sub(team, offset_seconds) do
    ends =
      DateTime.utc_now()
      |> DateTime.add(offset_seconds, :second)
      |> DateTime.truncate(:microsecond)

    {:ok, sub} =
      %Subscription{}
      |> Subscription.changeset(%{
        team_id: team.id,
        plan: "trial",
        status: "active",
        current_period_end: ends
      })
      |> Repo.insert()

    sub
  end

  defp reload_bp(%Barkpark{id: id}), do: Repo.get!(Barkpark, id)

  defp deprovision_jobs(bp_id) do
    Repo.all(from(j in ProvisionJob, where: j.barkpark_id == ^bp_id and j.kind == "deprovision"))
  end

  ## ── CLOCK ──────────────────────────────────────────────────────────────

  # The crontab the APPLICATION is configured with, read off this booted BEAM.
  defp configured_crontab do
    plugins = Application.get_env(:barkpark_cloud, Oban)[:plugins] || []

    Enum.find_value(plugins, [], fn
      {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
      _ -> nil
    end)
    |> Enum.map(fn
      {schedule, worker} -> {schedule, worker}
      {schedule, worker, _opts} -> {schedule, worker}
    end)
  end

  # EQUALITY, not a name heuristic. Returns the sorted read so a red can print
  # the exact rows that appeared or vanished.
  defp crontab_agrees do
    read = Enum.sort(configured_crontab())
    pinned = Enum.sort(@scheduled_crontab)

    added = read -- pinned
    removed = pinned -- read

    cond do
      added != [] ->
        {:error,
         "the configured crontab gained #{inspect(added)}. Every ABSENT clock verdict in this " <>
           "register is only true while the crontab is exactly what it pins. Classify the new " <>
           "row: if it is the actor a promise here was missing, move that row's verdict; if it " <>
           "is unrelated, add it to @scheduled_crontab in the same commit."}

      removed != [] ->
        {:error,
         "the configured crontab lost #{inspect(removed)} — a scheduled actor this register " <>
           "counted on is gone"}

      true ->
        {:ok, "crontab equality holds over #{length(read)} rows"}
    end
  end

  defp resolve_clock(:crontab_absent) do
    case crontab_agrees() do
      {:ok, detail} -> {:ok, "ABSENT — #{detail}, and none of them reaches this promise"}
      err -> err
    end
  end

  defp resolve_clock({:crontab_row, worker, schedule}) do
    read = configured_crontab()

    cond do
      {schedule, worker} not in read ->
        {:error,
         "no crontab row schedules #{inspect(worker)} at #{inspect(schedule)} — the configured " <>
           "rows are #{inspect(read)}"}

      not Code.ensure_loaded?(worker) ->
        {:error, "#{inspect(worker)} is scheduled but the module does not load"}

      true ->
        {:ok, "PRESENT — #{inspect(worker)} at #{schedule}"}
    end
  end

  defp resolve_clock({:external_only, :stripe}) do
    # Two things must hold for "external only": no local schedule reaches the
    # boundary (the equality read), AND nothing local honours the flag when the
    # day comes. The second is a RUN, not a reading.
    with {:ok, detail} <- crontab_agrees() do
      team = team_with_owner()
      {:ok, sub} = Billing.subscribe(team, "supporter")
      {:ok, sub} = sub |> Subscription.changeset(%{cancel_at_period_end: true}) |> Repo.update()

      cond do
        not Billing.entitled?(team) ->
          {:error,
           "entitled?/1 DID honour cancel_at_period_end — this promise has a local reader after " <>
             "all, so the clock verdict must be re-derived"}

        not is_nil(sub.current_period_end) ->
          {:error,
           "the paid plan now stores a period end (#{inspect(sub.current_period_end)}) — the " <>
             "boundary this copy names has a value, so re-derive this row"}

        true ->
          {:ok,
           "EXTERNAL-ONLY — #{detail}; entitled?/1 stays true with cancel_at_period_end set, " <>
             "and a paid plan stores no current_period_end for the boundary to fall on"}
      end
    end
  end

  defp resolve_clock(:synchronous),
    do: {:ok, "N/A — the act completes in-band on the request that triggers it"}

  ## ── ACTOR ──────────────────────────────────────────────────────────────

  # The DISCHARGED row's actor: the REAL producer, run, with an observer
  # pre-armed on an effect row. A cron probe would not do — see the moduledoc.
  defp resolve_actor({:producer_run, :teardown_enqueued}) do
    team = team_with_owner()
    _sub = trial_sub(team, -3600)
    bp = barkpark_fixture(team)

    # Observer pre-armed: the effect row does not exist yet.
    assert deprovision_jobs(bp.id) == [],
           "the observer was not pre-armed — a deprovision job already existed before the run"

    case perform_job(TrialExpiryWorker, %{}) do
      {:ok, %{expired: expired, teardowns: teardowns}} when expired >= 1 and teardowns >= 1 ->
        case deprovision_jobs(bp.id) do
          [%ProvisionJob{kind: "deprovision"} = job] ->
            {:ok,
             "RAN — perform_job(TrialExpiryWorker) reported expired=#{expired} " <>
               "teardowns=#{teardowns} and the observer caught ProvisionJob #{job.id} " <>
               "(kind: \"deprovision\") on box #{bp.id}"}

          other ->
            {:error,
             "the producer ran but the observer caught no single deprovision row: #{inspect(other)}"}
        end

      other ->
        {:error, "perform_job(TrialExpiryWorker, %{}) returned #{inspect(other)}"}
    end
  end

  # The grace-elapse promise's actor, resolved by DRIVING the only path that
  # reaches it. mark_past_due/2 with no attrs is exactly what the
  # invoice.payment_failed webhook does; it re-anchors grace to now+3d before
  # maybe_enforce/1 looks at it, so the branch can never be true on that path.
  defp resolve_actor({:unreachable, :grace_reanchors_on_every_delivery}) do
    team = team_with_owner()
    {:ok, sub} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team)

    # First delivery, then a redelivery — the only shape this path takes.
    {:ok, _} = Billing.mark_past_due(sub)
    sub = Repo.get!(Subscription, sub.id)
    {:ok, _} = Billing.mark_past_due(sub)
    sub = Repo.get!(Subscription, sub.id)

    cond do
      reload_bp(bp).suspended ->
        {:error,
         "a bare mark_past_due/2 DID suspend the box — the grace branch is reachable after all, " <>
           "so this row's ACTOR verdict must be re-derived"}

      is_nil(sub.current_period_end) ->
        {:error, "the grace anchor was not written at all — re-derive this row"}

      DateTime.compare(sub.current_period_end, DateTime.utc_now()) != :gt ->
        {:error,
         "the grace anchor landed in the PAST (#{inspect(sub.current_period_end)}) — the " <>
           "re-anchor this verdict rests on is gone"}

      true ->
        {:ok,
         "UNREACHABLE — two deliveries of the only event that reaches maybe_enforce/1 left the " <>
           "box live and pushed the grace anchor forward to #{inspect(sub.current_period_end)}"}
    end
  end

  defp resolve_actor({:synchronous_call, :request_cancel_immediate}) do
    team = team_with_owner()
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team)

    case Billing.request_cancel(team, false) do
      {:ok, %Subscription{status: "canceled"}} ->
        if reload_bp(bp).suspended_reason == "billing_lapsed" do
          {:ok,
           "RAN — request_cancel(team, false) canceled the sub and suspended the box in-band"}
        else
          {:error, "request_cancel(team, false) canceled the sub but suspended nothing"}
        end

      other ->
        {:error, "request_cancel(team, false) returned #{inspect(other)}"}
    end
  end

  defp resolve_actor({:synchronous_call, :reconcile_plan_limit}) do
    team = team_with_owner()
    {:ok, sub} = Billing.subscribe(team, "support_plus")
    for _ <- 1..4, do: barkpark_fixture(team)

    {:ok, _} = sub |> Subscription.changeset(%{plan: "supporter"}) |> Repo.update()

    case Billing.reconcile_plan_limit(team) do
      %{suspended: 1, restored: 0} ->
        quota =
          Registry.list_barkparks(team) |> Enum.filter(&(&1.suspended_reason == "quota_exceeded"))

        if length(quota) == 1 do
          {:ok,
           "RAN — reconcile_plan_limit/1 suspended 1 box as quota_exceeded against a 3-box plan"}
        else
          {:error, "reconcile reported 1 suspend but #{length(quota)} rows carry quota_exceeded"}
        end

      other ->
        {:error,
         "reconcile_plan_limit/1 returned #{inspect(other)} against 4 boxes on a 3-box plan"}
    end
  end

  # NOT "unverified" — resolved by the same equality read that backs the clock,
  # plus the absence of any local reader (proven in the clock arm above).
  defp resolve_actor(:none_local) do
    with {:ok, detail} <- crontab_agrees() do
      {:ok, "NONE LOCAL — #{detail}; no scheduled worker and no in-band caller reaches this act"}
    end
  end

  ## ── EFFECT ─────────────────────────────────────────────────────────────

  # What a suspension IS: the set of columns that change on a real row, plus the
  # tree fact that nothing in cloud/lib powers a machine off.
  defp resolve_effect({:flag_only, :suspend_update_all}) do
    team = team_with_owner()
    bp = barkpark_fixture(team)

    before = Map.from_struct(reload_bp(bp))
    {:ok, 1} = Registry.suspend_team_barkparks(team, "billing_lapsed")
    later = Map.from_struct(reload_bp(bp))

    changed =
      before
      |> Enum.filter(fn {k, v} -> Map.fetch!(later, k) != v end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    with :ok <- assert_flag_only_columns(changed),
         {:ok, poweroff} <- poweroff_is_an_uncalled_catalog_entry() do
      {:ok, "FLAG-ONLY — one update_all changed exactly #{inspect(changed)}; #{poweroff}"}
    end
  end

  defp resolve_effect({:absent, :free_plan_write}) do
    team = team_with_owner()
    sub = trial_sub(team, -3600)
    _bp = barkpark_fixture(team)

    {:ok, _} = perform_job(TrialExpiryWorker, %{})
    after_run = Repo.get!(Subscription, sub.id)

    if after_run.plan == "free" do
      {:error,
       "the trial row DID land on \"free\" — the console's promise is kept after all, so this " <>
         "row's EFFECT verdict must be re-derived"}
    else
      {:ok,
       "ABSENT — after the expiry run the subscription still reads plan=#{inspect(after_run.plan)} " <>
         "status=#{inspect(after_run.status)}; nothing writes the free plan the copy names"}
    end
  end

  defp resolve_effect({:unread, :cancel_at_period_end}) do
    team = team_with_owner()
    {:ok, sub} = Billing.subscribe(team, "supporter")
    {:ok, _} = sub |> Subscription.changeset(%{cancel_at_period_end: true}) |> Repo.update()

    if Billing.entitled?(team) do
      {:ok, "UNREAD — entitled?/1 answers true on status \"active\" regardless of the flag"}
    else
      {:error, "entitled?/1 honoured cancel_at_period_end — re-derive this row"}
    end
  end

  defp resolve_effect({:produced, :deprovision_job}) do
    team = team_with_owner()
    _sub = trial_sub(team, -3600)
    bp = barkpark_fixture(team)

    {:ok, _} = perform_job(TrialExpiryWorker, %{})

    case deprovision_jobs(bp.id) do
      [%ProvisionJob{kind: "deprovision", status: status}] ->
        {:ok,
         "PRODUCED — one deprovision ProvisionJob (status #{inspect(status)}) on box #{bp.id}"}

      other ->
        {:error, "the named effect was not produced: #{inspect(other)}"}
    end
  end

  # The four columns a suspend writes. Named here so a fifth column (or a lost
  # one) reds with the diff rather than passing as "some flags moved".
  @suspend_columns [:suspended, :suspended_at, :suspended_reason, :updated_at]

  defp assert_flag_only_columns(changed) do
    if changed == @suspend_columns do
      :ok
    else
      {:error,
       "a suspend changed #{inspect(changed)}, not #{inspect(@suspend_columns)} — this register " <>
         "calls the effect FLAG-ONLY on the strength of exactly those four columns"}
    end
  end

  # Read the tree, do not describe it: the only `poweroff` in cloud/lib is a
  # catalog entry, and nothing calls the verb.
  defp poweroff_is_an_uncalled_catalog_entry do
    lib = Path.expand(Path.join([__DIR__, "..", "..", "lib"]))

    hits =
      Path.wildcard(Path.join(lib, "**/*.ex"))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> String.contains?(line, "poweroff") end)
        |> Enum.map(fn {line, n} -> {Path.relative_to(path, lib), n, String.trim(line)} end)
      end)

    catalog_only? =
      hits != [] and
        Enum.all?(hits, fn {rel, _n, line} ->
          rel == "barkpark_cloud/registry/hetzner_catalog.ex" and
            (String.starts_with?(line, "verb:") or String.starts_with?(line, "path:"))
        end)

    if catalog_only? do
      {:ok,
       "the only poweroff in cloud/lib is the uncalled hetzner_catalog entry " <>
         "(#{length(hits)} lines, all in registry/hetzner_catalog.ex)"}
    else
      {:error,
       "poweroff now appears outside the hetzner catalog entry: #{inspect(hits)} — an effect " <>
         "stronger than a flag may exist, so every FLAG-ONLY verdict here must be re-derived"}
    end
  end

  ## ── The register's arms ────────────────────────────────────────────────

  defp resolve_row(%{clock: clock, actor: actor, effect: effect}) do
    %{clock: resolve_clock(clock), actor: resolve_actor(actor), effect: resolve_effect(effect)}
  end

  test "CLOCK: the configured crontab is exactly what this register pins, by EQUALITY" do
    # This is the arm every ABSENT verdict rests on. It is an equality, not a
    # /Billing|Dunning|Grace/ heuristic: an enforcement worker named e.g.
    # ArrearsWorker slips past a heuristic and the register would keep claiming
    # ABSENT while the clock had arrived.
    assert {:ok, detail} = crontab_agrees()
    assert detail =~ "14 rows"
    assert length(configured_crontab()) == length(@scheduled_crontab)
  end

  test "every row's CLOCK, ACTOR and EFFECT resolve as this register records them" do
    for {{reason, transition}, spec} <- @register do
      for {column, result} <- resolve_row(spec) do
        case result do
          {:ok, _detail} ->
            :ok

          {:error, why} ->
            flunk(
              "#{reason}/#{transition}: the #{column} column does not resolve as recorded: #{why}"
            )
        end
      end
    end
  end

  test "the PAIR key is load-bearing: the two `trial` rows resolve to genuinely different triples" do
    # If both trial rows resolved the same way, a register keyed on the bare
    # reason would have done — and this file would be agreeing with itself
    # rather than discriminating.
    discharged = resolve_row(@register[{"trial", :expire_teardown}])
    unsupported = resolve_row(@register[{"trial", :land_on_free}])

    {:ok, d_clock} = discharged.clock
    {:ok, u_clock} = unsupported.clock
    assert d_clock == u_clock, "the split control must share a clock, or the pair proves nothing"

    {:ok, d_effect} = discharged.effect
    {:ok, u_effect} = unsupported.effect

    assert d_effect =~ "PRODUCED"
    assert u_effect =~ "ABSENT"

    refute d_effect == u_effect,
           "the two trial rows resolved identically — the (reason, transition) key is doing no " <>
             "work and a state key would have sufficed"
  end

  test "EFFECT: a suspension is four columns and nothing in cloud/lib powers a box off" do
    # Stated as its own test so the property is visible without reading
    # resolve_effect/1.
    assert {:ok, detail} = resolve_effect({:flag_only, :suspend_update_all})
    assert detail =~ "[:suspended, :suspended_at, :suspended_reason, :updated_at]"
    assert detail =~ "uncalled hetzner_catalog entry"
  end

  test "ACTOR: the discharged row is backed by the real producer, not by its cron row" do
    # A cron probe proves the module is scheduled and loads. It survives a
    # perform/1 gutted to :ok (measured in this epic on
    # AutoupdateRolloutWorker). So the DISCHARGED verdict costs a run whose
    # observer sits on an effect row.
    assert {:ok, detail} = resolve_actor({:producer_run, :teardown_enqueued})
    assert detail =~ "perform_job(TrialExpiryWorker)"
    assert detail =~ "kind: \"deprovision\""
  end

  test "META: the register actually iterated every row and exercised every resolver kind" do
    # Without this, gutting a resolver to `{:ok, "fine"}` — or emptying
    # @register — would leave a green suite that compared nothing.
    resolved = for {key, spec} <- @register, do: {key, resolve_row(spec)}

    assert length(resolved) == map_size(@register)

    assert map_size(@register) == 6,
           "the register seeded 6 rows; it now holds #{map_size(@register)}"

    reasons = @register |> Map.keys() |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    assert reasons == ["billing_lapsed", "billing_past_due", "quota_exceeded", "trial"]

    kind = fn
      tuple when is_tuple(tuple) -> elem(tuple, 0)
      atom when is_atom(atom) -> atom
    end

    clock_kinds =
      @register |> Map.values() |> Enum.map(&kind.(&1.clock)) |> Enum.uniq() |> Enum.sort()

    actor_kinds =
      @register |> Map.values() |> Enum.map(&kind.(&1.actor)) |> Enum.uniq() |> Enum.sort()

    effect_kinds =
      @register |> Map.values() |> Enum.map(&kind.(&1.effect)) |> Enum.uniq() |> Enum.sort()

    assert clock_kinds == [:crontab_absent, :crontab_row, :external_only, :synchronous]
    assert actor_kinds == [:none_local, :producer_run, :synchronous_call, :unreachable]
    assert effect_kinds == [:absent, :flag_only, :produced, :unread]

    # And every resolution reported a non-empty detail — a resolver that
    # returns {:ok, ""} is a resolver that measured nothing.
    for {key, columns} <- resolved, {column, {:ok, detail}} <- columns do
      assert is_binary(detail) and detail != "",
             "#{inspect(key)}'s #{column} resolved with no detail to report"
    end
  end
end
