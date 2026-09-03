defmodule BarkparkCloud.TerminalActResidueManifestTest do
  @moduledoc """
  cch-w57-s1 — THE TERMINAL-ACT RESIDUE REGISTER.

  Every terminal verb in this product ends with a sentence — "removed",
  "deprovisioning", "canceled" — and none of those sentences say what is left
  behind. This file is the register that makes each one say it. Its key is

      (verb) -> (what is DESTROYED, what SURVIVES, who is TOLD)

  and every cell is resolved by RUNNING the real thing: the shipped console
  model in a node sandbox, and the real router / registry / store against this
  booted BEAM. Nothing here is resolved by reading a comment.

  ## A SIBLING, NEVER AN EXTENSION

  This is a NEW file beside `promise_actor_manifest_test.exs` and
  `lifecycle_state_manifest_test.exs` (charter D607/D636). The three manifest
  instruments share no extractor and each re-types its own node-spawn recipe on
  purpose: a change to one instrument's reader can then never silently retune
  another instrument's population. The client script this file spawns
  (`__preview__/__terminal_verb_dump.mjs`) is likewise a sibling of
  `__lifecycle_state_dump.mjs`, not a parameterisation of it.

  ## THE POPULATION IS A UNION OF TWO MECHANISMS, AND THEY ARE NOT EQUALLY STRONG

  The set of terminal verbs this register must account for is read two different
  ways, and the asymmetry is stated here in plain words because the strength of
  the guard differs across the halves:

    * (a) THE CONSOLE HALF IS READ BY RUNNING. `__terminal_verb_dump.mjs`
      evaluates the SHIPPED `app.js` inside a node:vm sandbox
      (`document.readyState = "loading"`, so `init()` is merely registered and no
      boot path runs), reads `__bpTestHook.lifecycleVerbs` and CALLS
      `lifecycleActionsModel/4` over a DERIVED cartesian matrix of every value
      its four inputs can hold. There is no regex and no `File.read!` over
      `app.js` anywhere in this file. A verb added to `LIFECYCLE_VERBS` surfaces
      here with zero edits to the probe — which is exactly the mutation proof
      this half is worth. The dump never prints an empty list: every unreadable
      path is a numbered non-zero exit, because an empty array would read on this
      side as "there is no terminal verb to account for".

    * (b) THE SERVER HALF IS READ BY SCANNING. The router's terminal call sites
      are counted out of `router.ex`'s SOURCE TEXT, with `@router_source` pinned
      by `Path.expand/2` and an EXISTENCE assertion before the scan — the recipe
      `test/barkpark_cloud/web/router_ability_matrix_test.exs:40` established and
      `router_head_fence_census_test.exs` / `crash_envelope_census_test.exs` also
      follow. A SCAN IS WEAKER THAN A RUN, and the way it is weaker is specific:
      a scan survives a refactor that keeps the bytes and changes the value. Move
      `Registry.delete_barkpark/1` behind a wrapper, or change what it does, and
      the count here is unmoved and still green. It catches a call site ADDED or
      REMOVED — nothing else. Do not quote this half's green for more than that.

  Both halves are joined only in the sense that the register accounts for the
  union; neither vouches for the other.

  ## WHAT THIS REGISTER DELIBERATELY DOES NOT CLOSE OVER

  It does NOT declare closure over charter D428's seven elevated verbs. Driven on
  this tree, only two of those seven identifiers are reachable on `__bpTestHook`
  (`runDecommission`, `attachDomain`); the other five are unexported IIFE locals
  and read back `undefined`. A register keyed on that list could never report ADD
  or STALE across five of its seven rows, so it would be a guard that cannot lose
  wearing the costume of one.

  `LIFECYCLE_VERBS` is re-used here for a DIFFERENT AXIS than the one charter
  D458 ruled out of scope. D458 is about AUTHORITY — who may press these verbs.
  This file is about RESIDUE — what is left standing after one is pressed.
  Nothing here reopens D458.

  ## THE ADD DIRECTION, AND WHY IT IS THE ONE FROM `lifecycle_state_manifest_test`

  Both population halves lose in BOTH directions through ONE `MapSet.equal?/2`
  that reports ADD and STALE in a SINGLE failure message — the shape at
  `lifecycle_state_manifest_test.exs:536` — carried by two anti-vacuity arms
  (`combos > 0`, and a non-empty actual set). It is deliberately NOT the shape in
  `sold_capability_manifest_test.exs`, whose ADD arm iterates whatever the client
  happens to emit and therefore passes vacuously at zero iterations (charter
  D564; that file's own moduledoc says so at :48-58).

  ## THE WORDING DISCIPLINE: NO ROW MAY OVERCLAIM

  Residue that lives in someone else's system — an object store, a DNS zone, a
  payment processor — is NOT observable from here, and no row pretends otherwise.
  Every foreign-residue cell asserts exactly one thing: OUR TREE MAKES NO SUCH
  CALL. That is a statement about this codebase, which is a thing a test can
  know. "The bundle is deleted" and "the platform's DNS records are swept" are
  not, and this file asserts neither — `deprovisionDNS`
  (internal/cli/cloud/warmpool.go) degrades to a by-NAME delete whenever the
  provider is not a `RecordLister` or `exclusiveIP` is false, and BOTH of those
  arms leave a platform custom host standing. That pin belongs to a sibling
  slice. The last test in this file enforces the discipline mechanically by
  scanning this file's own source for sweep-claiming phrasing.

  ## SCOPE — quote this register's green for exactly this much

    1. The console half reads the four inputs `lifecycleActionsModel/4` takes. A
       new BRANCH inside the model shows up here with no edit; a new INPUT FIELD
       does not.
    2. The server half is a source scan (see above).
    3. The residue rows are driven against Postgres, the router, and the registry
       in THIS BEAM. Anything a real worker does to a real Hetzner box or a real
       DNS zone is outside every one of them.
  """

  # async: false — the archive-store row toggles the GLOBAL `:archive_store_http_client`
  # and `BarkparkCloud.ArchiveStore` app env, so this module must not race a
  # parallel test reading either.
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, ArchiveStore, Billing, Registry, Repo}
  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  # Pinned by Path.expand + an existence assertion before any scan — the recipe
  # from router_ability_matrix_test.exs:40.
  @router_source Path.expand("../../lib/barkpark_cloud/web/router.ex", __DIR__)

  # ── THE POPULATION, HALF (a): the console's terminal verbs ────────────────
  #
  # Pinned HERE and by NEITHER side. That is not style — it is the only reason
  # the STALE direction can lose. A guard that iterated whatever the dump emitted
  # would pass at zero iterations with LIFECYCLE_VERBS gutted.
  @console_verbs MapSet.new(~w(adopt archive audit decommission pause resurrect))

  # ── THE POPULATION, HALF (b): the router's terminal call sites ────────────
  #
  # THREE `Registry.delete_barkpark/1` call sites — the exact count IS the ADD arm
  # — plus the one destructive billing verb, whose residue row is driven below.
  #
  # CITED BY ROUTE, NOT BY LINE. This register used to name the call sites as
  # five bare line numbers in the cloud router — every one of them already stale
  # in this tree. That file is ~13k lines and grows constantly, so ANY insertion
  # above a cited line silently invalidates every number below it, and the commit
  # that raised this count to 6 is itself such an insertion. The route is the
  # handle that survives.
  #
  # The old numbers are deliberately NOT reproduced above, even as history: the
  # lineref sweep reads a `<file>.ex <n>, <n>` shape as a LIVE citation, and a
  # bare `router.ex` stem is ambiguous across this repo (the api router is a
  # different, much shorter file), so quoting them makes the sweep resolve the
  # wrong file and red on a comment that is only describing the past.
  #
  #   DELETE /v1/barkparks/:id ....................... 1 (inline, in Accounts.audit/3)
  #   audited_delete_barkpark/3, the shared helper ... 1
  #   the resurrect enqueue-failure rollback ......... 1
  #
  # SIX -> THREE, deliberately, in the commit that lowered it
  # (task-55fb1f33a217249b). Four call sites did not disappear — they were routed
  # through ONE audited helper, because all four deleted a team's instance row
  # and wrote no audit event: both arms of `DELETE /v1/fleet/supports/:id` and
  # both arms of `POST /v1/internal/barkparks/:id/deprovision`. The two residue
  # rows below still describe the two support ARMS; what changed is that a single
  # call site now serves four of them.
  #
  # WHICH MEANS THIS COUNT NO LONGER EQUALS THE NUMBER OF TERMINAL ARMS, and
  # saying so is the point: it counts CALL SITES, which is all a scan can do. The
  # arm-level population is pinned instead by `audit_vocabulary_census_test.exs`
  # ARM (d), which enumerates every row-destroying unit in `cloud/lib` and holds
  # each of the four lanes by name.
  #
  # THE SIXTH ROW ABOVE USED TO READ "the site domain-status reaper .... 1", AND
  # IT WAS FALSE. No reaper calls `Registry.delete_barkpark/1`; that call site is
  # the resurrect enqueue-failure rollback, twenty lines under a
  # `barkpark.resurrected` stamp. The error outlived the register — it was copied
  # into the filing that commissioned this change — which is what a register
  # naming its population by hand buys you when nothing re-reads the names.
  #
  # RESIDUE ROW for the call site this count GAINED (5 → 6).
  #
  # DELETE /v1/fleet/supports/:id used to delete the row unconditionally — one
  # terminal act, and the defect: a support owns a real box AND an
  # `A <label>.barkpark.cloud` record, so dropping the row stranded both. The
  # route now splits by lifecycle, and only TWO of its four arms are terminal
  # HERE:
  #
  #   * `?mode=detach` — the caller asserts it already tore the box AND its A
  #     record down itself. DESTROYS: the support row and its five cascade
  #     children. SURVIVES: nothing the row pointed at — that is the caller's
  #     assertion, and `bp cloud support remove` sends the mode ONLY on a run
  #     whose own by-value zone sweep actually ran. TOLD: push_event(team, "fleet").
  #   * non-live, nothing in flight — no box and no record exist, so the row IS
  #     the whole resource. DESTROYS: the row + its cascade children.
  #     SURVIVES: nothing. TOLD: push_event(team, "fleet").
  #
  # The other two arms are deliberately NOT terminal acts here, which is the
  # point of the change: a LIVE support hands off to the deprovision worker,
  # which deletes the row only AFTER the zone sweep succeeds — the row is the
  # sole pointer to the record that must die — and an in-flight
  # provision/resurrect is refused 409 rather than stranding a box being built.
  @delete_barkpark_call_sites 3
  @billing_cancel_route {"post", "/v1/billing/cancel"}

  # The five tables whose FK to `barkparks` is ON DELETE CASCADE. The sixth FK
  # edge — `barkparks.fleet_parent_id` — is `:nilify_all` and is this register's
  # built-in negative control (migration
  # 20260723000000_add_fleet_group_to_barkparks.exs:30).
  #
  # SIX -> FIVE (cch-w53-bl env-var Option A, ruled 2026-09-02): `env_vars` was
  # the sixth cascade child until the team env-var feature was deleted and the
  # table dropped (prod held zero rows ever). The seed below and every count
  # helper derive from this list, so the row it used to contribute is gone from
  # all of them at once.
  @cascade_children ~w(agent_events agent_tokens provision_jobs sites usage_samples)

  ## ── Fixtures (copied verbatim from web/router_audit_test.exs) ────────────

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp team_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, team} =
      attrs
      |> Enum.into(%{name: "Team #{n}", slug: "team-#{n}"})
      |> Accounts.create_team()

    team
  end

  defp logged_in do
    user = user_fixture()
    team = team_fixture()
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {:ok, token} = Accounts.create_user_session_token(user)
    {user, team, token}
  end

  defp barkpark_fixture(team, attrs) do
    n = System.unique_integer([:positive])

    {:ok, bp} =
      Registry.register_barkpark(team, Enum.into(attrs, %{name: "BP #{n}", slug: "bp-#{n}"}))

    bp
  end

  defp call(method, path, body, token) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  ## ── The client half: read by RUNNING ────────────────────────────────────

  defp console_dump! do
    node = System.find_executable("node")

    # A guard that cannot run must RED, never skip. `.github/workflows/cloud.yml`
    # installs node with actions/setup-node@v4 rather than betting on the image.
    assert node,
           "node is not on PATH — the terminal-act residue register cannot read the console's verbs"

    script =
      :barkpark_cloud
      |> :code.priv_dir()
      |> Path.join("static/__preview__/__terminal_verb_dump.mjs")

    assert File.exists?(script),
           "the terminal-verb dump script is missing at #{script} — the console's terminal verbs " <>
             "cannot be read by running"

    {out, status} = System.cmd(node, [script], stderr_to_stdout: true)

    assert status == 0,
           "the terminal-verb dump failed (exit #{status}) — what the console offers could not be " <>
             "read by running: #{out}"

    Jason.decode!(out)
  end

  ## ── Child-row seeding: raw SQL ON PURPOSE ───────────────────────────────
  #
  # The register asks what the DATABASE does when a row is deleted, not what a
  # changeset is willing to build. Every child is inserted with raw INSERTs so
  # no context module stands between the question and the answer.
  #
  # GOTCHA, load-bearing: `provision_jobs` is seeded in a TERMINAL status. With a
  # pending/claimed job the DELETE route answers 409 on
  # `Registry.active_provision_job?/1` (registry.ex:1270) and the delete never
  # runs — a green that measured nothing.
  defp seed_children!(%Barkpark{} = bp) do
    q = fn sql, params -> Repo.query!(sql, params) end
    id = fn -> Ecto.UUID.dump!(Ecto.UUID.generate()) end
    bp_id = Ecto.UUID.dump!(bp.id)
    team_id = Ecto.UUID.dump!(bp.team_id)
    now = DateTime.utc_now()

    q.(
      "INSERT INTO agent_events (id, barkpark_id, type, payload, inserted_at) VALUES ($1,$2,$3,$4,$5)",
      [id.(), bp_id, "heartbeat", %{}, now]
    )

    q.(
      "INSERT INTO agent_tokens (id, barkpark_id, token_hash, inserted_at, updated_at) VALUES ($1,$2,$3,$4,$5)",
      [id.(), bp_id, "hash-#{System.unique_integer([:positive])}", now, now]
    )

    q.(
      "INSERT INTO provision_jobs (id, barkpark_id, kind, status, inserted_at, updated_at) VALUES ($1,$2,$3,$4,$5,$6)",
      [id.(), bp_id, "provision", "failed", now, now]
    )

    q.(
      "INSERT INTO sites (id, barkpark_id, team_id, name, slug, inserted_at, updated_at) VALUES ($1,$2,$3,$4,$5,$6,$7)",
      [id.(), bp_id, team_id, "Site", "site-#{System.unique_integer([:positive])}", now, now]
    )

    q.(
      "INSERT INTO usage_samples (id, barkpark_id, envelope, measured_at, inserted_at, updated_at) " <>
        "VALUES ($1,$2,$3,$4,$5,$6)",
      [id.(), bp_id, %{"meters" => %{}}, now, now, now]
    )

    :ok
  end

  # {table => row count for this barkpark}, for all five cascade children.
  defp child_counts(%Barkpark{} = bp) do
    bp_id = Ecto.UUID.dump!(bp.id)

    Map.new(@cascade_children, fn table ->
      %Postgrex.Result{rows: [[n]]} =
        Repo.query!("SELECT count(*) FROM #{table} WHERE barkpark_id = $1", [bp_id])

      {table, n}
    end)
  end

  defp all_ones, do: Map.new(@cascade_children, &{&1, 1})
  defp all_zeroes, do: Map.new(@cascade_children, &{&1, 0})

  ## ── POPULATION (a): the console's terminal verbs ─────────────────────────

  test "POPULATION (console half, read by RUNNING): the terminal verbs are pinned, and the pin loses in BOTH directions" do
    dump = console_dump!()

    # ANTI-VACUITY, arm 1: a matrix that drove nothing cannot vouch for anything.
    assert Map.fetch!(dump, "combos") > 0,
           "the terminal-verb dump drove no inputs at all — a zero-combo matrix is not a reading"

    actual = dump |> Map.fetch!("verbs") |> MapSet.new()

    # ANTI-VACUITY, arm 2: an empty verb set must never read as "nothing to
    # account for". (The dump also exits non-zero on this; belt and braces,
    # because THIS is the assertion that would otherwise pass silently.)
    refute MapSet.size(actual) == 0,
           "the console declared NO terminal verbs — an unreadable population is a red, not a pass"

    added = MapSet.difference(actual, @console_verbs)
    stale = MapSet.difference(@console_verbs, actual)

    assert MapSet.equal?(actual, @console_verbs),
           "the console's terminal verbs drifted from this register.\n" <>
             "  offered but unregistered (ADD):   #{inspect(MapSet.to_list(added))}\n" <>
             "  registered but unoffered (STALE): #{inspect(MapSet.to_list(stale))}\n" <>
             "A new terminal verb needs a residue row here saying what it DESTROYS, what SURVIVES " <>
             "it and who is TOLD; a verb the console no longer offers needs its pin deleted in the " <>
             "same commit, deliberately."

    # The rail may never invent a verb: everything it PAINTS is a verb it
    # DECLARES. (The reverse does not hold — every degraded branch paints
    # `decommission` alone — which is why the population is read from the
    # declaration and the paint is checked against it, not the other way round.)
    painted = dump |> Map.fetch!("painted_verbs") |> MapSet.new()

    assert MapSet.subset?(painted, actual),
           "the rail painted a verb LIFECYCLE_VERBS does not declare: " <>
             "#{inspect(MapSet.difference(painted, actual) |> MapSet.to_list())}"

    assert Map.fetch!(dump, "painted_equals_declared_always"),
           "a WIRED provider painted something other than the declared verb sequence — the rail " <>
             "either invented a verb or silently dropped one"
  end

  ## ── POPULATION (b): the router's terminal call sites ─────────────────────

  test "POPULATION (server half, read by SCANNING): the router's terminal call sites are pinned by an EXACT count" do
    # EXISTENCE FIRST. A scan of a file that isn't there counts zero of
    # everything and reads as green — the exact failure mode this assertion
    # exists to make impossible (router_ability_matrix_test.exs:40, :187-188).
    assert File.exists?(@router_source),
           "the router source is missing at #{@router_source} — a scan that cannot find its file " <>
             "counts zero call sites and would read as 'no terminal act in the router'"

    source = File.read!(@router_source)

    call_sites =
      ~r/Registry\.delete_barkpark\(/
      |> Regex.scan(source)
      |> length()

    assert call_sites == @delete_barkpark_call_sites,
           "the number of Registry.delete_barkpark/1 call sites in router.ex changed: " <>
             "found #{call_sites}, this register accounts for #{@delete_barkpark_call_sites}.\n" <>
             "A new call site is a new terminal act and needs a residue row here; a removed one " <>
             "needs this count lowered in the same commit, deliberately.\n" <>
             "REMEMBER WHAT THIS ARM IS: a SCAN. It catches a call site added or removed. It does " <>
             "NOT catch a refactor that keeps the bytes and changes what they do."

    {verb, path} = @billing_cancel_route

    declared =
      ~r/^\s*(get|post|patch|put|delete)\(?\s*"([^"]+)"/m
      |> Regex.scan(source)
      |> Enum.map(fn [_, v, p] -> {v, p} end)
      |> MapSet.new()

    assert MapSet.member?(declared, @billing_cancel_route),
           "#{verb} #{path} is no longer declared in router.ex — the destructive billing verb this " <>
             "register carries a residue row for has moved or gone"
  end

  # RESIDUE-ROWS-BEGIN — everything between this marker and its closing twin
  # below is the register's rows, and it is the region the wording guard at the
  # bottom of this file scans for sweep-claiming phrasing. The moduledoc sits
  # OUTSIDE that region on purpose:
  # the moduledoc discusses the forbidden sentences in order to forbid them, and
  # a guard that could not tell those two apart would forbid its own explanation.

  ## ── ROW 1: DELETE /v1/barkparks/:id, NON-LIVE arm ────────────────────────

  test "ROW 1 — decommission (non-live): DESTROYS the row and all FIVE cascade children; the audit row SURVIVES" do
    {user, team, token} = logged_in()
    bp = barkpark_fixture(team, %{name: "Doomed"})
    :ok = seed_children!(bp)

    before = child_counts(bp)

    assert before == all_ones(),
           "the seed did not land — every cascade child must be 1 BEFORE the delete or the " <>
             "1 -> 0 reading measures nothing. got: #{inspect(before)}"

    conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)

    assert conn.status == 200, "expected a non-live remove; got #{conn.status} #{conn.resp_body}"
    assert json_body(conn) == %{"ok" => true, "status" => "removed"}

    after_counts = child_counts(bp)

    assert after_counts == all_zeroes(),
           "DESTROYED column drifted. before: #{inspect(before)} after: #{inspect(after_counts)}"

    assert Repo.get(Barkpark, bp.id) == nil, "the barkpark row survived its own decommission"

    # SURVIVES: the audit row, and it is the ONLY thing the team is told.
    assert [ev] = Accounts.list_audit_events(team)
    assert ev.action == "barkpark.deleted"
    assert ev.actor_user_id == user.id
    assert ev.target_id == bp.id
  end

  ## ── ROW 2: the NEGATIVE CONTROL — the sixth FK edge is not a cascade ───

  test "ROW 2 (NEGATIVE CONTROL) — fleet_parent_id is :nilify_all: deleting a fleet MAIN leaves its SUPPORT box standing, orphaned" do
    {_user, team, token} = logged_in()
    main = barkpark_fixture(team, %{name: "Main"})

    support =
      team
      |> barkpark_fixture(%{name: "Support"})
      |> Ecto.Changeset.change(fleet_role: "support", fleet_parent_id: main.id)
      |> Repo.update!()

    assert support.fleet_parent_id == main.id,
           "the support box was not grouped — nothing to orphan"

    conn = call(:delete, "/v1/barkparks/#{main.id}", nil, token)
    assert conn.status == 200

    assert Repo.get(Barkpark, main.id) == nil

    # ONE delete, TWO opposite outcomes: the main vanishes, the support machine
    # SURVIVES — still a row, still billable, no longer grouped to anything.
    # Migration 20260723000000_add_fleet_group_to_barkparks.exs:30 declares
    # `on_delete: :nilify_all`, and this is that declaration, driven.
    assert %Barkpark{} = survivor = Repo.get(Barkpark, support.id)

    assert survivor.fleet_parent_id == nil,
           "the support box kept a parent id pointing at a deleted row — the FK edge is no longer " <>
             ":nilify_all and this register's negative control has changed meaning"

    assert survivor.fleet_role == "support",
           "the orphaned box no longer calls itself a support machine — nothing in the delete path " <>
             "should have touched this column"
  end

  ## ── ROW 3: THE METERING ROW ──────────────────────────────────────────────

  test "ROW 3 — decommission DESTROYS the metering evidence while the subscription SURVIVES to keep charging" do
    {_user, team, token} = logged_in()
    {:ok, sub} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team, %{name: "Metered"})
    :ok = seed_children!(bp)

    assert Map.fetch!(child_counts(bp), "usage_samples") == 1

    conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)
    assert conn.status == 200

    # DESTROYED: every usage sample for this box — the rows `GET /v1/usage/summary`
    # answers from, and the only record in Cloud of what the box consumed.
    assert Map.fetch!(child_counts(bp), "usage_samples") == 0,
           "usage_samples no longer cascade — this row's premise changed"

    # SURVIVES, pointing the OTHER WAY across the same act: the subscription is
    # untouched and still active. Removing the box does not stop the bill, and
    # the evidence behind the bill is what the removal destroyed.
    assert %{status: "active"} = Repo.reload!(sub)
  end

  ## ── ROW 4: THE 202 INTERMEDIATE STATE ────────────────────────────────────

  test "ROW 4 — decommission on a LIVE box answers 202 'deprovisioning' and, at that instant, has destroyed NOTHING" do
    {_user, team, token} = logged_in()
    bp = barkpark_fixture(team, %{name: "Live", host: "10.0.0.1"})
    :ok = seed_children!(bp)

    before = child_counts(bp)
    assert before == all_ones()

    conn = call(:delete, "/v1/barkparks/#{bp.id}", nil, token)

    assert conn.status == 202
    assert json_body(conn) == %{"ok" => true, "status" => "deprovisioning"}

    # DESTROYED: nothing. The row, the host, and all five children are exactly
    # where they were — the ONLY change is one more provision_jobs row, the
    # pending deprovision job.
    after_counts = child_counts(bp)

    assert after_counts == %{before | "provision_jobs" => before["provision_jobs"] + 1},
           "the 202 path changed more than the enqueue. before: #{inspect(before)} " <>
             "after: #{inspect(after_counts)}"

    assert %Barkpark{host: "10.0.0.1"} = Repo.get(Barkpark, bp.id),
           "the row or its host moved on a path whose whole answer is 'later'"

    %Postgrex.Result{rows: [[pending]]} =
      Repo.query!(
        "SELECT count(*) FROM provision_jobs WHERE barkpark_id = $1 AND kind = 'deprovision' AND status = 'pending'",
        [Ecto.UUID.dump!(bp.id)]
      )

    assert pending == 1, "no pending deprovision job was enqueued — the 202 promised a worker"

    # TOLD: nobody. The console says the box is going away; the audit trail says
    # nothing happened, because at this instant nothing has.
    assert Accounts.list_audit_events(team) == []
  end

  ## ── ROW 5: THE LIVE TEARDOWN, END TO END, IN-PROCESS ─────────────────────

  test "ROW 5 — the LIVE teardown DESTROYS the row and all five children, and SAYS SO on the trail" do
    {_user, team, token} = logged_in()
    bp = barkpark_fixture(team, %{name: "Live", host: "10.0.0.1"})
    :ok = seed_children!(bp)

    assert call(:delete, "/v1/barkparks/#{bp.id}", nil, token).status == 202

    # `claim_next_deprovision_job/1` (registry.ex:1340) and
    # `succeed_deprovision_job/2` (:2110) are ordinary public Elixir — the Go
    # worker is a caller, not a prerequisite, so the whole path runs here.
    claim_token = "probe-#{System.unique_integer([:positive])}"

    assert {job, %Barkpark{id: claimed_id}} = Registry.claim_next_deprovision_job(claim_token),
           "no deprovision job was claimable — the 202's promise has no worker seam"

    assert claimed_id == bp.id

    assert {:ok, :deleted} = Registry.succeed_deprovision_job(job.id, claim_token: claim_token)

    assert Repo.get(Barkpark, bp.id) == nil
    assert child_counts(bp) == all_zeroes()

    # TOLD: the team, on the trail, by the transaction that did it (cch-w57).
    #
    # THIS ROW USED TO READ THE OTHER WAY. Wave 57 drove the live path to the
    # deletion and found it wrote no audit event whatsoever — and the tree pinned
    # that silence as EXPECTED in web/router_audit_test.exs. Since the live
    # deprovision is the only path a box that actually RAN can take, the console's
    # append-only audit list showed the removal of every box that never ran and
    # was silent about every box that did. The register said so; this is the
    # register being answered, not edited.
    #
    # `Registry.succeed_deprovision_job/2` now stamps `barkpark.deleted` INSIDE
    # the transaction that deletes the row, so the fact cannot outlive a rolled-
    # back act and the act cannot outrun the fact. The actor is nil because the
    # WORKER performs the deletion; `provision_jobs` carries no actor column, and
    # a guessed actor would be worse than a declared absence.
    events = Accounts.list_audit_events(team)

    # NOT `assert [ev] = ..., "msg"` — a match with a custom message raises
    # MatchError before assert/2 ever runs, and the sentence below would be dead
    # text on the one failure it exists to explain.
    assert length(events) == 1,
           "the live teardown wrote #{length(events)} audit events, not one — it has gone back " <>
             "to being silent about every box that actually ran, or it is now double-stamping"

    [ev] = events

    assert ev.action == "barkpark.deleted"
    assert ev.target_type == "barkpark"
    assert ev.target_id == bp.id
    assert ev.actor_user_id == nil
    assert ev.metadata["via"] == "deprovision"

    # SURVIVES: the trail row, and nothing it points at. ROW 6 drives WHY that is
    # possible (`target_id` is a bare string with no FK).
    assert Repo.get(Barkpark, ev.target_id) == nil
  end

  ## ── ROW 6: THE AUDIT SURVIVOR / POSITIVE CONTROL ─────────────────────────

  test "ROW 6 (POSITIVE CONTROL) — the barkpark.deleted row OUTLIVES its target, and audit_events.target_id has no FK" do
    {user, team, token} = logged_in()
    bp = barkpark_fixture(team, %{name: "Doomed"})

    assert call(:delete, "/v1/barkparks/#{bp.id}", nil, token).status == 200
    assert Repo.get(Barkpark, bp.id) == nil

    # The survivor column can be POSITIVELY observed — `:none` must never be
    # reachable by failing to look.
    assert [ev] = Accounts.list_audit_events(team)
    assert ev.target_type == "barkpark"

    assert ev.target_id == bp.id,
           "the audit row no longer names the row it outlived"

    # And it survives because nothing holds it to a real target: `target_id` is a
    # bare :string with NO foreign key (migration
    # 20260701120600_create_audit_events.exs:33). Driven, not read.
    never_existed = Ecto.UUID.generate()

    assert {:ok, orphan} =
             Accounts.record_audit(%{
               team_id: team.id,
               actor_user_id: user.id,
               action: "barkpark.deleted",
               target_type: "barkpark",
               target_id: never_existed,
               metadata: %{"name" => "Never Was"}
             })

    assert orphan.target_id == never_existed,
           "audit_events.target_id gained a foreign key — the trail can no longer outlive its " <>
             "subject, and ROW 6's premise has changed"
  end

  ## ── ROW 7: THE ARCHIVE BUNDLE — FOREIGN RESIDUE, DONE HONESTLY ───────────

  test "ROW 7 — decommission makes ZERO object-storage requests; the one destructive export is NOT on the teardown path" do
    {_user, team, token} = logged_in()

    base = Application.get_env(:barkpark_cloud, ArchiveStore, [])
    base_client = Application.get_env(:barkpark_cloud, :archive_store_http_client)

    on_exit(fn ->
      Application.put_env(:barkpark_cloud, ArchiveStore, base)

      if base_client,
        do: Application.put_env(:barkpark_cloud, :archive_store_http_client, base_client),
        else: Application.delete_env(:barkpark_cloud, :archive_store_http_client)
    end)

    Application.put_env(:barkpark_cloud, ArchiveStore,
      access_key: "AK-TEST",
      secret_key: "SK-TEST",
      bucket: "bundles",
      location: "fsn1"
    )

    # The fake transport records every request into THIS process's dictionary —
    # the route runs synchronously in the test process, so it sees everything the
    # teardown would dial.
    Process.put(:archive_reqs, [])
    Application.put_env(:barkpark_cloud, :archive_store_http_client, &__MODULE__.fake_request/1)

    bp = barkpark_fixture(team, %{name: "Bundled"})
    :ok = seed_children!(bp)

    assert call(:delete, "/v1/barkparks/#{bp.id}", nil, token).status == 200
    assert Repo.get(Barkpark, bp.id) == nil

    # THE CLAIM, WORDED EXACTLY AS FAR AS IT CAN BE: our tree made no
    # object-storage call while tearing this box down. NOT "the bundle is
    # deleted", NOT "the bundle is retained" — what happens inside Hetzner's
    # object store is not observable from here.
    assert Process.get(:archive_reqs) == [],
           "the teardown dialled object storage: " <> inspect(Process.get(:archive_reqs))

    # ANTI-VACUITY, and it is load-bearing: read the recorder BEFORE the control
    # call. Without this arm the assertion above is trivially true whenever the
    # fake is not installed at all — a recorder that can never record proves
    # nothing about silence.
    assert {:ok, archives} = ArchiveStore.list_archives(team.id)

    assert length(Process.get(:archive_reqs)) > 0,
           "the recorder recorded NOTHING even when list_archives/1 ran — it is not wired, so the " <>
             "zero-requests reading above measured nothing"

    # SURVIVES: the bundle is still listable after the box it belonged to is gone.
    assert Enum.any?(archives, &(&1.slug == "old-box")),
           "the archived bundle is no longer listable after the teardown: #{inspect(archives)}"

    # THE REFLECTION ARM, derived by RUNNING __info__(:functions) — never by
    # grep. The file carries several `def` lines but exports four functions (a
    # second `list_archives` clause and a second `delete_bundle` clause collapse,
    # and the transport lives in the nested HttpClient module), so a grep-based
    # reading of this guard would be wrong about the population it is guarding.
    exports = ArchiveStore.__info__(:functions) |> Enum.sort()

    assert exports == [
             delete_bundle: 2,
             derive_signing_key: 4,
             list_archives: 1,
             sign_v4: 1
           ],
           "BarkparkCloud.ArchiveStore's exports changed: #{inspect(exports)}. Re-derive this row " <>
             "— a new export may be a new way for our tree to reach the bundle."

    # cch-w54-bl RE-DERIVED THIS ARM RATHER THAN DELETING IT. It used to read
    # `destructive == []` — our tree had no object-storage verb that could
    # destroy anything, so the bundle's survival needed no further explanation.
    # It has exactly one now, `delete_bundle/2`. What ROW 7 still measures is
    # UNCHANGED and is the whole point: the destructive verb is NOT on this
    # path. The teardown above ran to completion with the recorder armed and
    # dialled the store zero times, so the bundle outlives the DELETE route and
    # is erased later, on a schedule, by a caller this test does not run.
    # (`ArchiveRetentionWorker` is run for real — with its window and its
    # live-team carve-out driven in both directions — in
    # `workers/archive_retention_worker_test.exs`. That proof stays there: this
    # file may not claim a sweep it does not execute.)
    destructive =
      Enum.filter(exports, fn {name, _arity} ->
        Atom.to_string(name) =~ ~r/delete|purge|remove/
      end)

    assert destructive == [delete_bundle: 2],
           "the destructive-export population changed: #{inspect(destructive)}. Every entry here " <>
             "is a way our tree can reach into the bundle store, and each one must be shown to be " <>
             "off the teardown path before this row's zero-requests reading means anything."

    # And the reachability claim is asserted the only way it can be: the DELETE
    # route above made no request AT ALL, so it reached no signed verb, and the
    # anti-vacuity arm above proves the recorder could have caught one.
    assert Process.get(:archive_reqs) |> Enum.all?(fn r -> r.method != :delete end),
           "the teardown issued an object-storage DELETE — the erasure moved onto the synchronous " <>
             "path and this row's premise is gone"
  end

  # The injected transport, modelled on archive_store_test.exs:461-541. Public so
  # it can be captured into the application env by name. A ListObjectsV2 answers
  # one archived bundle for every team; a manifest GET answers its manifest.
  def fake_request(req) do
    Process.put(:archive_reqs, (Process.get(:archive_reqs) || []) ++ [req])

    %URI{query: query, path: path} = URI.parse(req.url)
    params = URI.decode_query(query || "")
    prefix = params["prefix"] || ""

    cond do
      params["list-type"] == "2" ->
        key = "#{prefix}old-box/manifest.json"

        body =
          ~s(<?xml version="1.0"?><ListBucketResult><Name>bundles</Name><IsTruncated>false</IsTruncated>) <>
            "<Contents><Key>#{key}</Key><Size>80</Size><LastModified>2026-07-01T00:00:01.000Z</LastModified></Contents>" <>
            "</ListBucketResult>"

        {:ok, %{status: 200, body: body, headers: []}}

      String.ends_with?(path, "/manifest.json") ->
        body =
          Jason.encode!(%{
            fqdn: "old-box.barkpark.cloud",
            slug: "old-box",
            source_provider: "hetzner",
            created_at: "2026-07-01T00:00:01Z",
            spec: %{region: "fsn1", server_type: "cax11"}
          })

        {:ok, %{status: 200, body: body, headers: []}}

      true ->
        {:ok, %{status: 404, body: "", headers: []}}
    end
  end

  ## ── ROW 8: the OTHER destructive verb, for contrast ──────────────────────

  test "ROW 8 — an immediate billing cancel DESTROYS the entitlement and leaves EVERY box and child standing" do
    {_user, team, token} = logged_in()
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    bp = barkpark_fixture(team, %{name: "Kept", host: "10.0.0.2"})
    :ok = seed_children!(bp)

    conn = call(:post, "/v1/billing/cancel", %{password: @password, at_period_end: false}, token)
    assert conn.status == 200

    # DESTROYED: nothing that is a row. The subscription's status changed, which
    # is the whole act.
    assert json_body(conn)["status"] == "canceled"

    # SURVIVES: the box, its host, and all five children. A verb the console calls
    # a cancellation leaves every billable artefact exactly where it was; the
    # only thing that moved is a flag.
    assert %Barkpark{host: "10.0.0.2"} = survivor = Repo.get(Barkpark, bp.id)
    assert child_counts(bp) == all_ones()

    assert survivor.suspended,
           "an immediate cancel no longer suspends the team's boxes — this row's SURVIVES cell " <>
             "must be re-derived"

    # TOLD: the audit trail, exactly once.
    assert [ev] =
             team
             |> Accounts.list_audit_events()
             |> Enum.filter(&(&1.action == "subscription.canceled"))

    assert ev.target_type == "subscription"
  end

  # RESIDUE-ROWS-END

  ## ── THE WORDING GUARD: no row may overclaim ──────────────────────────────

  test "NO ROW OVERCLAIMS: no residue row asserts a sweep this tree cannot observe" do
    whole = File.read!(Path.expand(__ENV__.file))

    # The scanned region is the ROWS, bracketed by two sentinels. Both must be
    # present and in order, or the scan is reading nothing and must RED.
    opened = String.split(whole, "RESIDUE-ROWS-" <> "BEGIN", parts: 2)

    assert length(opened) == 2,
           "the opening sentinel is missing — the wording guard has nothing to scan"

    closed = String.split(List.last(opened), "RESIDUE-ROWS-" <> "END", parts: 2)

    assert length(closed) == 2,
           "the closing sentinel is missing — the wording guard would scan the rest of the file, " <>
             "including its own forbidden-pattern list"

    source = List.first(closed)

    assert String.contains?(source, "assert "),
           "the scanned rows region contains no assertions — the sentinels have drifted and this " <>
             "guard is reading an empty string"

    # Foreign residue — an object store, a DNS zone, a payment processor — is not
    # observable from this BEAM. The only honest claim class is "OUR TREE MAKES NO
    # SUCH CALL", and these are the phrasings that would quietly exceed it.
    #
    # `deprovisionDNS` (internal/cli/cloud/warmpool.go) degrades to a by-NAME
    # delete when the provider is not a RecordLister OR exclusiveIP is false, and
    # BOTH arms leave a platform custom host standing — so a DNS sweep is exactly
    # the sentence this tree cannot support.
    overclaims = [
      ~r/\bdns\s+(records?\s+)?(are|is)\s+swept\b/i,
      ~r/\bsweeps?\s+(the\s+)?(platform\s+)?dns\b/i,
      ~r/\bplatform\s+hosts?\s+(are|is)\s+swept\b/i,
      ~r/\bthe\s+bundle\s+is\s+deleted\b/i,
      ~r/\bbundles?\s+(are|is)\s+(deleted|purged|removed)\b/i,
      ~r/\bstripe\s+(is|was)\s+told\b/i
    ]

    hits = Enum.filter(overclaims, &Regex.match?(&1, source))

    assert hits == [],
           "a residue row in this file claims a sweep this tree cannot observe: " <>
             "#{inspect(Enum.map(hits, &Regex.source/1))}\n" <>
             "Foreign residue may be asserted ONLY as 'our tree makes no such call'. If a real " <>
             "sweep is genuinely wired now, prove it by RUNNING the sweep, not by rewording this " <>
             "file."

    # And the guard must be able to lose: the forbidden phrasings are real
    # patterns, not a list that matches nothing by construction.
    assert Enum.any?(
             overclaims,
             &Regex.match?(&1, "the platform DNS records are swept on teardown")
           ),
           "the overclaim patterns match nothing at all — this wording guard cannot lose"
  end
end
