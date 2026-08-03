defmodule BarkparkWeb.Studio.PdsW43CapsDeriveCostTest do
  @moduledoc """
  pds-w43 / PDS-D634 — THE COST INSTRUMENT for `BarkparkWeb.Studio.Caps.derive/1`,
  and the ratchet that keeps the collapse collapsed.

  WHAT IT MEASURES, AND WHY THAT UNIT. `derive/1` used to ask
  `Tenancy.Auth.authorize/3` three times per principal (`:read`, `:write`, and
  `admin?/1`'s `:admin`), and each of those issues its own BYTE-IDENTICAL
  `Tenancy.Auth.membership/2` `Repo.one`. This file counts REPO QUERIES, not
  time, because the query count is the only figure that is LOAD-INVARIANT: a
  verifier ran the identical loop three times and wall swung 2.47 → 18.52 ms/op
  (a 7.5x spread) while the count did not move by one — 8.000, 8.000, 8.000. So
  the counts are ASSERTED and the millisecond/wall figures are PRINTED ONLY.
  Nothing in this file asserts a duration.

  PROCESS-SCOPED COUNTER, DELIBERATELY. `:telemetry.attach/4` is NODE-global:
  an unscoped counter over-counted 800 as 806 on a verifier's first pass,
  picking up queries from unrelated processes in the same VM. The handler runs
  IN the querying process, so `self() == owner` is the filter that makes the
  count descend from THIS measurement and nothing else.

  BLIND SPOT, STATED WHERE IT IS USED (PDS-D633) — this sentence is printed
  alongside every row, not left in prose:

  ":erlang.statistics(:runtime) is a VM-GLOBAL sum of BEAM scheduler +
  async-thread CPU. It is accurate to <1% for pure in-BEAM work, blind to port
  children (2.58 s read as 6 ms), blind to I/O wait and to Postgres' own CPU,
  floored at 1 ms, and inflated by any concurrent process in the same VM (5.0x
  under 8 siblings)."

  HONEST SCOPE — three things this file does NOT claim:

    * The EVENT row is the TWO authorization derives an autosave performs
      (`Caps.gate/3`, then `Shared.Paper.write_denied?/1`), NOT a full event
      round-trip; a real round-trip also loads the document, and that load is
      not this slice's cost.
    * The principals here hold NO grants. A grantee's `Access.admits_desk?/3`
      re-validates the GRANTOR per action, which issues its own queries — a
      real and separate cost this instrument does not price.
    * A per-derive count says nothing about how often `derive/1` is called.
      The autosave path calls it twice per debounced keystroke; at
      `phx-debounce="500"` that is the multiplier, and it is unchanged here.

  WHAT MUST NOT REGRESS: the grant `Repo.all` (`Access.list_active_grants_for_grantee/1`)
  is still issued UNCONDITIONALLY on every `derive/1` — it is the load that buys
  mid-session grant-expiry truth. The USER row's 2 queries ARE 1 membership + 1
  grant load; if the grant load were memoized away the USER row would read 1 and
  this file would go RED on the wrong side of a freshness trade.

  `async: false` — a node-global telemetry attach and a CPU measurement have no
  business sharing the VM with a concurrent case in the same file.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Auth}
  alias BarkparkWeb.Studio.Caps

  # Default Ecto telemetry event for a repo with `otp_app: :barkpark`.
  @repo_query_event [:barkpark, :repo, :query]
  @dataset "production"
  @ops 200

  # PDS-D633, verbatim. Printed with every row AND carried in the @moduledoc
  # above; `the blind-spot sentence is in BOTH places` pins that they agree.
  @blind_spot ":erlang.statistics(:runtime) is a VM-GLOBAL sum of BEAM scheduler + " <>
                "async-thread CPU. It is accurate to <1% for pure in-BEAM work, blind to port " <>
                "children (2.58 s read as 6 ms), blind to I/O wait and to Postgres' own CPU, " <>
                "floored at 1 ms, and inflated by any concurrent process in the same VM (5.0x " <>
                "under 8 siblings)."

  setup do
    {ws, proj} = ensure_default_scope!()
    {:ok, ws: ws, proj: proj}
  end

  # A bare socket carrying exactly the assigns `derive/1` reads. Deliberately
  # NOT a mounted LiveView: a mount issues dozens of unrelated queries, and the
  # figure under test is the cost of ONE derive, not of a page.
  defp socket(ws, proj, assigns) do
    %Phoenix.LiveView.Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            current_workspace: ws,
            current_project: proj,
            dataset: @dataset,
            api_token: nil,
            current_user: nil
          },
          assigns
        )
    }
  end

  defp user_principal(ws) do
    email = "w43-cost-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Barkpark.Tenancy.Auth.create_membership(ws.id, user.id, "member", "user")
    user
  end

  defp token_principal do
    raw = "w43-cost-token-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "w43 cost", @dataset, ["read", "write"])
    token
  end

  # THE METER. Counts `[:barkpark, :repo, :query]` events fired BY THIS PROCESS
  # while `fun` runs `n` times, and returns the total. Prints per-op query
  # count, user-CPU ms and wall ms — and the blind-spot sentence, because a
  # number without its blind spot is the thing PDS-D633 is about.
  defp meter(label, n, fun) do
    counter = :counters.new(1, [:atomics])
    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        @repo_query_event,
        fn _event, _measurements, _metadata, %{owner: owner, counter: counter} ->
          # The handler runs IN the querying process. A node-global attach
          # otherwise counts every other process's queries too.
          if self() == owner, do: :counters.add(counter, 1, 1)
        end,
        %{owner: owner, counter: counter}
      )

    {runtime_before, _} = :erlang.statistics(:runtime)
    wall_before = System.monotonic_time(:microsecond)

    try do
      Enum.each(1..n//1, fn _ -> fun.() end)
    after
      :telemetry.detach(handler_id)
    end

    wall_us = System.monotonic_time(:microsecond) - wall_before
    {runtime_after, _} = :erlang.statistics(:runtime)
    queries = :counters.get(counter, 1)

    print_row(label, n, queries, runtime_after - runtime_before, wall_us)
    queries
  end

  defp print_row(label, n, queries, runtime_ms, wall_us) do
    per_op = if n > 0, do: Float.round(queries / n, 3), else: 0.0

    IO.puts("""

    ── pds-w43 Caps.derive/1 cost ─────────────────────────────────────────────
    #{label}
      ops                : #{n}
      repo queries       : #{queries}   (ASSERTED)
      queries / op       : #{:erlang.float_to_binary(per_op, decimals: 3)}   (ASSERTED)
      user CPU (runtime) : #{runtime_ms} ms   (PRINTED ONLY — never asserted)
      wall               : #{Float.round(wall_us / 1000, 2)} ms   (PRINTED ONLY — never asserted)
      blind spot         : #{@blind_spot}
    """)
  end

  # ── the control: a meter that can read zero ─────────────────────────────────

  test "n=0 CONTROL: the meter reads ZERO queries when nothing runs", %{ws: ws, proj: proj} do
    user = user_principal(ws)
    sock = socket(ws, proj, %{current_user: user})

    # If this row is non-zero the meter is counting something other than the
    # work under test, and every other row in this file is worthless.
    assert meter("CONTROL n=0 (USER principal socket, derive NOT called)", 0, fn ->
             Caps.derive(sock)
           end) == 0
  end

  # ── the collapsed derive ────────────────────────────────────────────────────

  describe "Caps.derive/1 query cost per op" do
    test "USER principal: exactly 2 queries per derive (was 4)", %{ws: ws, proj: proj} do
      user = user_principal(ws)
      sock = socket(ws, proj, %{current_user: user})

      # Answer first, cost second — a cheap derive that answers wrongly is not
      # an improvement.
      assert Caps.derive(sock) == %{read: true, write: true, admin: false}

      queries = meter("USER principal — Caps.derive/1", @ops, fn -> Caps.derive(sock) end)

      # 1 membership Repo.one (reused for :read/:write/:admin — was 3 identical
      # loads) + 1 UNCONDITIONAL grant Repo.all (the freshness load, kept).
      assert queries == 2 * @ops
    end

    test "API-TOKEN principal: exactly 1 query per derive (was 2)", %{ws: ws, proj: proj} do
      token = token_principal()
      sock = socket(ws, proj, %{api_token: token})

      assert Caps.derive(sock) == %{read: true, write: true, admin: false}

      queries = meter("API-TOKEN principal — Caps.derive/1", @ops, fn -> Caps.derive(sock) end)

      # 1 membership Repo.one. No grant load at all: grants are bound to a
      # grantee USER, and `active_grants/1` returns [] without querying when the
      # socket carries no `current_user`.
      assert queries == 1 * @ops
    end

    test "EVENT path (the two authorization derives an autosave performs): exactly 4 (was 8)", %{
      ws: ws,
      proj: proj
    } do
      user = user_principal(ws)
      sock = socket(ws, proj, %{current_user: user})

      # The autosave path derives TWICE for one event: `Caps.gate/3` (the
      # socket-level deny-gate) and `Shared.Paper.write_denied?/1` (the
      # chokepoint). Both are spelled here as they are spelled there.
      event_path = fn ->
        Caps.write_capable?(sock.assigns, Caps.derive(sock))
        Caps.write_capable?(sock.assigns, Caps.derive(sock))
      end

      queries =
        meter("EVENT path — Caps.gate/3 + Shared.Paper.write_denied?/1", @ops, event_path)

      assert queries == 4 * @ops
    end

    test "an unresolved workspace costs NOTHING — no principal load, no grant load", %{
      proj: proj
    } do
      user = %Barkpark.Accounts.User{id: Ecto.UUID.generate()}

      sock = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          current_workspace: nil,
          current_project: proj,
          dataset: @dataset,
          api_token: nil,
          current_user: user
        }
      }

      assert Caps.derive(sock) == %{read: false, write: false, admin: false}

      queries = meter("UNRESOLVED workspace — Caps.derive/1", @ops, fn -> Caps.derive(sock) end)
      assert queries == 0
    end
  end

  # ── the discipline is mechanical, not prose ─────────────────────────────────

  test "the blind-spot sentence is in BOTH the @moduledoc and the printed output" do
    source = File.read!(__ENV__.file)

    [_head, moduledoc | _rest] = String.split(source, ~s("""))

    # The @moduledoc wraps the sentence across lines, so compare on collapsed
    # whitespace — the WORDS must be identical, not the line breaks.
    assert collapse(moduledoc) =~ collapse(@blind_spot)

    # And the same string is what `print_row/5` emits (it interpolates
    # @blind_spot directly — one literal, two surfaces).
    output =
      ExUnit.CaptureIO.capture_io(fn -> print_row("SENTENCE CHECK", 1, 1, 0, 1_000) end)

    assert output =~ @blind_spot
  end

  defp collapse(text), do: text |> String.split() |> Enum.join(" ")
end
