defmodule BarkparkCloud.Notifications.WithholdCensus do
  @moduledoc """
  wave 33 R2 — the DERIVED census of silent withholds in `notifications.ex`.

  Charter D349(c) + D351: the LEFT side is derived, never hand-enumerated. A hand
  list is a list of the branches somebody REMEMBERED; the whole point of this
  epic is the branch nobody remembered.

  ## The derivation, in three steps

    1. **EGRESS REACHABILITY (a fixpoint).** A function that cannot transitively
       reach `Mailer.deliver` / `Oban.insert` / `ChatNotificationWorker.new` /
       `record_delivery` / `log_chat_delivery` was never positioned to send, so
       it cannot withhold. Qualified pairs only: a bare `:insert` name list
       matches `Repo.insert` and false-accuses every persistence branch in the
       file.

    2. **TERMINAL POSITIONS, PATH-SENSITIVELY.** Inside those functions, every
       terminal return is enumerated together with the BRANCH PATH that reaches
       it — `if`/`case`/`cond`/`with`/`try` arms, the `rescue` block (a terminal
       position `dispatch_event/3` uses and a clause-level walk misses), and the
       ZERO-ITERATION arm of a `for`/`Enum` fan-out whose body sends (an egress
       that happens per element does not happen at all over an empty list —
       that is the empty-team withhold, and no arm exists in the source for it).

    3. **LEFT = the terminals that LIE.** Shape `:ok` / `{:cancel, _}` /
       `{:ok, atom}` — a return the caller reads as "handled" — with no trace
       call (`record_delivery`, `log_chat_delivery`, `Withhold.record`) anywhere
       on the path that reaches it. A trace inside a BRANCHY prefix statement
       does not count for the paths that do not take it.

  ## The consent key is FINE: `{fun, arity, clause, origin, path, shape}`

  `origin` is `:do` / `:rescue` / `:catch` and `path` is the structural branch
  path inside it — together the brief's `origin`, refined so two forks in one
  clause cannot collapse. The COARSE key `{fun, arity, shape}` is a proven
  failure: it green-lights `dispatch_event/3`'s `rescue` arm, because that arm
  shares name, arity and observable shape (`:ok`) with the CONSENTED empty-team
  fan-out in the same function — one consent row silently absolving two
  unrelated branches. `withhold_test.exs` pins that collision.

  LINE NUMBERS ARE REJECTED as a key: they red on any edit above the branch,
  which trains a builder to re-stamp instead of read. Every anchor in this
  slice's own brief had drifted 40-70 lines before it was dispatched.
  """

  @trace_locals [:record_delivery, :log_chat_delivery]
  @trace_remote [{:Withhold, :record}]
  @egress_remote [{:Mailer, :deliver}, {:Oban, :insert}, {:ChatNotificationWorker, :new}]
  @left_shapes [:ok, :cancel, :ok_atom]
  @combo_cap 16

  @doc "The file this census owns."
  def source, do: Path.expand("../../../lib/barkpark_cloud/notifications.ex", __DIR__)

  @doc "Every terminal position in the file, with its branch path, shape and trace state."
  def rows(path \\ source()) do
    ast = path |> File.read!() |> Code.string_to_quoted!(columns: true)
    egress = egress_closure(calls_by_fun(ast))

    ast
    |> clauses()
    |> Enum.flat_map(fn c ->
      for {origin, opath, shape, traced} <- clause_terminals(c.body) do
        %{
          fun: c.name,
          arity: c.arity,
          clause: c.ordinal,
          origin: origin,
          path: opath,
          shape: shape,
          traced: traced,
          on_egress: MapSet.member?(egress, c.name)
        }
      end
    end)
  end

  @doc "The LEFT set: positioned-to-send terminals that return success and write nothing."
  def left(path \\ source()),
    do: Enum.filter(rows(path), &(&1.on_egress and &1.shape in @left_shapes and not &1.traced))

  @doc """
  The RECEIPT-LOSS set — a DIFFERENT class, kept separate on purpose: the send
  already happened and the ROW failed to write. A `suppressed` row here would
  assert the opposite of what occurred, so these are not routed through
  `Withhold`; they are named, and owned by their own backlog task.
  """
  def receipt_loss(path \\ source()) do
    rows(path)
    |> Enum.filter(&(&1.on_egress and &1.shape == :nil_shape and not &1.traced))
    |> Enum.map(&{&1.fun, &1.arity, &1.shape})
    |> Enum.uniq()
  end

  @doc "Every reason atom handed to `Withhold.record/4` anywhere in the file."
  def reasons_used(path \\ source()) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, mods}, :record]}, _, [_t, _e, reason | _]} = n, acc
        when is_atom(reason) ->
          {n, if(List.last(mods) == :Withhold, do: [reason | acc], else: acc)}

        n, acc ->
          {n, acc}
      end)

    Enum.uniq(acc)
  end

  @doc "The FINE consent key — what a consent row must name."
  def fine(r), do: {r.fun, r.arity, r.clause, r.origin, r.path, r.shape}

  @doc "The COARSE key this census REFUSES, kept only so a test can prove why."
  def coarse(r), do: {r.fun, r.arity, r.shape}

  @doc "One printable line per branch, naming it by {fun, arity, clause, origin}."
  def describe(r),
    do:
      "#{r.fun}/#{r.arity} clause #{r.clause} origin=#{r.origin} shape=#{r.shape} " <>
        "path=#{if(r.path == "", do: "<clause body>", else: r.path)}"

  ## ── clause extraction ─────────────────────────────────────────────────────

  defp clauses(ast) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {k, _m, [head, body]} = n, acc when k in [:def, :defp] and is_list(body) ->
          {name, arity} = sig(head)
          {n, [%{name: name, arity: arity, body: body} | acc]}

        n, acc ->
          {n, acc}
      end)

    acc
    |> Enum.reverse()
    |> Enum.map_reduce(%{}, fn c, counts ->
      k = {c.name, c.arity}
      n = Map.get(counts, k, 0) + 1
      {Map.put(c, :ordinal, n), Map.put(counts, k, n)}
    end)
    |> elem(0)
  end

  defp sig({:when, _, [i | _]}), do: sig(i)
  defp sig({n, _, a}) when is_atom(n) and is_list(a), do: {n, length(a)}
  defp sig({n, _, _}) when is_atom(n), do: {n, 0}
  defp sig(_), do: {:unknown, 0}

  ## ── call graph + egress fixpoint ──────────────────────────────────────────

  defp calls_by_fun(ast) do
    {_, out} =
      Macro.prewalk(ast, [], fn
        {k, _m, [head, body]} = n, acc when k in [:def, :defp] and is_list(body) ->
          {name, _} = sig(head)
          {n, [{name, called(body)} | acc]}

        n, acc ->
          {n, acc}
      end)

    Enum.reduce(out, %{}, fn {k, v}, acc -> Map.update(acc, k, v, &MapSet.union(&1, v)) end)
  end

  defp called(ast) do
    {_, names} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, mods}, f]}, _, a} = n, acc when is_list(a) ->
          {n, if({List.last(mods), f} in @egress_remote, do: [:__egress__ | acc], else: acc)}

        {name, _, a} = n, acc when is_atom(name) and is_list(a) ->
          {n, if(name in @trace_locals, do: [:__egress__, name | acc], else: [name | acc])}

        n, acc ->
          {n, acc}
      end)

    MapSet.new(names)
  end

  defp egress_closure(graph) do
    seed = for {n, c} <- graph, MapSet.member?(c, :__egress__), into: MapSet.new(), do: n
    grow(graph, MapSet.union(seed, MapSet.new(@trace_locals)))
  end

  defp grow(graph, acc) do
    next =
      for {n, c} <- graph,
          not MapSet.member?(acc, n),
          Enum.any?(c, &MapSet.member?(acc, &1)),
          into: acc,
          do: n

    if MapSet.size(next) == MapSet.size(acc), do: acc, else: grow(graph, next)
  end

  ## ── terminals ─────────────────────────────────────────────────────────────

  defp clause_terminals(body) do
    Enum.flat_map(body, fn
      {:do, b} ->
        for {p, s, t} <- terms(b, "", false), do: {:do, p, s, t}

      {k, cs} when k in [:rescue, :catch] and is_list(cs) ->
        Enum.flat_map(cs, fn {:->, _, [_, b]} ->
          for {p, s, t} <- terms(b, "", false), do: {k, p, s, t}
        end)

      _ ->
        []
    end)
  end

  defp terms(nil, p, t), do: [{p, :nil_shape, t}]

  defp terms({:__block__, _, exprs}, p, t) when exprs != [] do
    {prefix, [last]} = Enum.split(exprs, length(exprs) - 1)
    for {pl, pt} <- combos(prefix), r <- terms(last, join(p, pl), t or pt), do: r
  end

  defp terms({op, _, [c, kw]}, p, t) when op in [:if, :unless] and is_list(kw) do
    t = t or has_trace?(c)

    for {k, b} <- [{"then", kw[:do]}, {"else", kw[:else]}],
        r <- terms(b, join(p, "#{op}(#{src(c)})>#{k}"), t),
        do: r
  end

  defp terms({:case, _, [subj, [do: cls]]}, p, t) do
    t = t or has_trace?(subj)

    Enum.flat_map(cls, fn {:->, _, [pat, b]} ->
      terms(b, join(p, "case(#{src(subj)})>#{pats(pat)}"), t)
    end)
  end

  defp terms({:|>, _, [lhs, {:case, m, [[do: cls]]}]}, p, t),
    do: terms({:case, m, [lhs, [do: cls]]}, p, t)

  defp terms({:cond, _, [[do: cls]]}, p, t),
    do: Enum.flat_map(cls, fn {:->, _, [pat, b]} -> terms(b, join(p, "cond>#{pats(pat)}"), t) end)

  defp terms({:with, _, args}, p, t) do
    {heads, opts} = Enum.split_while(args, &(not is_list(&1)))
    opts = List.flatten(opts)
    ht = t or Enum.any?(heads, &has_trace?/1)

    terms(opts[:do], join(p, "with>do"), ht) ++
      case opts[:else] do
        nil ->
          []

        cs ->
          Enum.flat_map(cs, fn {:->, _, [pat, b]} ->
            terms(b, join(p, "with>else>#{pats(pat)}"), t)
          end)
      end
  end

  defp terms({:try, _, [opts]}, p, t) when is_list(opts) do
    Enum.flat_map(opts, fn
      {k, cs} when is_list(cs) ->
        Enum.flat_map(cs, fn {:->, _, [pat, b]} ->
          terms(b, join(p, "try>#{k}>#{pats(pat)}"), t)
        end)

      {k, b} ->
        terms(b, join(p, "try>#{k}"), t)
    end)
  end

  defp terms(expr, p, t), do: [{p, shape(expr), t or has_trace?(expr)}]

  ## ── prefix-statement path expansion ───────────────────────────────────────

  defp combos(prefix) do
    prefix
    |> Enum.reduce([{"", false}], fn stmt, acc ->
      for {al, at} <- acc, {sl, st} <- branch_paths(stmt), do: {join(al, sl), at or st}
    end)
    |> Enum.take(@combo_cap)
  end

  defp branch_paths({op, _, [c, kw]}) when op in [:if, :unless] and is_list(kw) do
    for {k, b} <- [{"then", kw[:do]}, {"else", kw[:else]}],
        {l, t} <- branch_paths(b),
        do: {join("#{op}(#{src(c)})>#{k}", l), t or has_trace?(c)}
  end

  defp branch_paths({:case, _, [subj, [do: cls]]}) do
    for {:->, _, [pat, b]} <- cls,
        {l, t} <- branch_paths(b),
        do: {join("case(#{src(subj)})>#{pats(pat)}", l), t or has_trace?(subj)}
  end

  # A fan-out whose body SENDS has an arm the source does not write: zero
  # iterations. That arm is the empty-team withhold.
  defp branch_paths({:for, _, args} = n) do
    {gens, opts} = Enum.split_while(args, &(not is_list(&1)))
    opts = List.flatten(opts)

    if Keyword.has_key?(opts, :do) and has_send?(opts[:do]) do
      g = gens |> Enum.map(&src/1) |> Enum.join(", ")

      [{"for(#{g})>empty", false}] ++
        for {l, t} <- branch_paths(opts[:do]), do: {join("for(#{g})>each", l), t}
    else
      [{"", has_trace?(n)}]
    end
  end

  defp branch_paths({{:., _, [{:__aliases__, _, [:Enum]}, f]}, _, args} = n) do
    fns = Enum.filter(args, &match?({:fn, _, _}, &1))

    if fns != [] and Enum.any?(fns, &has_send?/1) do
      subj = args |> Enum.reject(&match?({:fn, _, _}, &1)) |> Enum.map(&src/1) |> Enum.join(", ")

      [
        {"Enum.#{f}(#{subj})>empty", false},
        {"Enum.#{f}(#{subj})>each", Enum.any?(fns, &has_trace?/1)}
      ]
    else
      [{"", has_trace?(n)}]
    end
  end

  defp branch_paths({:__block__, _, exprs}) when exprs != [], do: combos(exprs)
  defp branch_paths(ast), do: [{"", has_trace?(ast)}]

  ## ── helpers ───────────────────────────────────────────────────────────────

  defp join("", b), do: b
  defp join(a, ""), do: a
  defp join(a, b), do: a <> ">" <> b

  defp pats(pat), do: pat |> Enum.map(&src/1) |> Enum.join(", ")

  defp src(ast),
    do: ast |> Macro.to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 72)

  defp shape(:ok), do: :ok
  defp shape({:{}, _, [:cancel, _]}), do: :cancel
  defp shape({:cancel, _}), do: :cancel
  defp shape({:ok, v}) when is_atom(v), do: :ok_atom
  defp shape({:__block__, _, [v]}), do: shape(v)
  defp shape(_), do: :other

  defp has_trace?(ast), do: scan(ast, @trace_locals, @trace_remote)
  defp has_send?(ast), do: scan(ast, @trace_locals, @egress_remote)

  defp scan(ast, locals, remotes) do
    {_, f} =
      Macro.prewalk(ast, false, fn
        {n, _, a} = node, acc when is_atom(n) and is_list(a) ->
          {node, acc or n in locals}

        {{:., _, [{:__aliases__, _, mods}, f]}, _, a} = node, acc when is_list(a) ->
          {node, acc or {List.last(mods), f} in remotes}

        node, acc ->
          {node, acc}
      end)

    f
  end
end

defmodule BarkparkCloud.Notifications.FakeJobClient do
  @moduledoc """
  The job-queue double behind `notifications.ex`'s `insert_job/1` seam, wired in
  per test via `config :barkpark_cloud, :notifications_job_client`. Programmed
  from — and read out of — the CALLING process's dictionary, exactly like
  `Notifications.FakeHttpClient`, so it is safe under `async: true`: an
  unprogrammed process gets the real `Oban.insert/1` and nothing changes for it.
  """

  @key :w33r2_fake_job_verdict

  @doc "Program this process's next enqueue verdict: `:raise` or `{:error, term}`."
  def program(verdict), do: Process.put(@key, verdict)

  @doc "Hand this process back to the real queue."
  def reset, do: Process.delete(@key)

  def insert(changeset) do
    case Process.get(@key) do
      :raise -> raise "chat job queue unavailable (cch-w32-r2 fake)"
      {:error, _reason} = err -> err
      _ -> Oban.insert(changeset)
    end
  end
end

defmodule BarkparkCloud.Notifications.WithholdTest do
  @moduledoc """
  wave 32 S2 — a WITHHELD notification becomes a row a person can read.

  The delivery log was a log of ATTEMPTS: both writers run only after a transport
  returns, and `Delivery.@statuses` was `pending | sent | failed`. So every branch
  that DECIDED not to send was invisible on the one surface built to answer "was
  I notified?" — the 26th owner in a cluster-wide incident read a log that said
  nothing at all.

  These tests drive the funnel itself. The producer-level proof (a real reap
  sweep past the cap writing real rows) lives in
  `deployment_failed_dispatch_test.exs`; here we pin the vocabulary, the ROW
  GRAIN, the consented zero-recipient case, and the `last_error` clamp.

  ## wave 33 R2 — the CENSUS, and the other five withholds

  §5 below is the derived census (`WithholdCensus`, top of this file): every
  silent withhold in `notifications.ex` is either routed through this funnel or
  NAMED CONSENTED with its reason, and the census fails on any branch that is
  neither. §6-§8 drive the three newly-funnelled branches and re-prove the two
  consented ones from the constraint that makes them unrecordable.

  ## Why this module is `async: false`

  §7 swaps `:notifications_job_client`, and `Application.put_env/3` writes one
  value for the WHOLE NODE — under `async: true` that swap is in force for every
  other module running at that instant. `AsyncGlobalSeamGuardTest` is the ratchet
  that says so, and it is right: the fake delegating to the real `Oban.insert/1`
  when a process has not programmed it makes the swap HARMLESS, not ISOLATED.
  Sync is the guard's own first remedy and costs one short file its parallelism.
  """
  use BarkparkCloud.DataCase, async: false

  import ExUnit.CaptureLog

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Notifications

  alias BarkparkCloud.Notifications.{
    Delivery,
    DeliveryReason,
    FakeJobClient,
    Withhold,
    WithholdCensus
  }

  ## Fixtures

  defp team_with_members(count) do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})

    emails =
      for i <- 1..count do
        m = System.unique_integer([:positive])
        email = "member-#{m}-#{i}@example.com"

        {:ok, user} =
          Accounts.register_user(%{email: email, password: "correct-horse-battery"})

        {:ok, _} = Accounts.add_member(team, user, if(i == 1, do: "owner", else: "member"))
        email
      end

    {team, emails}
  end

  defp empty_team do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Empty #{n}", slug: "empty-#{n}"})
    team
  end

  ## 1. THE VOCABULARY — pinned by EQUALITY, not by inclusion.
  ##
  ##    Nothing pinned `Delivery.statuses/0` in EITHER direction before this
  ##    slice: it is exported and was asserted in zero tests, and the console
  ##    harness's own check was an inclusion loop that is green whether the server
  ##    grows a status the console cannot render or the console invents one the
  ##    server would reject. The counterpart pin is in
  ##    `cloud/priv/static/__app.test.mjs` ("pinned by EQUALITY").

  test "the delivery status vocabulary is EXACTLY these four words" do
    assert Delivery.statuses() == ~w(pending sent failed suppressed)
  end

  test "a suppressed row inserts, reads back team-scoped, and answers ?status=suppressed" do
    {team, [email | _]} = team_with_members(1)

    assert {:ok, %Delivery{status: "suppressed"}} =
             %Delivery{}
             |> Delivery.changeset(%{
               team_id: team.id,
               recipient: email,
               event: "deployment_failed",
               channel: "email",
               kind: "alert",
               status: "suppressed",
               attempts: 0,
               last_error: Withhold.label(:reap_alert_cap)
             })
             |> Repo.insert()

    # The team-scoped delivery surface — the route's own reader.
    assert [%Delivery{status: "suppressed", recipient: ^email}] =
             Notifications.list_deliveries(team)

    # ...and the status filter the console's new chip sends.
    assert [%Delivery{status: "suppressed"}] =
             Notifications.list_deliveries(team, status: "suppressed")

    assert [] = Notifications.list_deliveries(team, status: "failed")
  end

  ## 2. THE GRAIN — one row per MEMBER, with that member's OWN address.
  ##
  ##    A team-level marker row is unreadable by the person it concerns: the log
  ##    is read per-recipient. Any other grain makes "a member can see the alert
  ##    that was withheld from them" structurally impossible.

  test "record/4 writes one suppressed row per member, each with that member's own address" do
    {team, emails} = team_with_members(3)

    assert Withhold.record(team.id, "deployment_failed", :reap_alert_cap) == 3

    rows = Notifications.list_deliveries(team)
    assert length(rows) == 3
    assert Enum.map(rows, & &1.recipient) |> Enum.sort() == Enum.sort(emails)

    for row <- rows do
      assert row.status == "suppressed"
      assert row.event == "deployment_failed"
      assert row.channel == "email"
      assert row.kind == "alert"
      # Nothing was attempted — an attempt count of 1 would read as "we tried".
      assert row.attempts == 0
      assert row.last_error == Withhold.label(:reap_alert_cap)
      # The reason names the DECISION, and none of the failure sentences can.
      refute row.last_error in Enum.map(DeliveryReason.classes(), &DeliveryReason.label/1)
    end
  end

  test "two withholds for the same team are two rows per member — a decision each, not a dedupe" do
    {team, _emails} = team_with_members(2)

    assert Withhold.record(team.id, "deployment_failed", :reap_alert_cap) == 2
    assert Withhold.record(team.id, "deployment_failed", :reap_alert_cap) == 2

    assert length(Notifications.list_deliveries(team, limit: 50)) == 4
  end

  ## 3. THE CONSENTED ZERO-RECIPIENT CASE — named, and a no-op that COUNTS.
  ##
  ##    `Delivery` requires a recipient. Two withhold sites have none by
  ##    construction (a team with no member emails; the fleet digest with no
  ##    platform admins). They are consented — there is no person the alert was
  ##    withheld FROM — and they must never be given a synthetic recipient, which
  ##    would be a row claiming somebody was involved who was not.

  test "a team with zero member emails is a no-op that returns a COUNT, never a fabricated row" do
    team = empty_team()

    assert Withhold.record(team.id, "deployment_failed", :reap_alert_cap) == 0
    assert Notifications.list_deliveries(team) == []
  end

  test "a nil team and an unknown reason are counted no-ops, never raises" do
    assert Withhold.record(nil, "deployment_failed", :reap_alert_cap) == 0
    assert Withhold.record(Ecto.UUID.generate(), "deployment_failed", :not_a_reason) == 0
  end

  test "a CONSENTED reason returns 0 QUIETLY — the clause that made the funnel callable" do
    # THE DEFECT THIS CLAUSE REMOVES. `record/4` guards on `is_binary(team_id)`,
    # and the fleet digest has no team by construction, so before this clause
    # every call from it fell to the catch-all: zero rows AND a Logger.error
    # naming a consented absence as "an unrecordable withhold" needing a code
    # fix. A funnel that answers its own documented caller with a false operator
    # error is a funnel that caller cannot use — and `deliver_fleet_digest/1`
    # did not use it, which is exactly how the branch stayed outside the shared
    # vocabulary while the moduledoc claimed it was inside.
    log =
      capture_log(fn ->
        assert Withhold.record(nil, "fleet_digest", :no_recipient_by_construction) == 0
      end)

    refute log =~ "refused an unrecordable withhold"
    refute log =~ "[error]"
  end

  test "the catch-all is STILL loud for a reason that is not consented" do
    # The counterpart of the test above, so the quiet is proved to be SCOPED to
    # the consented vocabulary and not a blanket silencing of the catch-all.
    log =
      capture_log(fn ->
        assert Withhold.record(nil, "deployment_failed", :dispatch_crashed) == 0
      end)

    assert log =~ "refused an unrecordable withhold"
  end

  test "a consented reason writes NO row even when a real team IS supplied" do
    # Clause ORDER is the invariant here. The consented clause is first, so a
    # consented reason can never reach the recording clause and fan `suppressed`
    # rows out to members the notification was not withheld from — the row would
    # tell a real person they were skipped for a send that had no audience.
    {team, _emails} = team_with_members(2)

    assert Withhold.record(team.id, "fleet_digest", :no_recipient_by_construction) == 0
    assert Notifications.list_deliveries(team) == []
  end

  test "every consented reason is in the closed vocabulary and has a label" do
    assert length(Withhold.consented_reasons()) >= 1

    for reason <- Withhold.consented_reasons() do
      assert reason in Withhold.reasons(),
             "a consented reason outside reasons/0 would be reachable only through " <>
               "the catch-all the clause exists to avoid"

      assert is_binary(Withhold.label(reason))
    end
  end

  ## 4. THE CLAMP — `last_error` admits TWO vocabularies and nothing else.
  ##
  ##    `last_error` is PUBLISHED (`delivery_json/1` → app.js, verbatim), so it is
  ##    clamped to sentences this system is willing to say out loud. It cannot be
  ##    a `validate_inclusion`: `{:http_status, n}` is an unbounded family.

  defp last_error_changeset(value) do
    Delivery.changeset(%Delivery{}, %{
      recipient: "someone@example.com",
      event: "deployment_failed",
      status: "failed",
      last_error: value
    })
  end

  test "a real {:http_status, n} failure reason still validates — the unbounded family survives" do
    for code <- [400, 429, 500, 503] do
      cs = last_error_changeset(DeliveryReason.label({:http_status, code}))
      assert cs.valid?, "HTTP #{code} label was rejected: #{inspect(cs.errors)}"
    end
  end

  test "every constant failure label validates" do
    for class <- DeliveryReason.classes() do
      assert last_error_changeset(DeliveryReason.label(class)).valid?,
             "failure label for #{inspect(class)} was rejected"
    end
  end

  test "every withhold label validates" do
    for reason <- Withhold.reasons() do
      assert last_error_changeset(Withhold.label(reason)).valid?,
             "withhold label for #{inspect(reason)} was rejected"
    end
  end

  test "an arbitrary RAW transport term is REJECTED — the leak this clamp exists to stop" do
    raw =
      "{:retries_exceeded, {:network_failure, ~c\"relay.example.invalid\", {:error, :nxdomain}}}"

    cs = last_error_changeset(raw)

    refute cs.valid?
    assert %{last_error: [_ | _]} = errors_on(cs)

    # ...and a near-miss of the http family does not sneak through.
    refute last_error_changeset("The channel rejected the message (HTTP boom).").valid?
    refute last_error_changeset("timeout").valid?

    # nil is still legitimate — a successful send stores nothing here.
    assert last_error_changeset(nil).valid?
  end

  ## 5. THE CENSUS (wave 33 R2) — the LEFT set is DERIVED, and every member of
  ##    it is either funnelled or NAMED.
  ##
  ##    Charter D349(c)/D351: a hand list is a list of the branches somebody
  ##    remembered. `WithholdCensus` (top of this file) derives the population by
  ##    an egress-reachability fixpoint; these tests are its verdict.

  # THE CONSENT LIST. Keyed FINE — {fun, arity, clause, origin, path, shape} —
  # because the coarse key demonstrably absolves two unrelated branches (5.2).
  # Every entry is a withhold this system is willing to keep silent, with the
  # reason it is allowed to. A key that stops matching a live branch is a RED,
  # not a leftover: a consent row that no longer describes reality consents to
  # nothing and hides whatever replaced it.
  @consented %{
    {:dispatch_event, 3, 1, :do,
     "if(should_send?(settings, event))>then>for(recipient <- team_member_emails(settings.team_id))>empty",
     :ok} =>
      "W2 — RECIPIENT-LESS BY CONSTRUCTION. A team with zero member emails: " <>
        "`Delivery.changeset/2` runs validate_required([:recipient, :event]) " <>
        "(delivery.ex:78) so no row can exist, and charter D362 forbids a " <>
        "synthetic recipient. Not the system deciding against a person — the " <>
        "absence of a person. Re-proved at runtime in §9.",
    {:dispatch_event, 3, 1, :do, "if(should_send?(settings, event))>else", :ok} =>
      "The team's OWN switch: `alerts_enabled` off, or this event's toggle off. " <>
        "Charter D363's lens: a user's own disabled toggle is not a withhold — " <>
        "counting it would make 'withhold' mean 'any switch that is off'.",
    # W6 — THE FLEET DIGEST'S ZERO-RECIPIENT ARM IS NO LONGER CONSENTED, IT IS
    # FUNNELLED, and its consent row is deliberately GONE (dr-w18-s3-fu).
    #
    # Nothing about the branch's ETHICS changed — it is still recipient-less by
    # construction, `Delivery.changeset/2` still requires a recipient, and D362
    # still forbids inventing one, so it still writes no row. What changed is
    # that it now ROUTES THROUGH THE FUNNEL to say so: it calls
    # `Withhold.record(nil, "fleet_digest", :no_recipient_by_construction)` and
    # accounts the returned count. `Withhold` could not answer that call before
    # — a digest has no `team_id`, so every call hit the catch-all and reported
    # a consented absence as an operator bug — which is why this branch was
    # carrying a consent row instead of a trace in the first place.
    #
    # A consent row left here would now be STALE, and 5.1 would red on it by
    # name. That is the point: consent and a trace are alternatives, and a
    # branch cannot hold both.
    {:dispatch_site_event, 3, 1, :do, "with>else>_", :ok} =>
      "Charter D349(b): a since-deleted or non-UUID site has no team, so a row " <>
        "written here is returnable by NOBODY — 'a Logger line in a Delivery " <>
        "costume'. Consented deliberately; re-filing it is the known mistake.",
    {:enqueue_chat, 3, 1, :do, "", :ok} =>
      "The chat master switch: `alerts_enabled: false`. The team's own decision, " <>
        "the same lens as the email toggle above.",
    {:enqueue_chat, 3, 2, :do, "if(withheld != [])>else", :ok} =>
      "Nothing was withheld on this path: either every selected channel enqueued, " <>
        "or the team routed this event to no channel at all (its own matrix)."
  }

  # A SECOND CLASS, adjudicated rather than absorbed. The send already happened
  # and the RECEIPT insert failed; a `suppressed` row would assert the opposite
  # of what occurred, so these are NOT routed through `Withhold`. They keep
  # their own filed backlog task, `cch-w32-bl-receipt-loss-branches-have-no-trace`,
  # which needs a trace of its own class — this row does not silently duplicate it.
  @receipt_loss %{
    # cch-w52-s3 widened this to /6 (the carrier the send actually used rides in
    # as the sixth argument). The BRANCH is unchanged — same `{:error, changeset}`
    # arm, same class, same owner — so this row is re-keyed rather than re-judged.
    {:record_delivery, 6, :nil_shape} =>
      "record_delivery/6's `{:error, changeset}` arm: the email send returned, " <>
        "the row did not write. Logger-only; owned by cch-w32-bl-receipt-loss-*.",
    {:log_chat_delivery, 6, :nil_shape} =>
      "log_chat_delivery/6's `{:error, changeset}` arm: the chat POST returned, " <>
        "the row did not write. Logger-only; owned by cch-w32-bl-receipt-loss-*."
  }

  test "5.1 the DERIVED left set is exactly the NAMED consented branches" do
    left = WithholdCensus.left()

    # The census PRINTS its left set. A census whose output nobody can read is a
    # census nobody audits.
    IO.puts("\n  WITHHOLD CENSUS — #{length(left)} untraced branch(es) in notifications.ex:")
    for r <- left, do: IO.puts("    LEFT  " <> WithholdCensus.describe(r))

    keys = MapSet.new(left, &WithholdCensus.fine/1)
    consented = MapSet.new(Map.keys(@consented))

    unconsented =
      left
      |> Enum.reject(&MapSet.member?(consented, WithholdCensus.fine(&1)))
      |> Enum.map(&WithholdCensus.describe/1)

    assert unconsented == [],
           "silent withhold(s) with no funnel call and no consent row:\n  " <>
             Enum.join(unconsented, "\n  ")

    stale = consented |> MapSet.difference(keys) |> MapSet.to_list()

    assert stale == [],
           "consent row(s) that no longer match any branch — consenting to " <>
             "nothing while hiding whatever replaced them:\n  " <> inspect(stale, pretty: true)
  end

  test "5.2 the consent key must be FINE — the coarse key green-lights the rescue arm" do
    rows = WithholdCensus.rows()

    [rescue_arm] =
      Enum.filter(rows, &(&1.fun == :dispatch_event and &1.origin == :rescue and &1.shape == :ok))

    [empty_fanout] =
      Enum.filter(rows, &(&1.fun == :dispatch_event and &1.origin == :do and &1.path =~ ">empty"))

    # Two unrelated branches: one is the crash swallow, one is the empty team.
    refute WithholdCensus.fine(rescue_arm) == WithholdCensus.fine(empty_fanout)

    # The COARSE key cannot tell them apart — same name, same arity, same
    # observable shape (`:ok`), because BOTH are what the caller sees when
    # dispatch_event/3 returns.
    assert WithholdCensus.coarse(rescue_arm) == WithholdCensus.coarse(empty_fanout)
    assert WithholdCensus.coarse(rescue_arm) == {:dispatch_event, 3, :ok}

    # And the consequence, RUN rather than asserted in the abstract: put the
    # rescue arm back where it was before this slice (untraced) and resolve both
    # branches against a consent list holding only the empty-team row.
    hypothetical = [%{rescue_arm | traced: false}, empty_fanout]
    coarse_consent = MapSet.new([empty_fanout], &WithholdCensus.coarse/1)
    fine_consent = MapSet.new([empty_fanout], &WithholdCensus.fine/1)

    assert Enum.reject(hypothetical, &MapSet.member?(coarse_consent, WithholdCensus.coarse(&1))) ==
             [],
           "the coarse key was expected to green-light the rescue arm — that is why it is refused"

    assert [caught] =
             Enum.reject(hypothetical, &MapSet.member?(fine_consent, WithholdCensus.fine(&1)))

    assert caught.origin == :rescue
  end

  test "5.3 every reason handed to Withhold.record/4 is in the closed vocabulary" do
    # THE HAZARD THIS PINS: `record/4` guards on `reason in @reasons` and the
    # catch-all writes ZERO rows. A caller inventing a reason without adding it
    # to `@reasons` would rebuild this epic's own defect inside its own fix.
    used = WithholdCensus.reasons_used()

    assert length(used) >= 3,
           "expected the funnelled branches to name their reasons: #{inspect(used)}"

    for reason <- used do
      assert reason in Withhold.reasons(),
             "notifications.ex calls Withhold.record/4 with #{inspect(reason)}, which is NOT in " <>
               "Withhold.reasons() — that call writes zero rows and the withhold stays silent"

      assert is_binary(Withhold.label(reason))
    end
  end

  test "5.4 the RECEIPT-LOSS branches are named, not silent, and not mistaken for withholds" do
    derived = MapSet.new(WithholdCensus.receipt_loss())
    named = MapSet.new(Map.keys(@receipt_loss))

    assert derived == named,
           "an unadjudicated receipt-loss branch appeared (or a named one vanished): " <>
             inspect(MapSet.symmetric_difference(derived, named), pretty: true)
  end

  ## 6-8. THE THREE NEWLY-FUNNELLED BRANCHES, each DRIVEN — not read.

  defp chat_team(count) do
    {team, emails} = team_with_members(count)

    {:ok, _} =
      Notifications.put_channel(team, "slack", true, %{
        "url" => "https://203.0.113.12/services/T0/B0/xxx"
      })

    {team, emails}
  end

  defp suppressed(team), do: Notifications.list_deliveries(team, status: "suppressed", limit: 50)

  describe "the chat egress branches (job-queue seam programmed per process)" do
    setup do
      Application.put_env(:barkpark_cloud, :notifications_job_client, FakeJobClient)

      on_exit(fn ->
        Application.delete_env(:barkpark_cloud, :notifications_job_client)
      end)

      :ok
    end

    test "6. a CRASH inside dispatch_event/3 is swallowed AND written, one row per member" do
      {team, emails} = chat_team(2)
      FakeJobClient.program(:raise)

      log =
        capture_log(fn ->
          # The swallow is the contract — the producer's broadcast must not fail
          # because notifications did.
          assert :ok = Notifications.dispatch_event(team, :deployment_failed, %{})
        end)

      assert log =~ "Notifications.dispatch_event/3 crashed"

      rows = suppressed(team)
      assert length(rows) == 2
      assert rows |> Enum.map(& &1.recipient) |> Enum.sort() == Enum.sort(emails)

      for row <- rows do
        assert row.event == "deployment_failed"
        assert row.attempts == 0
        assert row.last_error == Withhold.label(:dispatch_crashed)
      end
    end

    test "7. a chat alert that is never ENQUEUED writes a row per member, named by channel" do
      {team, emails} = chat_team(2)
      FakeJobClient.program({:error, :queue_unavailable})

      log =
        capture_log(fn ->
          assert :ok = Notifications.dispatch_event(team, :deployment_failed, %{})
        end)

      # s1's two log lines still stand; this slice adds the ROW they lacked.
      assert log =~ "chat enqueue FAILED"
      assert log =~ "enqueued 0/1 channels"

      rows = suppressed(team)
      assert length(rows) == 2
      assert rows |> Enum.map(& &1.recipient) |> Enum.sort() == Enum.sort(emails)

      for row <- rows do
        assert row.channel == "slack"
        assert row.event == "deployment_failed"
        assert row.last_error == Withhold.label(:chat_enqueue_failed)
      end
    end
  end

  test "8. a chat job whose channel is GONE writes a row per member instead of vanishing" do
    {team, emails} = team_with_members(2)

    # No slack channel is configured at all — the job outlived the channel.
    assert {:cancel, :channel_gone} =
             Notifications.deliver_chat(team.id, "slack", "deployment_failed", %{})

    rows = suppressed(team)
    assert length(rows) == 2
    assert rows |> Enum.map(& &1.recipient) |> Enum.sort() == Enum.sort(emails)

    for row <- rows do
      assert row.channel == "slack"
      assert row.last_error == Withhold.label(:chat_channel_gone)
    end
  end

  ## 9. THE TWO CONSENTED BRANCHES — proved from the CONSTRAINT, not asserted.

  test "9. W2 and W6 are recipient-less by construction and are given no synthetic recipient" do
    # The clause every prior surveyor quoted and none re-derived: delivery.ex:78.
    cs =
      Delivery.changeset(%Delivery{}, %{
        team_id: nil,
        recipient: nil,
        event: "deployment_failed",
        kind: "alert",
        status: "suppressed"
      })

    refute cs.valid?
    assert %{recipient: ["can't be blank"]} = errors_on(cs)

    # W2 — an empty team: the fan-out runs zero times and NOTHING is written.
    team = empty_team()
    assert :ok = Notifications.dispatch_event(team, :test, %{})
    assert Notifications.list_deliveries(team, limit: 50) == []

    # W6 — the fleet digest with no reachable recipient. It writes no row, and
    # it now says so THROUGH THE FUNNEL: `deliver_fleet_digest/1` calls
    # `Withhold.record/4` and accounts the count it returns on the same WARNING
    # line an operator greps (`withheld=0`). `0` is the count this branch must
    # report — a non-zero would be a row on a branch D362 forbids one on — and
    # the absence of the catch-all's error line is what makes the call legal to
    # place here at all.
    assert Notifications.platform_admin_emails() == []

    log =
      capture_log(fn ->
        assert {:ok, :no_admins} = Notifications.deliver_fleet_digest([])
      end)

    assert log =~ "fleet_digest phase=settled"
    assert log =~ "withheld=0"
    refute log =~ "refused an unrecordable withhold"
  end
end
