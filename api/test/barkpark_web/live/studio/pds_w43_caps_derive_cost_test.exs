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

  BUILT-IN-ROLE ONLY — WHAT THE ASSERTED NUMBERS ACTUALLY COVER (arpss-w10).
  The 2.000 / 1.000 / 4.000 figures are true for a BUILT-IN role and ONLY for a
  built-in role, and so is `Caps.derive/1`'s own docstring ("a USER-principal
  derive is 2 queries (was 4)"). `Tenancy.Auth.granted_actions/2` resolves
  owner/admin/member from the compiled-in `@builtin_role_actions` map BEFORE
  `db_actions/2` ever runs, so `role_permits?/3` costs ZERO queries for a
  built-in role and ONE `Repo.all` for any CUSTOM role — and `derive/1` reaches
  `role_permits?/3` THREE times per user principal (`:read`, `:write`, and
  `admin_from` → `account_admin_from`). Measured here, and ASSERTED below:

                                        built-in role      custom role
      Caps.derive/1, USER principal          2.0 q/op          5.0 q/op
      EVENT path (two derives)               4.0 q/op         10.0 q/op
      Tenancy.Auth.role_permits?/3           0.0 q/op          1.0 q/op
      Caps.admin?/1, user socket             1.0 q/op          2.0 q/op

  WHAT pds-w43 ACTUALLY COLLAPSED was the MEMBERSHIP row — three byte-identical
  `Repo.one`s became one. The ROLE resolution was NEVER collapsed and is still
  resolved THREE TIMES per derive; on a built-in role that is free and therefore
  invisible, on a custom role it is three extra round-trips. A debounced
  keystroke on a custom-role socket costs TEN queries, not four. No existing
  assertion is raised or weakened by this: those rows are correct for what they
  measure, the custom-role rows are added BESIDE them.

  DELIBERATELY NOT METERED: `Caps.admin?/1` on an API-TOKEN socket. It reads 0
  today, and the sibling slice (arpss-w10-caps-admin-parity-table) is what
  changes it; that number is that slice's cost obligation and a row here would
  red its merge.

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

  alias Barkpark.{Accounts, Auth, Repo, Tenancy}
  alias Barkpark.Tenancy.{Role, RolePermission}
  alias BarkparkWeb.Studio.Caps

  # Default Ecto telemetry event for a repo with `otp_app: :barkpark`.
  @repo_query_event [:barkpark, :repo, :query]
  @dataset "production"
  @ops 200

  # THE ASSERTED ROWS, as attributes rather than literals. `Caps.derive/1`'s own
  # @doc quotes these same five integers, and `the @doc for Caps.derive/1 names
  # the numbers this file ASSERTS` below rebuilds the @doc's sentences from
  # THESE names — so a number can no longer move in one place and stand still in
  # the other (arpss-w10-caps-docstring-builtin-only).
  @builtin_user_q 2
  @builtin_token_q 1
  @builtin_event_q 4
  @custom_user_q 5
  @custom_event_q 10

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

  # FIXTURE PRECONDITION for every custom-role row below, and it is the whole
  # reason this file had none. `Tenancy.Auth.create_membership/4` validates the
  # role name against `valid_role_names/1` (auth.ex:108-117), which is the
  # built-ins PLUS a `Repo.all` over `Tenancy.Role` scoped to the workspace (or
  # global). So the Role row AND its RolePermission rows must exist BEFORE the
  # membership is created, or the changeset returns
  # `role: {"is invalid", validation: :inclusion, enum: ["owner","admin","member"]}`
  # and a reader concludes custom roles are impossible. Recipe copied from
  # `custom_role/3` in test/barkpark/tenancy_rbac_test.exs — there is no shared
  # fixture for it anywhere.
  defp custom_role(ws_id, name, actions) do
    {:ok, role} = Repo.insert(Role.changeset(%Role{}, %{name: name, workspace_id: ws_id}))

    Enum.each(actions, fn a ->
      {:ok, _} =
        Repo.insert(RolePermission.changeset(%RolePermission{}, %{role_id: role.id, action: a}))
    end)

    role
  end

  defp custom_role_name(ws, actions) do
    name = "w43-cost-role-#{System.unique_integer([:positive])}"
    _role = custom_role(ws.id, name, actions)
    name
  end

  defp custom_user_principal(ws, actions) do
    role = custom_role_name(ws, actions)

    email = "w43-cost-custom-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})

    # "user" passed EXPLICITLY: create_membership/4's 4th arg defaults to
    # "api_token", and a mis-typed row makes the entire user axis vacuously
    # green (no membership ever matches a User principal).
    {:ok, membership} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    assert membership.role == role
    assert membership.principal_type == "user"

    {user, role}
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
      assert queries == @builtin_user_q * @ops
    end

    test "API-TOKEN principal: exactly 1 query per derive (was 2)", %{ws: ws, proj: proj} do
      token = token_principal()
      sock = socket(ws, proj, %{api_token: token})

      assert Caps.derive(sock) == %{read: true, write: true, admin: false}

      queries = meter("API-TOKEN principal — Caps.derive/1", @ops, fn -> Caps.derive(sock) end)

      # 1 membership Repo.one. No grant load at all: grants are bound to a
      # grantee USER, and `active_grants/1` returns [] without querying when the
      # socket carries no `current_user`.
      assert queries == @builtin_token_q * @ops
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

      assert queries == @builtin_event_q * @ops
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

    # ── the same derive, on a CUSTOM role: 2.5x, and nothing said so ──────────

    test "CUSTOM-ROLE user principal: 5 queries per derive — the 2.000 above is BUILT-IN ONLY",
         %{ws: ws, proj: proj} do
      {user, role} = custom_user_principal(ws, ["read", "write"])
      sock = socket(ws, proj, %{current_user: user})

      # Same ANSWER as the built-in `member` row above — this is a cost
      # difference, not an authorization difference.
      assert Caps.derive(sock) == %{read: true, write: true, admin: false}

      queries =
        meter(
          "CUSTOM-ROLE (#{role}) user principal — Caps.derive/1\n" <>
            "  decomposition      : 1 membership Repo.one + 3 db_actions Repo.all" <>
            " + 1 grant Repo.all = 5",
          @ops,
          fn -> Caps.derive(sock) end
        )

      # 1 membership Repo.one (the load pds-w43 collapsed) + THREE `db_actions`
      # `Repo.all`s (`role_permits?/3` for :read, for :write, and for
      # `admin_from` → `account_admin_from` — the resolution pds-w43 did NOT
      # collapse) + 1 unconditional grant `Repo.all`.
      assert queries == @custom_user_q * @ops
    end

    test "EVENT path on a CUSTOM role: 10 queries — a debounced keystroke, not 4",
         %{ws: ws, proj: proj} do
      {user, role} = custom_user_principal(ws, ["read", "write"])
      sock = socket(ws, proj, %{current_user: user})

      event_path = fn ->
        Caps.write_capable?(sock.assigns, Caps.derive(sock))
        Caps.write_capable?(sock.assigns, Caps.derive(sock))
      end

      queries =
        meter(
          "EVENT path, CUSTOM ROLE (#{role}) — Caps.gate/3 + Shared.Paper.write_denied?/1\n" <>
            "  decomposition      : 2 x 5 = 10   (the built-in row above reads 4)",
          @ops,
          event_path
        )

      assert queries == @custom_event_q * @ops
    end
  end

  # ── the decomposition: WHERE the extra three queries come from ──────────────
  #
  # These two rows are what make the 5.0 above an EXPLANATION rather than a bare
  # total: a future regression that moves them localises to the
  # `@builtin_role_actions` short-circuit in `Tenancy.Auth.granted_actions/2`,
  # not to "derive got slower".

  describe "Tenancy.Auth.role_permits?/3 query cost per call" do
    test "BUILT-IN role: 0 queries — the compiled-in map answers before db_actions/2", %{ws: ws} do
      assert Tenancy.Auth.role_permits?("member", ws.id, :read) == true

      queries =
        meter(
          "Tenancy.Auth.role_permits?(\"member\", ws, :read) — BUILT-IN short-circuit",
          @ops,
          fn -> Tenancy.Auth.role_permits?("member", ws.id, :read) end
        )

      assert queries == 0
    end

    test "CUSTOM role: 1 query — db_actions/2's Repo.all, paid THREE times per derive", %{ws: ws} do
      role = custom_role_name(ws, ["read", "write"])

      assert Tenancy.Auth.role_permits?(role, ws.id, :read) == true
      assert Tenancy.Auth.role_permits?(role, ws.id, :admin) == false

      queries =
        meter(
          "Tenancy.Auth.role_permits?(\"#{role}\", ws, :read) — CUSTOM role, db_actions/2",
          @ops,
          fn -> Tenancy.Auth.role_permits?(role, ws.id, :read) end
        )

      # 1 `Repo.all` over role_permissions ⨝ roles. `derive/1` reaches this
      # THREE times per user principal — which is exactly 5.0 - 2.0 = 3.
      assert queries == 1 * @ops
    end
  end

  # ── Caps.admin?/1 — metered for the FIRST time ──────────────────────────────
  #
  # `admin?/1` is the shares / item-share handlers' defense-in-depth re-check,
  # and this instrument never priced it at all. It does NOT reuse `derive/1`'s
  # loaded membership: its user arm calls `Tenancy.Auth.authorize/3`, which
  # loads the row itself.
  #
  # NO api_token row here, deliberately. `admin?/1` on a token socket reads 0
  # today and the sibling slice (arpss-w10-caps-admin-parity-table) is what
  # moves it; asserting it here would red that slice's merge. It is that
  # slice's cost obligation, not this file's.

  describe "Caps.admin?/1 query cost per call" do
    test "BUILT-IN-role user socket: 1 query (membership Repo.one, role free)", %{
      ws: ws,
      proj: proj
    } do
      user = user_principal(ws)
      sock = socket(ws, proj, %{current_user: user})

      assert Caps.admin?(sock) == false

      queries =
        meter("BUILT-IN-role user socket — Caps.admin?/1", @ops, fn -> Caps.admin?(sock) end)

      assert queries == 1 * @ops
    end

    test "CUSTOM-role user socket: 2 queries (membership Repo.one + db_actions Repo.all)", %{
      ws: ws,
      proj: proj
    } do
      {user, role} = custom_user_principal(ws, ["read", "write", "admin"])
      sock = socket(ws, proj, %{current_user: user})

      # A custom role carrying "admin" is legal (RolePermission's @actions is
      # read/write/admin) and answers TRUE — the COST, not the answer, is what
      # differs from the built-in row above.
      assert Caps.admin?(sock) == true

      queries =
        meter("CUSTOM-ROLE (#{role}) user socket — Caps.admin?/1", @ops, fn ->
          Caps.admin?(sock)
        end)

      assert queries == 2 * @ops
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

  # THE PROSE-CATCHES-UP GUARD (arpss-w10-caps-docstring-builtin-only).
  #
  # The defect this closes: `Caps.derive/1`'s @doc read "a USER-principal derive
  # is 2 queries (was 4), an API-TOKEN one is 1 (was 2)" with NO built-in-role
  # qualifier, while this file measured 5 and 10 on a custom role. A docstring
  # is not self-checking, so the correction would rot the same way — this test
  # reads the SHIPPING @doc out of the compiled module and rebuilds the exact
  # sentences from the attributes asserted above.
  #
  # It reds in both directions: put the universal wording back and the
  # BUILT-IN/CUSTOM sentences vanish; change an asserted integer without
  # touching the @doc and the interpolated sentence stops matching.
  test "the @doc for Caps.derive/1 names the numbers this file ASSERTS, built-in AND custom" do
    {:docs_v1, _anno, _lang, _fmt, _mod_doc, _meta, docs} = Code.fetch_docs(Caps)

    doc =
      Enum.find_value(docs, fn
        {{:function, :derive, 1}, _anno, _sig, %{"en" => text}, _meta} -> text
        _other -> nil
      end)

    assert is_binary(doc), "Caps.derive/1 has no @doc — there is nothing to keep honest"

    flat = collapse(doc)

    # (a) the qualifier. Its ABSENCE is the whole defect: without it the cheap
    # rows below read as universal.
    assert flat =~ "BUILT-IN ROLE ONLY",
           "Caps.derive/1's @doc states its query counts without a built-in-role qualifier"

    # (b) the built-in rows, spelled from the integers asserted above.
    assert flat =~
             "a USER-principal derive is #{@builtin_user_q} queries (was 4), " <>
               "an API-TOKEN one is #{@builtin_token_q} (was 2), " <>
               "and the EVENT path #{@builtin_event_q}"

    # (c) the custom-role rows — the half the @doc never mentioned.
    assert flat =~ "On a CUSTOM role the same USER derive costs #{@custom_user_q}"
    assert flat =~ "the EVENT path #{@custom_event_q}, not #{@builtin_event_q}"

    # (d) the REASON, without which the numbers are trivia: the role resolution
    # was never collapsed.
    assert flat =~ "THREE times per user principal"
  end

  defp collapse(text), do: text |> String.split() |> Enum.join(" ")
end
