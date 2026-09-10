defmodule BarkparkWeb.InstanceSiteDeployControllerTest do
  @moduledoc """
  Contract tests for `GET /v1/instance/site-deploy` (dr-w15-s1).

  The route exists so an instance can answer "can I deploy sites?" WITHOUT
  spending a deploy. Two properties are worth a test each, and they are the two
  ways this instrument could lie:

    * it rides the `[:api, :require_admin]` seam (task-d7ac954aa57aa522) — 401
      without a token, 403 with a plain `["read"]` token, 200 with an admin
      one, four keys. It rode `[:api, :require_token]` until then, and the
      three assertions in "auth — the operator tier" are what would catch a
      revert: `door.in_flight_slugs` names other tenants' site slugs, and
      `:require_token` admits any read token from any workspace;
    * `configured` CANNOT contradict the refusal a real POST would produce —
      proved by mutation, both directions, in the same test.

  ## What dr-w26-s7 removed, and what that cost

  `build_slots` and `runner_queue_len` were deleted from the payload because
  neither ever had a reader anywhere outside this file. Their assertions went
  with them, and two of those were worth naming:

    * `body["build_slots"] == DeployRunner.build_slot_capacity()` compared a
      compile-time constant to itself and was satisfied by identity — it passed
      on a saturated box, on a box that had refused 1,810 deploys, and on a box
      with no door at all. Its useful half survives, RE-ANCHORED: the wire's
      `door.capacity` is now checked against `DeployRunner.build_slot_capacity/0`
      directly, which is a real cross-check between the census and the module
      attribute the door admits on. The measurements themselves are asserted by
      MUTATION in `test/barkpark/sites/deploy_runner_door_census_test.exs`.
    * the wedged-Runner test (a working behavioural positive control: park a pid
      in `receive`, pile six real callers into its mailbox, assert the field rose
      0 -> >=6) was DELETED OUTRIGHT rather than trimmed. Trimming it to its
      surviving property, `elapsed < 1_000`, would have left a green that passes
      identically against a perfectly healthy runner — a control that cannot
      fail is worse than no control, because it reads as coverage.

  ## RE-PINNED (dr-w27-s7): "a wedged Runner still gets answered"

  The no-`GenServer.call` property is NO LONGER UNPINNED. The control at the
  bottom of this file restores it WITHOUT the deleted field: the wedge is proven
  where it lives — `Process.info(wedged, :message_queue_len) >= 6`, read off the
  parked pid itself — and only then is the route's bounded-time 200 asserted.
  The precondition is an assertion that CAN fail, so the timing assertion is no
  longer vacuous, and no payload field observes the wedge (the controller's
  "Honest limit" still holds: nothing on the wire sees one).

  Its `on_exit` releases the singleton UNCONDITIONALLY — name restored, box
  drained to idle — which is the defect the original carried: a red mid-wedge
  leaked the registered name across files and could cascade into
  `test/barkpark/sites/deploy_runner_door_census_test.exs`.
  """
  # async: false — borrows the DeployRunner singleton's registered name and
  # mutates Application env.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Sites.{DeployRunner, Provisioner}

  @route "/v1/instance/site-deploy"
  @admin_token "barkpark-test-instance-site-deploy-admin"

  # The payload now carries `serving`, which reads (and, on a first sighting,
  # writes) a durable record under the Runner's run-state dir. Point that at a
  # tmp dir for the whole module so the suite never touches the checkout's real
  # one.
  setup do
    run_state = Path.join(System.tmp_dir!(), "bp-isd-runs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(run_state)
    put_runner_cfg(run_state_dir: run_state)
    on_exit(fn -> File.rm_rf(run_state) end)

    # A PLAIN read token — deliberately not `public-read`, which `PublicRead`
    # would clamp on the old pipeline for an unrelated reason and so could not
    # tell `:require_token` from `:require_admin`. This is the exact principal
    # the tier gap admitted, and after task-d7ac954aa57aa522 it gets a 403.
    read_raw = "instance-site-deploy-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(read_raw, "instance-site-deploy", "test", ["read"])

    {:ok, _} =
      Auth.create_token(@admin_token, "instance-sd-admin", "test", ["read", "write", "admin"])

    # `token:` is the ADMIN token: every payload assertion below reads the route
    # as the principal that is now allowed to. `read_token:` is the negative
    # control, used only in "auth — the operator tier".
    {:ok, token: @admin_token, read_token: read_raw}
  end

  defp authed(conn, token) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json")
  end

  defp admin_conn(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin_token)

  defp put_runner_cfg(overrides) do
    prior = Application.get_env(:barkpark, DeployRunner)
    Application.put_env(:barkpark, DeployRunner, Keyword.merge(prior || [], overrides))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, DeployRunner, prior),
        else: Application.delete_env(:barkpark, DeployRunner)
    end)
  end

  # A real, provisionable site root + a stub build command, so the enabled half
  # of the mutation proof reaches a genuine 202 instead of failing for an
  # unrelated reason.
  defp provisionable_box do
    base = Path.join(System.tmp_dir!(), "bp-instance-sd-#{System.unique_integer([:positive])}")
    template = Path.join(base, "template")
    File.mkdir_p!(template)
    File.write!(Path.join(template, "package.json"), ~s({"name":"instance-stub"}))

    prior = Application.get_env(:barkpark, Provisioner)

    Application.put_env(:barkpark, Provisioner,
      sites_dir: Path.join(base, "sites"),
      template_dir: template
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Provisioner, prior),
        else: Application.delete_env(:barkpark, Provisioner)

      File.rm_rf(base)
    end)
  end

  describe "auth — the operator tier" do
    test "401 without a token", %{conn: conn} do
      assert conn |> get(@route) |> json_response(401)
    end

    test "401 with a bogus token", %{conn: conn} do
      assert conn |> authed("not-a-real-token") |> get(@route) |> json_response(401)
    end

    # THE REGRESSION GUARD (task-d7ac954aa57aa522). This route returned 200 to
    # this exact conn on `[:api, :require_token]`, handing a plain read token
    # from any workspace `door.in_flight_slugs` — the list of every site slug
    # building on the box. Revert the router hunk and this test reds with
    # `expected response with status 403, got: 200`.
    test "403 for a plain read token — in_flight_slugs names other tenants' sites",
         %{conn: conn, read_token: read_token} do
      assert %{"error" => %{"code" => "forbidden"}} =
               conn |> authed(read_token) |> get(@route) |> json_response(403)
    end

    # POSITIVE CONTROL. Without this, the test above is satisfiable by a route
    # that 403s everyone — including the on-box agent this route exists for.
    test "200 for an admin token, with in_flight_slugs present", %{conn: conn} do
      body = conn |> authed(@admin_token) |> get(@route) |> json_response(200)

      assert is_list(body["door"]["in_flight_slugs"])
    end
  end

  describe "the capability record" do
    test "200 with the four-key contract {configured, runner_alive, door, serving} — and NOT the two deleted keys",
         %{conn: conn, token: token} do
      body = conn |> authed(token) |> get(@route) |> json_response(200)

      assert Enum.sort(Map.keys(body)) ==
               [
                 "configured",
                 "door",
                 "runner_alive",
                 "serving"
               ]

      # Set EQUALITY above, not a subset — so this line is what would catch a
      # reintroduction of either deleted key. Stated separately because the
      # deletion is the point of dr-w26-s7 and a reader should not have to infer
      # it from a sorted list.
      refute Map.has_key?(body, "build_slots")
      refute Map.has_key?(body, "runner_queue_len")

      assert is_boolean(body["configured"])
      # The Runner is in the supervision tree UNCONDITIONALLY, so on a healthy
      # box this is true even with the feature off — the two facts are separate
      # fields precisely so `false` here can only mean CRASHED.
      assert body["runner_alive"] == true

      # ── the door's census ──
      door = body["door"]

      assert Enum.sort(Map.keys(door)) == [
               "capacity",
               "door_open_admissions",
               "door_open_admissions_total",
               "in_flight_slugs",
               "measured_at",
               "observed_in_flight",
               "refusals_since",
               "refusals_total"
             ]

      # The door's OTHER half: builds it let through without a second opinion
      # (no /proc/locks, an unreadable one, a lock it could not stat). It has
      # always failed open in those cases; until dr-w12 it did so silently, so
      # the leak the refusal count hides had no number at all. Counted by
      # reason, so the dev-box case never hides the operator case.
      assert is_integer(door["door_open_admissions_total"])
      assert is_map(door["door_open_admissions"])

      # RE-ANCHORED (dr-w26-s7). This used to read `== body["build_slots"]`,
      # which compared the wire to a wire field the wire itself produced from
      # the same constant. Against `build_slot_capacity/0` it is a real
      # cross-check: the ETS census the door admits on vs. the module attribute
      # it admits BY. `build_slot_capacity/0` survives the deletion — the door
      # needs it — and note `grep build_slots` does not match it.
      assert door["capacity"] == DeployRunner.build_slot_capacity()
      assert door["capacity"] >= 1
      assert is_integer(door["observed_in_flight"])
      assert is_list(door["in_flight_slugs"])
      assert is_integer(door["refusals_total"])

      # The count NEVER travels without its window: the counter's lifetime is
      # the Runner's, so a total with no `refusals_since` beside it would let a
      # reader mistake a fresh process for a quiet door.
      assert is_binary(door["refusals_since"])
      assert {:ok, _, _} = DateTime.from_iso8601(door["refusals_since"])
      assert is_binary(door["measured_at"])

      # ── the serving clock ──
      serving = body["serving"]
      assert Enum.sort(Map.keys(serving)) == ["serving_sha", "serving_since"]

      # In the test checkout `git rev-parse HEAD` resolves, so both are present;
      # the both-null path is asserted directly in the census test.
      assert is_nil(serving["serving_sha"]) == is_nil(serving["serving_since"])
    end

    # THE VACUOUS SURVIVOR (dr-w26-s7). This test used to end with
    # `assert is_nil(body["runner_queue_len"])` — the "never a reassuring 0"
    # guard. It PASSED UNCHANGED after the key was deleted from the payload
    # outright (measured: 1 test, 0 failures), because a nil-guard cannot
    # distinguish "measured, and the answer is absent" from "the instrument is
    # gone". It was DELETED rather than repaired: the only honest repair —
    # `refute Map.has_key?(body, "runner_queue_len")` — is a key-set assertion
    # about a field that no longer exists, and the four-key set equality above
    # already carries it. What remains here is the half that still measures
    # something: an unregistered Runner reports `runner_alive: false`.
    test "runner_alive is false when the Runner is gone", %{conn: conn, token: token} do
      real = Process.whereis(DeployRunner)
      Process.unregister(DeployRunner)

      on_exit(fn ->
        if is_nil(Process.whereis(DeployRunner)), do: Process.register(real, DeployRunner)
      end)

      body = conn |> authed(token) |> get(@route) |> json_response(200)

      assert body["runner_alive"] == false
    end
  end

  # ── MUTATION PROOF: the RENDERED payload moves with the box ─────────────
  #
  # The old `build_slots` assertion is satisfied by identity and would pass on a
  # saturated box. This one cannot: it drives a real build through the real
  # route and reads the numbers back off the wire, then refuses a second deploy
  # at the door and reads them again.
  describe "the door census, end to end on the wire" do
    test "observed_in_flight goes 0 → 1 → 0 and refusals_total RISES across a real refusal",
         %{token: token} do
      provisionable_box()

      put_runner_cfg(
        enabled: true,
        command: {"bash", ["-c", "sleep 0.8; echo done; exit 0"]}
      )

      # The line below reads a VM-GLOBAL gauge COLD. Guard the precondition
      # first — see `await_idle_box/2` for why, and for why it is not the
      # `await_in_flight/3` the fall-back assertion at the end of this test uses.
      assert await_idle_box() == 0

      idle = scoped_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert idle["door"]["observed_in_flight"] == 0
      assert idle["door"]["in_flight_slugs"] == []
      refusals_before = idle["door"]["refusals_total"]

      assert %{"ok" => true} =
               scoped_conn()
               |> admin_conn()
               |> post("/v1/admin/site-deploy", %{
                 "slug" => "census-wire",
                 "build_id" => "b1",
                 "mode" => "deploy"
               })
               |> json_response(202)

      busy = scoped_conn() |> authed(token) |> get(@route) |> json_response(200)

      # THE NUMBER. A constant cannot do this.
      assert busy["door"]["observed_in_flight"] == 1
      assert busy["door"]["in_flight_slugs"] == ["census-wire"]
      # RE-ANCHORED with the same reasoning as the contract test above: the
      # capacity the box reports WHILE BUSY is still the module attribute, so a
      # door that quietly widened under load would be caught here.
      assert busy["door"]["capacity"] == DeployRunner.build_slot_capacity()

      # A second site is refused at the door while the first builds — and the
      # box now counts what it used to only mention in a log line.
      assert %{"error" => %{"code" => "box_at_capacity"}} =
               scoped_conn()
               |> admin_conn()
               |> post("/v1/admin/site-deploy", %{
                 "slug" => "census-wire-two",
                 "build_id" => "b2",
                 "mode" => "deploy"
               })
               |> json_response(409)

      refused = scoped_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert refused["door"]["refusals_total"] == refusals_before + 1
      assert is_binary(refused["door"]["refusals_since"])

      # And it falls back when the build ends — no operator action.
      assert await_in_flight(token, 0) == 0

      # A read that changed nothing did not invent a refusal.
      settled = scoped_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert settled["door"]["refusals_total"] == refusals_before + 1
    end
  end

  # ── PRECONDITION, not an assertion about the box's own bookkeeping ───────
  #
  # `door.observed_in_flight` is served from `:barkpark_site_deploy_door_census`, a
  # `:named_table, :public` ETS table owned by the DeployRunner SINGLETON. It is
  # VM-global, sits outside the Ecto sandbox, and is never reset between tests
  # or between files — and CI runs bare `mix test` with no `--seed`, so ExUnit
  # reshuffles every run. Anything that left a build in flight lands in the next
  # test's cold read.
  #
  # Two known leakers, both real:
  #
  #   * this file's `configured …` test ends on a 202 (now awaited, below);
  #   * `deploy_runner_door_vs_unit_review_test.exs` drives the SYSTEMD path,
  #     whose engines are detached — the Runner never receives a port-exit for
  #     them, so nothing republishes the census and a stale reading sits there
  #     until the next `:census_tick`, which is `@default_census_interval_ms`
  #     = 10s.
  #
  # Observed, twice, with output: `mix test <that file> <this file> --seed 7`
  # reds here with `left: 1, right: 0`; so does a narrowed run pairing that
  # file's `CONTROL:` test with this one (5 of 6).
  #
  # But the repro is LOAD-DEPENDENT, and this comment will not pretend
  # otherwise. On a quiet box the same narrowed run went 0 for 8, and a probe
  # reading the gauge immediately after each of that file's three tests found
  # `observed_in_flight=0` every time. The likely reason the leak comes and
  # goes: that file's `is_active` stub is a script under a tmp dir its
  # `on_exit` deletes, and `building_slugs/1` SHELLS OUT to it — so whether a
  # later `publish_census/1` still sees the unit as active depends on whether
  # it runs before or after that delete. Stated as the open question it is,
  # not as a finding.
  #
  # So the reason this guard exists is the MECHANISM above — a VM-global gauge
  # the route reads without recomputing — not any one command. A cold `== 0`
  # against a cache nothing is obliged to refresh is unsound whether or not
  # today's box happens to expose it.
  #
  # `refresh_door_census/0` is a synchronous recompute inside the Runner
  # (`publish_census/1` off `building_slugs/1`), so this waits for the box to
  # BE idle instead of waiting out a tick it cannot influence.
  #
  # It cannot manufacture a green. It returns whatever the Runner observed, so
  # a box that never goes idle still fails the `== 0` at the call site with the
  # real number. And it is deliberately NOT `await_in_flight/3`: that helper's
  # other caller is the "falls back when the build ends — no operator action"
  # assertion, and forcing a refresh there would mask precisely the defect that
  # assertion exists to catch.
  defp await_idle_box(budget_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_await_idle_box(deadline)
  end

  defp do_await_idle_box(deadline) do
    observed = DeployRunner.refresh_door_census().observed_in_flight

    cond do
      observed == 0 -> observed
      System.monotonic_time(:millisecond) >= deadline -> observed
      true -> Process.sleep(50) && do_await_idle_box(deadline)
    end
  end

  defp await_in_flight(token, target, budget_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_await_in_flight(token, target, deadline)
  end

  defp do_await_in_flight(token, target, deadline) do
    body = scoped_conn() |> authed(token) |> get(@route) |> json_response(200)
    observed = body["door"]["observed_in_flight"]

    cond do
      observed == target -> observed
      System.monotonic_time(:millisecond) >= deadline -> observed
      true -> Process.sleep(50) && do_await_in_flight(token, target, deadline)
    end
  end

  # ── MUTATION PROOF: `configured` cannot contradict the refusal ──────────
  #
  # The field's whole justification is that it is LITERALLY the expression
  # `SiteDeployController.trigger/2` branches on to emit `feature_not_configured`
  # (`DeployRunner.enabled?/0`). That is only worth believing if both directions
  # are observed against the REAL POST, in the same test, on the same box.
  describe "configured vs. the refusal it predicts" do
    test "off: the route says configured=false AND the POST refuses feature_not_configured; flipping it flips BOTH",
         %{conn: conn, token: token} do
      provisionable_box()
      put_runner_cfg(enabled: false)

      off = scoped_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert off["configured"] == false

      assert %{"error" => %{"code" => "feature_not_configured"}} =
               conn
               |> admin_conn()
               |> post("/v1/admin/site-deploy", %{
                 "slug" => "cap-probe",
                 "build_id" => "b1",
                 "mode" => "deploy"
               })
               |> json_response(503)

      # ── flip ──
      put_runner_cfg(
        enabled: true,
        command: {"bash", ["-c", "echo 'BPSTAGE name=PLAN status=ok build_id=b1'\nexit 0"]}
      )

      on = scoped_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert on["configured"] == true

      accepted =
        scoped_conn()
        |> admin_conn()
        |> post("/v1/admin/site-deploy", %{
          "slug" => "cap-probe-on",
          "build_id" => "b2",
          "mode" => "deploy"
        })

      assert %{"ok" => true} = json_response(accepted, 202)

      # This test returned on a 202 and used to STOP here, leaving `cap-probe-on`
      # in flight in the singleton Runner's VM-global census — which the next
      # test to read `observed_in_flight` cold inherits (see `await_idle_box/2`).
      # Nothing above is relaxed by draining it: the 202 is still the assertion,
      # this is the test cleaning up after itself.
      assert await_idle_box() == 0
    end
  end

  # ── RESTORED (dr-w27-s7): the wedged-Runner positive control ────────────
  #
  # dr-w26-s7 deleted the original whole. It observed wedge-ness ONLY through
  # `runner_queue_len`, the payload field that PR removed for never having
  # acquired a reader; trimming it to its surviving property, `elapsed < bound`,
  # would have left a green that passes identically against a perfectly healthy
  # runner — a control that cannot fail, which reads as coverage it does not
  # provide.
  #
  # This restoration needs no payload field at all. The wedge is proven where it
  # actually exists — in the wedged process's OWN mailbox, read with
  # `Process.info/2` — by an assertion that CAN fail (the six callers can fail to
  # arrive; the name takeover can fail to take). Only once the wedge is a
  # measured fact does the timing assertion mean anything, and then it means
  # exactly what it says: `show/2` did not wait on the Runner.
  describe "a wedged Runner still gets answered" do
    test "the wedge is proven on the wedged pid's own mailbox, and the route still answers 200 inside the bound",
         %{token: token} do
      # Short status budget so the piling-up callers give up quickly; their
      # `$gen_call` messages stay in the wedged process's mailbox regardless,
      # which is what the precondition below measures.
      put_runner_cfg(status_call_timeout_ms: 150)

      real = Process.whereis(DeployRunner)
      assert is_pid(real), "the DeployRunner singleton must be alive to be wedged"

      # Parked forever on a message nobody sends: never processes its mailbox.
      wedged = spawn(fn -> receive do: (:never -> :ok) end)

      # UNCONDITIONAL RELEASE (dr-w27-s7). Registered BEFORE the takeover and
      # written so that no assertion below can skip it: whatever this test
      # asserted, failed, or raised, the singleton's registered name points back
      # at the REAL runner and the box is drained to zero in-flight builds before
      # the next test — and the next FILE — reads it. The original control
      # aborted mid-wedge on failure and leaked the singleton across files, which
      # is why one red here could cascade into
      # `test/barkpark/sites/deploy_runner_door_census_test.exs`, whose every
      # `refresh_door_census/1` and `await_in_flight/1` goes through this exact
      # registered name.
      on_exit(fn ->
        if Process.whereis(DeployRunner) == wedged, do: Process.unregister(DeployRunner)
        Process.exit(wedged, :kill)

        if is_nil(Process.whereis(DeployRunner)) and Process.alive?(real),
          do: Process.register(real, DeployRunner)

        # The build slot itself: released through the RESTORED runner, so a red
        # above cannot hand the next file a box that reads busy forever.
        await_idle_box()
      end)

      Process.unregister(DeployRunner)
      Process.register(wedged, DeployRunner)

      # Six real callers do what the control plane does — poll status — and are
      # never answered.
      for i <- 1..6 do
        Task.start(fn -> DeployRunner.status("wedge-probe-#{i}") end)
      end

      # THE PRECONDITION, AND IT CAN FAIL. Read off the wedged pid directly, not
      # off the wire: no payload field reports this any more, and that is the
      # point. If the takeover did not take, or the callers never arrived, this
      # reds and the timing assertion below is never reached on a box that was
      # not actually wedged.
      assert {:message_queue_len, queued} = await_queue_len(wedged, 6, 5_000)

      assert queued >= 6,
             "the wedge was never established: the parked pid holds #{queued} " <>
               "unanswered messages, expected at least the 6 status callers"

      started = System.monotonic_time(:millisecond)
      body = scoped_conn() |> authed(token) |> get(@route) |> json_response(200)
      elapsed = System.monotonic_time(:millisecond) - started

      # THE PROPERTY: the capability read is not taken down by the wedge it
      # exists to be readable during. A single `GenServer.call` to the Runner
      # anywhere in `show/2` blows this.
      #
      # THE BOUND, AND ITS MARGIN. `show/2` is a `whereis` + an ETS read + one
      # small file read: single-digit milliseconds, so 1_000 is ~100x the honest
      # cost and cannot red on a loaded CI box. A `GenServer.call` introduced
      # into `show/2` cannot come back at all under this wedge — it either sits
      # for its timeout (5_000ms by default, 5x the bound) or exits into a 500,
      # so the mutation cannot squeeze under 1_000 by being fast. Measured by
      # mutation, not assumed: see the task's evidence.
      assert elapsed < 1_000,
             "the capability read must not wait on the Runner (took #{elapsed}ms)"

      # And the wedge is genuinely invisible to the payload, which is exactly the
      # "Honest limit" the controller moduledoc states: a parked process is as
      # alive as a healthy one to `Process.whereis/1`.
      assert body["runner_alive"] == true
      assert body["configured"] == DeployRunner.enabled?()
      assert body["door"]["capacity"] == DeployRunner.build_slot_capacity()
    end
  end

  defp await_queue_len(pid, at_least, budget_ms) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_await_queue_len(pid, at_least, deadline)
  end

  defp do_await_queue_len(pid, at_least, deadline) do
    info = Process.info(pid, :message_queue_len)

    cond do
      match?({:message_queue_len, n} when n >= at_least, info) -> info
      System.monotonic_time(:millisecond) >= deadline -> info
      true -> Process.sleep(10) && do_await_queue_len(pid, at_least, deadline)
    end
  end
end
