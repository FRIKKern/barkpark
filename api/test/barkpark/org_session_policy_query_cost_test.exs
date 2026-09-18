defmodule Barkpark.OrgSessionPolicyQueryCostTest do
  @moduledoc """
  era-bl-policy-query-perf — the MEASUREMENT `era-w8-org-session-policy` never
  took: what does `Tenancy.org_session_policy_for_user/1` actually cost inside
  `Accounts.verify_user_session/1`, which runs on EVERY authenticated request,
  for every user including fully ungoverned ones?

  ## The materiality threshold — PREDECLARED, before any number was read

  This paragraph was written and committed BEFORE the benchmark was run. The
  extra lookup is MATERIAL, and must be optimised away (per-session cache keyed
  by session id with a short TTL invalidated on policy change, or folded into
  the session query as a join), if ANY of these holds:

    * **T1 — query count.** The policy lookup adds MORE THAN ONE query per
      `verify_user_session/1` call, or its cost scales with the number of
      governing orgs (an N+1).
    * **T2 — absolute warm latency.** The policy lookup's warm p50 exceeds
      **1.0 ms** on a local pool, for either a governed or an ungoverned user.
    * **T3 — relative warm latency.** The policy lookup's warm p50 exceeds
      **40%** of the whole `verify_user_session/1` warm p50 — i.e. it is a
      comparable expense to the two reads (session row + user row) the verify
      cannot avoid, rather than a third read of the same shape.

  Under T1/T2/T3 all false the verdict is a DOCUMENTED NO-OP: the numbers,
  commands and environment are recorded on the PR body, and the query-count
  assertions below become the pin that stops the cost from growing silently.

  ## What is asserted vs. what is only printed

  **Asserted:** query counts. They are deterministic and they are the part a
  future change can regress. `policy_query_count == 1` for an ungoverned user,
  for a one-org governed user, and for a THREE-org governed user (the N+1
  probe), and the decomposition control
  `baseline_queries + policy_queries == verify_queries` — which proves the
  "policy disabled" baseline below really is the whole verify minus the policy
  lookup, not an unrelated third thing.

  **Printed, never asserted:** latency percentiles. A wall-clock assertion in
  a shared-Postgres CI run is a flake generator, not a gate; the numbers are
  emitted to stdout so the run itself is the artifact and the PR body quotes
  it. The threshold above is applied by a HUMAN reading those numbers.

  ## The "policy lookup disabled" baseline

  There is no feature flag to switch the lookup off, and adding one to
  production code for a benchmark would be a worse change than the one being
  measured. So the baseline is composed here from the exact primitives the
  verify uses either side of the policy call — the session row read, the
  all-nil-policy predicate, and the user row read — which is literally what
  `verify_user_session/1` did before era-w8 wired the lookup in. The
  decomposition control above is what keeps that composition honest: if the
  verify ever grows a fourth read, the control reds rather than quietly
  attributing it to the policy.

  `async: false` deliberately — this file times things, and a concurrent
  neighbour on the same pool moves the numbers.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query, warn: false

  alias Barkpark.{Accounts, Repo, Tenancy}
  alias Barkpark.Accounts.{User, UserSession}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  # Timed-loop sizes. No benchee in mix.exs and this task does not add a
  # dependency; a warmed loop with percentiles answers the same question.
  @warmup 200
  @samples 500

  defp user!(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp org!(slug, policy) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})

    if policy do
      {:ok, org} = Tenancy.set_organization_session_policy(org.id, policy)
      org
    else
      org
    end
  end

  defp govern!(user, org, ws_slug) do
    {:ok, ws} = Tenancy.create_workspace(%{slug: ws_slug, name: ws_slug})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    :ok
  end

  defp token!(user) do
    {:ok, plaintext} = Accounts.create_user_session_token(user)
    plaintext
  end

  # The pre-era-w8 verify: session row, predicate against an all-nil policy,
  # user row. `last_used_at` is stamped at mint, so the 60s-throttled UPDATE
  # does not fire here — in BOTH this baseline and the real verify, which is
  # what makes the decomposition control below hold.
  @no_policy %{idle_timeout_seconds: nil, absolute_lifetime_seconds: nil}

  defp verify_without_policy(plaintext) do
    hash = UserSession.hash_token(plaintext)
    now = DateTime.utc_now()

    query =
      from t in UserSession,
        where: t.token_hash == ^hash and is_nil(t.revoked_at),
        where: is_nil(t.expires_at) or t.expires_at > ^now

    case Repo.one(query) do
      %UserSession{user_id: uid} = session ->
        if UserSession.within_org_policy?(session, @no_policy, now) do
          case Repo.get(User, uid) do
            %User{} = user -> {user, session}
            nil -> nil
          end
        end

      nil ->
        nil
    end
  end

  # Process-scoped Repo query counter, lifted from
  # test/barkpark/tenancy/seat_capabilities_test.exs:334-360. `:telemetry.attach/4`
  # is NODE-global, so the handler filters on `self() == owner` — an unscoped
  # counter reads other processes' queries.
  defp count_queries(fun) do
    counter = :counters.new(1, [:atomics])
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:barkpark, :repo, :query],
        fn _event, _measure, _meta, %{owner: owner, counter: counter} ->
          if self() == owner, do: :counters.add(counter, 1, 1)
        end,
        %{owner: owner, counter: counter}
      )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end

  # COLD = the very first call, before any statement is prepared or any row is
  # in a page cache. One sample by definition — a percentile over repeats would
  # not be cold any more.
  defp cold_us(fun) do
    {us, _} = :timer.tc(fun)
    us
  end

  # WARM = after @warmup discarded iterations, @samples timed ones.
  defp warm_us(fun) do
    for _ <- 1..@warmup, do: fun.()
    for _ <- 1..@samples, do: elem(:timer.tc(fun), 0)
  end

  defp pct(samples, p) do
    sorted = Enum.sort(samples)
    idx = min(length(sorted) - 1, floor(p / 100 * length(sorted)))
    Enum.at(sorted, idx)
  end

  defp ms(us), do: :erlang.float_to_binary(us / 1000, decimals: 3)

  defp row(label, cold, warm) do
    IO.puts(
      "  #{String.pad_trailing(label, 34)} cold #{String.pad_leading(ms(cold), 8)} ms" <>
        "   p50 #{String.pad_leading(ms(pct(warm, 50)), 8)} ms" <>
        "   p95 #{String.pad_leading(ms(pct(warm, 95)), 8)} ms"
    )
  end

  describe "query count — the deterministic, ASSERTED half" do
    test "the policy lookup is exactly ONE query for an ungoverned user" do
      user = user!("qc-ungoverned@example.com")
      plaintext = token!(user)

      # Warm the statement cache so the count is the steady-state count.
      Accounts.verify_user_session(plaintext)

      policy_q = count_queries(fn -> Tenancy.org_session_policy_for_user(user.id) end)
      verify_q = count_queries(fn -> Accounts.verify_user_session(plaintext) end)
      baseline_q = count_queries(fn -> verify_without_policy(plaintext) end)

      IO.puts(
        "\n  [queries/verify] ungoverned: verify=#{verify_q} " <>
          "baseline=#{baseline_q} policy=#{policy_q}"
      )

      assert policy_q == 1, "T1: the policy lookup must cost exactly one query"
      assert baseline_q == 2, "session row + user row, no policy, no throttled UPDATE"

      # DECOMPOSITION CONTROL. Delete the policy call from verify_user_session/1
      # and this reds — it is what proves `verify_without_policy/1` is the
      # verify MINUS the policy lookup and not an unrelated third thing.
      assert verify_q == baseline_q + policy_q
      assert verify_q == 3
    end

    test "a GOVERNED user costs the same one query — and does not scale with orgs" do
      one = user!("qc-gov1@example.com")
      govern!(one, org!("qc-org-a", %{idle_timeout_seconds: 900}), "qc-ws-a")

      three = user!("qc-gov3@example.com")
      govern!(three, org!("qc-org-b", %{idle_timeout_seconds: 1200}), "qc-ws-b")
      govern!(three, org!("qc-org-c", %{absolute_lifetime_seconds: 86_400}), "qc-ws-c")
      govern!(three, org!("qc-org-d", %{idle_timeout_seconds: 600}), "qc-ws-d")

      p_one = token!(one)
      p_three = token!(three)
      Accounts.verify_user_session(p_one)
      Accounts.verify_user_session(p_three)

      q_one = count_queries(fn -> Tenancy.org_session_policy_for_user(one.id) end)
      q_three = count_queries(fn -> Tenancy.org_session_policy_for_user(three.id) end)

      IO.puts("  [queries/policy] governed×1: #{q_one}   governed×3 orgs: #{q_three}")

      # T1's second arm: the cost must not scale with the number of governing
      # orgs. The resolver is one joined Repo.all/1, so three orgs is still one
      # query — if it ever becomes a per-org read this reds.
      assert q_one == 1
      assert q_three == 1

      assert count_queries(fn -> Accounts.verify_user_session(p_three) end) == 3

      # And the strictest bound really is being resolved off those three rows,
      # so the query being counted is doing the real work.
      assert Tenancy.org_session_policy_for_user(three.id) ==
               %{idle_timeout_seconds: 600, absolute_lifetime_seconds: 86_400}
    end
  end

  describe "latency — PRINTED, never asserted (see @moduledoc)" do
    test "warm/cold distribution for governed, ungoverned, and policy-disabled baseline" do
      ungoverned = user!("lat-ungoverned@example.com")
      governed = user!("lat-governed@example.com")
      govern!(governed, org!("lat-org", %{idle_timeout_seconds: 900}), "lat-ws")

      p_un = token!(ungoverned)
      p_gov = token!(governed)

      # Cold samples FIRST, each on a path nothing has touched yet.
      cold_policy_un = cold_us(fn -> Tenancy.org_session_policy_for_user(ungoverned.id) end)
      cold_policy_gov = cold_us(fn -> Tenancy.org_session_policy_for_user(governed.id) end)
      cold_verify_un = cold_us(fn -> Accounts.verify_user_session(p_un) end)
      cold_verify_gov = cold_us(fn -> Accounts.verify_user_session(p_gov) end)
      cold_baseline = cold_us(fn -> verify_without_policy(p_un) end)

      warm_policy_un = warm_us(fn -> Tenancy.org_session_policy_for_user(ungoverned.id) end)
      warm_policy_gov = warm_us(fn -> Tenancy.org_session_policy_for_user(governed.id) end)
      warm_verify_un = warm_us(fn -> Accounts.verify_user_session(p_un) end)
      warm_verify_gov = warm_us(fn -> Accounts.verify_user_session(p_gov) end)
      warm_baseline = warm_us(fn -> verify_without_policy(p_un) end)

      IO.puts("\n  era-bl-policy-query-perf — #{@samples} samples after #{@warmup} warmup")

      IO.puts(
        "  #{:erlang.system_info(:system_architecture)} | OTP #{System.otp_release()} | " <>
          "Elixir #{System.version()} | schedulers #{System.schedulers_online()}"
      )

      row("verify (governed)", cold_verify_gov, warm_verify_gov)
      row("verify (ungoverned)", cold_verify_un, warm_verify_un)
      row("verify (policy DISABLED baseline)", cold_baseline, warm_baseline)
      row("policy lookup alone (governed)", cold_policy_gov, warm_policy_gov)
      row("policy lookup alone (ungoverned)", cold_policy_un, warm_policy_un)

      tax_gov = pct(warm_verify_gov, 50) - pct(warm_baseline, 50)
      tax_un = pct(warm_verify_un, 50) - pct(warm_baseline, 50)

      IO.puts(
        "  tax p50 (verify - baseline): governed #{ms(tax_gov)} ms, " <>
          "ungoverned #{ms(tax_un)} ms"
      )

      IO.puts(
        "  T2 check: policy p50 vs 1.000 ms -> governed " <>
          "#{ms(pct(warm_policy_gov, 50))} ms, ungoverned " <>
          "#{ms(pct(warm_policy_un, 50))} ms"
      )

      IO.puts(
        "  T3 check: policy p50 / verify p50 -> governed " <>
          "#{Float.round(pct(warm_policy_gov, 50) / pct(warm_verify_gov, 50) * 100, 1)}%," <>
          " ungoverned " <>
          "#{Float.round(pct(warm_policy_un, 50) / pct(warm_verify_un, 50) * 100, 1)}%\n"
      )

      # The only assertion here is that the run produced samples at all — a
      # benchmark that silently measured nothing must not read as a pass.
      assert length(warm_verify_gov) == @samples
      assert Enum.all?(warm_verify_gov, &(&1 > 0))
    end
  end
end
