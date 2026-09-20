defmodule BarkparkWeb.Studio.PdsW42CapsDeriveOpLatencyTest do
  @moduledoc """
  pds-w42-bl-caps-derive-per-op-cost-unmeasured — THE PER-OP COST of
  `BarkparkWeb.Studio.Caps.derive/1` at the paper write chokepoint
  (`Shared.Paper.paper_pane_op/2`), measured BY RUN.

  ## What was actually unmeasured

  `pds_w43_caps_derive_cost_test.exs` prices ONE `derive/1` in REPO QUERIES and
  says so honestly: "A per-derive count says nothing about how often `derive/1`
  is called." That is the hole this file fills. Two questions, two units:

    1. HOW MANY `derive/1` calls does ONE real paper block op cost? Answered by
       a LIVE TRACE of the view process across a genuine `paper-op` round trip
       — NOT by `grep -c`, which counts LINES in source and is blind to a call
       reached through `defdelegate`, a `handle_info` hop or any dynamic
       dispatch. Every call site on this path is reached through at least one
       of those, so a source count was never going to be right.
    2. WHAT DOES ONE `derive/1` COST? Answered in REDUCTIONS, which is
       load-invariant, plus a repo-query count. Both are asserted. Wall and CPU
       milliseconds are NOT asserted here (see THE PRICE below).

  ## THE CALL COUNT: 1 per op, not 2 (measured, and it corrects the row)

  The task row says "the new `write_denied?/1` calls `Caps.derive/1` on EVERY
  paper block op", and `Caps.derive/1`'s own @doc says the autosave path runs
  `derive/1` TWICE per event — the socket gate (`Caps.gate/3`) and then
  `write_denied?/1`. BOTH are true of the `paper-op` EVENT. Neither is true of
  the door this row names. `paper_pane_op/2` is reached from
  `handle_info({:paper_op, op})`, and `Caps.attach/1` installs
  `attach_hook(_, :handle_event, _)`, which a `handle_info` cannot trip — that
  blindness is the whole reason the chokepoint gate exists (see
  `pds_w42_paper_op_principal_gate_test.exs`). So on the component route the
  socket gate does not fire and `derive/1` runs ONCE, not twice.

  This is measured below, both routes, in one test. It matters for the
  decision: the marginal cost this row was filed to price is ONE derive, and on
  the EVENT route the second derive is the pre-existing gate, not this fix.

  ## THE PRICE, and why no millisecond is asserted (PDS-D633 / PDS-D656)

  `:erlang.statistics(:runtime)` is VM-GLOBAL: blind to port children, blind to
  I/O wait and to Postgres' own CPU, floored at 1 ms, and inflated ~5x by
  concurrent processes in the same VM. A price must therefore come from an OS
  meter around a SHELL, and it is quotable only against its OWN load stamp.

  The row asks for a figure ON A QUIET HOST. This one was taken under heavy
  concurrent agent load and the band is REPORTED WITH ITS LOAD STAMP rather
  than laundered into a clean number — see the MEASUREMENT RECORD below. That
  is why the ratchet in this file is in REDUCTIONS: a reduction count does not
  move when the host is busy, and a millisecond moves 5x.

  ## MEASUREMENT RECORD — see `caps-derive-per-op-cost.md` next to this file.

  The OS-metered A/B, its command, its n, its load stamps and the decision all
  live in that note so a reader gets the numbers without reading the harness.

  `async: false` — a process trace and a cost measurement have no business
  sharing the VM with a concurrent case in the same file.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @writer "pds-w42-lat-writer"
  @block_id "fb-price"

  # THE ASSERTED ROWS. Named, so a number cannot move in the code and stand
  # still in the prose that quotes it.
  #
  # TWO derives per op on BOTH routes — MEASURED, and it is not the same two.
  # The breakdown is what carries the meaning, so the breakdown is what is
  # asserted:
  #
  #   COMPONENT route  2 derives = 2x write_denied?  + 0x socket gate
  #   EVENT route      2 derives = 1x write_denied?  + 1x socket gate
  #
  # So the derives THIS ROW'S FIX ADDED are 2 on the component route and 1 on
  # the event route. The component route pays twice because the composite
  # editor enters the write seam twice per field commit (`inner-change`, then
  # `inner-flush`), and it has no socket gate at all — that blindness is the
  # bypass `pds_w42_paper_op_principal_gate_test.exs` was filed to close.
  @derives_per_component_op 2
  @derives_per_event_op 2
  @write_denied_per_component_op 2
  @write_denied_per_event_op 1
  # Repo queries per derive, MEASURED on the live mounted socket, per PRINCIPAL
  # SHAPE — because the cost is not one number and the difference is a finding.
  #
  # API-TOKEN socket: 1 `%ApiToken{}` reload + 1 membership `Repo.one` = 2.
  # USER socket:      1 membership `Repo.one` + 1 grant `Repo.all` = 2.
  #
  # THE GRANT LOAD IS NOT UNCONDITIONAL, and that is worth saying plainly
  # because the prose next door reads as if it were.
  # `pds_w43_caps_derive_cost_test.exs` says "the grant `Repo.all`
  # (`Access.list_active_grants_for_grantee/1`) is still issued UNCONDITIONALLY
  # on every `derive/1`". Read against the source it means "not memoized", and
  # in that sense it is true. Read literally it is not: `active_grants/1`
  # (caps.ex) matches on `assigns.current_user` and returns `[]` — issuing NO
  # query — for any socket without one. A Studio socket authenticated by an API
  # TOKEN therefore never pays the grant load at all. Measured here, both ways,
  # rather than inherited from the sentence.
  @queries_per_derive_token 2
  @queries_per_derive_user 2
  # A CEILING, not a measurement: reductions are load-invariant but not
  # bit-stable across OTP/dep versions, so the ratchet is an upper bound with
  # headroom. It reds on a change that makes derive materially more expensive
  # and stays quiet on noise. The OBSERVED value is printed on every run.
  @max_reductions_per_derive 60_000

  @repo_query_event [:barkpark, :repo, :query]

  setup do
    prev = System.get_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    # A WRITE-capable api token. The denial path short-circuits before the
    # write, so a denied principal would price the CHEAP arm; the cost this row
    # asks about is the one a real editor pays.
    {:ok, _} =
      Auth.create_token(
        @writer,
        "pds w42 latency",
        @dataset,
        ["read", "write"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    :ok
  end

  defp create_paper!(slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "W42"},
      %{
        "id" => @block_id,
        "type" => "composite",
        "label" => "Price",
        "fields" => [
          %{"name" => "amount", "title" => "Amount", "type" => "string"},
          %{"name" => "currency", "title" => "Currency", "type" => "string"}
        ],
        "value" => %{"amount" => "299", "currency" => "NOK"}
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
      )

    paper
  end

  defp open!(conn, slug) do
    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => @writer})
      |> live(scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp paper_rev(view), do: socket_of(view).assigns.paper_rev

  defp stored_value(slug) do
    paper = Content.get_paper(slug, @dataset)

    blocks = get_in(paper.content, ["blocks"]) || get_in(paper.content, ["body", "blocks"]) || []

    blocks
    |> Enum.find(%{}, &(Map.get(&1, "id") == @block_id))
    |> Map.get("value")
  end

  # ── the live probe ──────────────────────────────────────────────────────────
  #
  # Traces CALLS to `Caps.derive_from_assigns/1` — the one function BOTH
  # `derive/1` and `write_capable_now?/1` funnel through, so no route can reach
  # a capability decision without passing this counter — IN THE VIEW PROCESS
  # ONLY. Node-global tracing would pick up a concurrent case's derives; the
  # pid filter is what makes the count descend from THIS op and nothing else.
  @probed [
    {Caps, :derive_from_assigns, 1},
    {Caps, :derive, 1},
    {Caps, :write_capable_now?, 1},
    {Paper, :write_denied?, 1},
    {Caps, :gate, 3}
  ]

  defp derives_during(view_pid, fun) do
    # `:local`, NOT `:global`. `Caps.derive/1` reaches `derive_from_assigns/1`
    # by an INTRA-MODULE call, which a `:global` trace pattern does not match —
    # the first draft of this probe was armed `:global` and reported 0 derives
    # for an op that had demonstrably just written to the store. A counter that
    # reads zero on the happy path is the signature of a mis-armed instrument,
    # not of a free call.
    for mfa <- @probed, do: :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(view_pid, true, [:call])

    try do
      fun.()
      # Force the view to drain its mailbox: the component route writes in a
      # LATER handle_info, and counting before that drains reports a false 0.
      :sys.get_state(view_pid)
      drain_calls(%{})
    after
      :erlang.trace(view_pid, false, [:call])
      for mfa <- @probed, do: :erlang.trace_pattern(mfa, false, [:local])
    end
  end

  defp drain_calls(acc) do
    receive do
      {:trace, _pid, :call, {m, f, args}} ->
        drain_calls(Map.update(acc, {m, f, length(args)}, 1, &(&1 + 1)))

      {:trace, _pid, :call, _} ->
        drain_calls(acc)
    after
      0 -> acc
    end
  end

  defp derive_count(acc), do: Map.get(acc, {Caps, :derive_from_assigns, 1}, 0)

  defp report_sites(label, acc) do
    IO.puts("\n[pds-w42] call sites during #{label}:")

    for mfa <- @probed do
      {m, f, a} = mfa
      IO.puts("  #{inspect(m)}.#{f}/#{a} : #{Map.get(acc, mfa, 0)}")
    end
  end

  defp queries_during(fun) do
    owner = self()
    ref = make_ref()
    counter = :counters.new(1, [])
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      @repo_query_event,
      fn _, _, _, _ -> if self() == owner, do: :counters.add(counter, 1, 1) end,
      nil
    )

    try do
      fun.()
      :counters.get(counter, 1)
    after
      :telemetry.detach(handler)
    end
  end

  # ── 1. HOW MANY derives does one op cost? ───────────────────────────────────

  describe "derive/1 calls per paper write op, counted by trace on the live socket" do
    test "the component route (handle_info → paper_pane_op/2) costs exactly one derive",
         %{conn: conn} do
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-lat-component"
      create_paper!(slug)

      view = open!(conn, slug)
      render_click(view, "paper-toggle-edit")
      assert render(view) =~ ~s(id="paper-fb-#{@block_id}")

      target = with_target(view, "#paper-fb-" <> @block_id)
      values = %{"amount" => "301", "currency" => "NOK"}
      rev = paper_rev(view)

      sites =
        derives_during(view.pid, fn ->
          render_hook(target, "inner-change", values)

          render_hook(target, "inner-flush", %{
            "request_id" => Ecto.UUID.generate(),
            "if_rev" => rev,
            "values" => values
          })

          render(view)
        end)

      # The write ACTUALLY HAPPENED — otherwise this counts the cost of a
      # no-op and calls it a per-op price. Read from the store, not an assign.
      assert stored_value(slug) == %{"amount" => "301", "currency" => "NOK"}

      report_sites("ONE COMPONENT-route paper op", sites)
      n = derive_count(sites)
      IO.puts("[pds-w42] derives per COMPONENT-route paper op: #{n}")
      assert n == @derives_per_component_op

      # ARM A of the ratchet — ALL of this route's derives are the chokepoint
      # gate's. Reverting that gate (the thing this row prices) drops this to 0
      # and reds here.
      assert Map.get(sites, {Paper, :write_denied?, 1}, 0) == @write_denied_per_component_op

      # ARM B — and NONE of them are the socket gate's, because a `handle_info`
      # cannot trip an `attach_hook(_, :handle_event, _)`. If a future edit ever
      # routed this door through the socket gate, this zero would rise and the
      # attribution above would silently stop being true.
      assert Map.get(sites, {Caps, :gate, 3}, 0) == 0
    end

    test "the paper-op EVENT route costs two: the socket gate, then the chokepoint",
         %{conn: conn} do
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-lat-event"
      create_paper!(slug)

      view = open!(conn, slug)
      rev = paper_rev(view)

      sites =
        derives_during(view.pid, fn ->
          render_hook(view, "paper-op", %{
            "request_id" => Ecto.UUID.generate(),
            "if_rev" => rev,
            "op" => "patch-block",
            "id" => @block_id,
            "patch" => %{"value" => %{"amount" => "302", "currency" => "NOK"}}
          })

          render(view)
        end)

      assert stored_value(slug) == %{"amount" => "302", "currency" => "NOK"}

      report_sites("ONE paper-op EVENT", sites)
      n = derive_count(sites)
      IO.puts("[pds-w42] derives per paper-op EVENT: #{n}")
      assert n == @derives_per_event_op

      # On THIS route only ONE of the two derives is the chokepoint gate's —
      # the other is the pre-existing socket gate, which this row did not add
      # and must not be billed for.
      assert Map.get(sites, {Paper, :write_denied?, 1}, 0) == @write_denied_per_event_op
      assert Map.get(sites, {Caps, :gate, 3}, 0) == 1
    end
  end

  # ── 2. WHAT DOES ONE derive COST? ───────────────────────────────────────────

  describe "the price of one derive/1 on a mounted studio socket" do
    test "queries and reductions per derive, both principal shapes, on the live socket",
         %{conn: conn} do
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-lat-price"
      create_paper!(slug)

      view = open!(conn, slug)
      token_assigns = socket_of(view).assigns

      # PRECONDITION, asserted rather than assumed: this socket must actually
      # be write-capable and carry a resolved workspace, or the figure below is
      # the price of the CHEAP early-return arm (`derive_from_assigns/1` skips
      # the principal list entirely when ws_id is not a binary) and the whole
      # measurement is vacuous.
      caps = Caps.derive_from_assigns(token_assigns)
      assert caps.write == true
      assert is_binary(token_assigns.current_workspace.id)
      assert is_struct(token_assigns.api_token)

      # THE SECOND PRINCIPAL SHAPE, built off the SAME live socket's assigns so
      # only the principal differs: a member USER and no token. This is the
      # shape that pays the grant `Repo.all`.
      user = user_principal!(token_assigns.current_workspace)

      user_assigns =
        token_assigns |> Map.put(:api_token, nil) |> Map.put(:current_user, user)

      user_caps = Caps.derive_from_assigns(user_assigns)
      assert user_caps.write == true

      token = price!("API-TOKEN socket", token_assigns)
      user_row = price!("USER socket", user_assigns)

      assert token.q == @queries_per_derive_token,
             "token derive issued #{token.q} q/op, expected #{@queries_per_derive_token}"

      assert user_row.q == @queries_per_derive_user,
             "user derive issued #{user_row.q} q/op, expected #{@queries_per_derive_user}. " <>
               "A DROP is the DANGEROUS direction: the grant `Repo.all` is what buys " <>
               "mid-session expiry truth, and memoizing it away is the trade this row " <>
               "decided AGAINST."

      assert token.reductions <= @max_reductions_per_derive,
             "token derive cost #{token.reductions} reductions, ceiling #{@max_reductions_per_derive}"

      assert user_row.reductions <= @max_reductions_per_derive,
             "user derive cost #{user_row.reductions} reductions, ceiling #{@max_reductions_per_derive}"
    end
  end

  defp user_principal!(ws) do
    email = "w42-lat-#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      Barkpark.Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    user
  end

  # n for the in-VM rows. The OS-METERED price is taken by running this same
  # file twice under `times` with CAPS_DERIVE_BENCH_N set low and high and
  # differencing the two arms INSIDE ONE LOAD STAMP — see
  # caps-derive-per-op-cost.md for the command, the n and the band.
  @ops (System.get_env("CAPS_DERIVE_BENCH_N") || "200") |> String.to_integer()

  defp price!(label, assigns) do
    # Warm: the first calls pay code loading and a connection checkout that no
    # steady-state op pays.
    Enum.each(1..20, fn _ -> Caps.derive_from_assigns(assigns) end)

    q =
      queries_during(fn -> Enum.each(1..@ops, fn _ -> Caps.derive_from_assigns(assigns) end) end)

    {:reductions, r0} = Process.info(self(), :reductions)
    Enum.each(1..@ops, fn _ -> Caps.derive_from_assigns(assigns) end)
    {:reductions, r1} = Process.info(self(), :reductions)

    row = %{q: div(q, @ops), reductions: div(r1 - r0, @ops)}

    IO.puts("""

    [pds-w42] ONE Caps.derive/1 — #{label} (n=#{@ops}):
      repo queries : #{row.q} q/derive
      reductions   : #{row.reductions} reductions/derive  (LOAD-INVARIANT — this is the ratchet)
      NOT ASSERTED : any millisecond. :erlang.statistics(:runtime) is VM-GLOBAL,
                     blind to Postgres' own CPU and to I/O wait, floored at 1 ms,
                     and inflated ~5x by concurrent processes in the same VM.
                     The OS-metered wall/CPU band and its load stamp are in
                     caps-derive-per-op-cost.md beside this file.
    """)

    row
  end
end
