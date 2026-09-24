defmodule BarkparkWeb.Studio.PdsW42ComponentRouteOpDecompositionTest do
  @moduledoc """
  task-c6e13ed8b2729bb4 — WHY the component route's TWO `write_denied?/1` calls
  CANNOT be collapsed to one, decided by run rather than by reading the count.

  ## The claim that sent this here

  `pds_w42_caps_derive_op_latency_test.exs` pins
  `@write_denied_per_component_op == 2` and its prose says the composite editor
  "enters the write seam twice per field commit (`inner-change`, then
  `inner-flush`)". Read quickly, that is a DUPLICATE inside one user action:
  two `Caps.derive/1` calls microseconds apart, one of them free to delete for
  a ~50% cut.

  ## What the run says instead: 1 derive per op, and there are TWO OPS

  That "2" is a property of the MEASUREMENT WINDOW, not of an op. The latency
  file's window spans two `render_hook/3` calls, and each one is a SEPARATE
  trip to persisted state:

    inner-change → `persist/4` → `send(self(), {:paper_op, op})`       (no request_id)
                 → `paper_pane_op/2` → `paper_pane_unidentified_op/2`  → write_denied?  → Content.apply_paper_block_op/4
    inner-flush  → `persist/4` → `send(self(), {:paper_op, op, rid})`  (request_id)
                 → `paper_pane_op/2` → `paper_pane_op_once/2` → `paper_ops/6` → write_denied?  → Content.apply_paper_ops_once

  Two different clauses of `paper_pane_op/2`, two different gate call sites,
  two different writes. Split the window (below) and each op prices at ONE
  derive and ONE `write_denied?`. There is no duplicate to collapse: the second
  call is the gate on the second write.

  ## And `inner-change` is a write seam a denied principal reaches ALONE

  This is the CAUTION the filing itself named, and it is the finding. A client
  that emits `inner-change` and never flushes — every keystroke in a composite
  field does exactly that, `phx-change="inner-change"` on the form — still
  reaches `Content.apply_paper_block_op/4`. Section 2 shows the store moving on
  a LONE `inner-change`, and section 3 shows a write-denied principal refused
  at that same lone entry with the store standing still. Deleting that gate to
  save one derive would hand a read-only principal the whole composite editor
  at typing speed and never trip the flush gate at all.

  ## Therefore the pin stays at 2, and section 4 is why it must

  A grant/permission that lapses BETWEEN the two ops must deny the SECOND one.
  One gate cannot do that for two writes at two instants: `write_denied?/1`
  answers for the socket AT THE MOMENT IT RUNS, and the whole reason the
  originating row refused a TTL memo is that an answer reused across a window
  is an answer with a staleness window. Collapsing two per-op gates into one is
  a TTL memo with a window of "until the next flush" — the same trade, spelled
  differently.

  `async: false` — a process trace has no business sharing the VM with a
  concurrent case in the same file.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.Repo
  alias Barkpark.{Auth, Content}
  alias BarkparkWeb.Studio.Caps
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper

  @dataset "production"
  @writer "pds-w42-decomp-writer"
  @readonly "pds-w42-decomp-readonly"
  @block_id "fb-price"

  # THE ASSERTED ROWS, per SINGLE op — the quantity the latency file's
  # two-hook window cannot express. Named so neither can move in the code and
  # stand still in the prose above.
  @derives_per_inner_change 1
  @derives_per_inner_flush 1
  @write_denied_per_inner_change 1
  @write_denied_per_inner_flush 1

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

    {:ok, writer_token} =
      Auth.create_token(
        @writer,
        "pds w42 decomposition writer",
        @dataset,
        ["read", "write"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    {:ok, _} =
      Auth.create_token(
        @readonly,
        "pds w42 decomposition readonly",
        @dataset,
        ["read"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    {:ok, writer_token: writer_token}
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

  defp open_editing!(conn, token, slug) do
    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => token})
      |> live(scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

    render_click(view, "paper-toggle-edit")
    assert render(view) =~ ~s(id="paper-fb-#{@block_id}")
    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp paper_rev(view), do: socket_of(view).assigns.paper_rev
  defp target(view), do: with_target(view, "#paper-fb-" <> @block_id)

  # Read from the STORE, never an assign, so every assertion here is falsifiable
  # in both directions.
  defp stored_value(slug) do
    paper = Content.get_paper(slug, @dataset)
    blocks = get_in(paper.content, ["blocks"]) || get_in(paper.content, ["body", "blocks"]) || []

    blocks
    |> Enum.find(%{}, &(Map.get(&1, "id") == @block_id))
    |> Map.get("value")
  end

  # ── the live probe (same arming contract as pds_w42_caps_derive_op_latency) ──
  #
  # `:local`, NOT `:global`: `Caps.derive/1` reaches `derive_from_assigns/1` by
  # an INTRA-MODULE call a `:global` pattern does not match. Pid-filtered to the
  # view, so a concurrent case's derives cannot land in this count.
  @probed [
    {Caps, :derive_from_assigns, 1},
    {Caps, :derive, 1},
    {Paper, :write_denied?, 1},
    {Caps, :gate, 3}
  ]

  defp sites_during(view_pid, fun) do
    for mfa <- @probed, do: :erlang.trace_pattern(mfa, true, [:local])
    :erlang.trace(view_pid, true, [:call])

    try do
      fun.()
      settle!(view_pid)
      drain_calls(%{})
    after
      :erlang.trace(view_pid, false, [:call])
      for mfa <- @probed, do: :erlang.trace_pattern(mfa, false, [:local])
    end
  end

  # A `:sys.get_state/1` is ONE BARRIER, NOT A DRAIN: the component's
  # `persist/4` does `send(self(), {:paper_op, …})` from inside `handle_event`,
  # so the write under measurement lands a GENERATION later. Loop until the
  # mailbox reads empty twice with a full barrier in between. The barrier is
  # deliberately NOT `render/1` — a re-render can itself reach a probed function
  # and inflate the number this file exists to publish; `:sys.get_state/1` calls
  # none of `@probed` and adds exactly zero to every counter.
  defp settle!(view_pid, quiet \\ 0, fuel \\ 50)
  defp settle!(_view_pid, 2, _fuel), do: :ok

  defp settle!(_view_pid, _quiet, 0) do
    flunk("the LiveView never went quiet inside sites_during/2 after 50 barriers")
  end

  defp settle!(view_pid, quiet, fuel) do
    :sys.get_state(view_pid)

    case :erlang.process_info(view_pid, :message_queue_len) do
      {:message_queue_len, 0} -> settle!(view_pid, quiet + 1, fuel - 1)
      _ -> settle!(view_pid, 0, fuel - 1)
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

  defp count(sites, mfa), do: Map.get(sites, mfa, 0)
  defp derives(sites), do: count(sites, {Caps, :derive_from_assigns, 1})

  defp report(label, sites) do
    IO.puts("\n[w21-decomp] call sites during #{label}:")

    for {m, f, a} = mfa <- @probed,
        do: IO.puts("  #{inspect(m)}.#{f}/#{a} : #{count(sites, mfa)}")
  end

  # ── 1. the decomposition: the "2" is 1+1 across two ops ─────────────────────

  describe "one op at a time, each window holding exactly ONE hook" do
    test "inner-change alone and inner-flush alone each cost ONE derive and ONE write_denied?",
         %{conn: conn} do
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-decomp-split"
      create_paper!(slug)
      view = open_editing!(conn, @writer, slug)

      change_values = %{"amount" => "311", "currency" => "NOK"}

      change_sites =
        sites_during(view.pid, fn ->
          render_hook(target(view), "inner-change", change_values)
        end)

      report("a LONE inner-change", change_sites)
      IO.puts("[w21-decomp] derives per LONE inner-change: #{derives(change_sites)}")

      assert derives(change_sites) == @derives_per_inner_change

      assert count(change_sites, {Paper, :write_denied?, 1}) ==
               @write_denied_per_inner_change

      # NOT the socket gate: a `handle_info` cannot trip an
      # `attach_hook(_, :handle_event, _)`, which is the whole reason the
      # chokepoint gate exists.
      assert count(change_sites, {Caps, :gate, 3}) == 0

      flush_values = %{"amount" => "312", "currency" => "NOK"}

      flush_sites =
        sites_during(view.pid, fn ->
          render_hook(target(view), "inner-flush", %{
            "request_id" => Ecto.UUID.generate(),
            "if_rev" => paper_rev(view),
            "values" => flush_values
          })
        end)

      report("a LONE inner-flush", flush_sites)
      IO.puts("[w21-decomp] derives per LONE inner-flush: #{derives(flush_sites)}")

      assert derives(flush_sites) == @derives_per_inner_flush
      assert count(flush_sites, {Paper, :write_denied?, 1}) == @write_denied_per_inner_flush
      assert count(flush_sites, {Caps, :gate, 3}) == 0

      # THE POINT, stated as an assertion rather than as prose: the latency
      # file's `@write_denied_per_component_op == 2` is the SUM of two
      # single-gate ops, not a duplicate inside one.
      assert @write_denied_per_inner_change + @write_denied_per_inner_flush == 2

      # And the second op really did land, so neither window priced a no-op.
      assert stored_value(slug) == flush_values
    end
  end

  # ── 2. inner-change is an INDEPENDENT trip to persisted state ───────────────

  describe "a LONE inner-change, with no flush ever sent" do
    test "reaches the store on its own", %{conn: conn} do
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-decomp-change-writes"
      create_paper!(slug)
      view = open_editing!(conn, @writer, slug)

      assert stored_value(slug) == %{"amount" => "299", "currency" => "NOK"}

      render_hook(target(view), "inner-change", %{"amount" => "777", "currency" => "NOK"})
      # The write lands in a LATER handle_info; drain before reading the store
      # or this reports a false "no write".
      settle!(view.pid)

      assert stored_value(slug) == %{"amount" => "777", "currency" => "NOK"},
             "inner-change did NOT write on its own — if this ever becomes true, " <>
               "the gate on paper_pane_unidentified_op/2 is no longer load-bearing " <>
               "and the collapse this file refuses could be reconsidered."
    end
  end

  # ── 3. THE REFUSAL, pinned: that lone entry is gated ────────────────────────

  describe "a write-denied principal at the LONE inner-change entry" do
    test "is refused there, with no flush involved and the store unmoved", %{conn: conn} do
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-decomp-denied"
      create_paper!(slug)
      view = open_editing!(conn, @readonly, slug)

      # PRECONDITION, asserted on the LIVE socket rather than assumed from the
      # fixture: this principal really is write-denied, so the refusal below
      # cannot be "the composite editor never writes here".
      socket = socket_of(view)
      assert Caps.derive(socket).write == false
      assert Paper.write_denied?(socket) == true

      render_hook(target(view), "inner-change", %{"amount" => "ESCALATED", "currency" => "NOK"})
      settle!(view.pid)

      assert stored_value(slug) == %{"amount" => "299", "currency" => "NOK"}
      assert socket_of(view).assigns.flash["error"] == "You don't have access to do that."
    end
  end

  # ── 4. the property the collapse would trade away ───────────────────────────

  describe "a principal downgraded BETWEEN two ops on the component route" do
    test "the first op writes and the SECOND is denied — one gate per op is what buys that",
         %{conn: conn, writer_token: writer_token} do
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-decomp-midsession"
      create_paper!(slug)
      view = open_editing!(conn, @writer, slug)

      assert Caps.derive(socket_of(view)).write == true

      # OP 1 — inner-change, while still capable. This is the op whose gate
      # answer a collapse would reuse.
      render_hook(target(view), "inner-change", %{"amount" => "401", "currency" => "NOK"})
      settle!(view.pid)
      assert stored_value(slug) == %{"amount" => "401", "currency" => "NOK"}

      # THE LAPSE, between the two ops: one column edit, no re-mount, no event
      # on this socket. Exactly the mid-session shape the originating row
      # refused to memoize away.
      {1, _} =
        Barkpark.Auth.ApiToken
        |> where([t], t.id == ^writer_token.id)
        |> Repo.update_all(set: [permissions: ["read"]])

      # OP 2 — inner-flush, the SECOND op of the same field commit. Its own
      # gate derives fresh and refuses.
      render_hook(target(view), "inner-flush", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "values" => %{"amount" => "402", "currency" => "NOK"}
      })

      settle!(view.pid)

      assert stored_value(slug) == %{"amount" => "401", "currency" => "NOK"},
             "the SECOND op of a field commit wrote after the principal lost :write — " <>
               "that is precisely what collapsing the two per-op gates into one would buy."

      assert socket_of(view).assigns.flash["error"] == "You don't have access to do that."
    end

    test "NO OVER-DENY: the same two ops, no downgrade, both land", %{conn: conn} do
      System.put_env("BARKPARK_PAPER_CANVAS", "0")
      slug = "pds-w42-decomp-midsession-control"
      create_paper!(slug)
      view = open_editing!(conn, @writer, slug)

      render_hook(target(view), "inner-change", %{"amount" => "401", "currency" => "NOK"})
      settle!(view.pid)
      assert stored_value(slug) == %{"amount" => "401", "currency" => "NOK"}

      render_hook(target(view), "inner-flush", %{
        "request_id" => Ecto.UUID.generate(),
        "if_rev" => paper_rev(view),
        "values" => %{"amount" => "402", "currency" => "NOK"}
      })

      settle!(view.pid)
      assert stored_value(slug) == %{"amount" => "402", "currency" => "NOK"}
      assert socket_of(view).assigns.flash["error"] == nil
    end
  end
end
