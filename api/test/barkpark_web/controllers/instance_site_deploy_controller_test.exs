defmodule BarkparkWeb.InstanceSiteDeployControllerTest do
  @moduledoc """
  Contract tests for `GET /v1/instance/site-deploy` (dr-w15-s1).

  The route exists so an instance can answer "can I deploy sites?" WITHOUT
  spending a deploy. Three properties are worth a test each, and they are the
  three ways this instrument could lie:

    * it rides the EXISTING `[:api, :require_token]` seam — 401 without a token,
      200 with one, six keys, no new auth surface;
    * `configured` CANNOT contradict the refusal a real POST would produce —
      proved by mutation, both directions, in the same test;
    * NO field makes a `GenServer.call` — proved by wedging the Runner's
      registered name behind a process that never receives, and showing the
      route still answers, fast, with a queue length that ROSE.

  ## What dr-w22-s2 added, and what it had to admit about the old test

  The `build_slots` assertion below reads
  `body["build_slots"] == DeployRunner.build_slot_capacity()` — and BOTH sides
  are the same compile-time constant, so it is satisfied by identity. It passes
  on a box whose door is saturated, on a box that has refused 1,810 deploys, and
  on a box with no door at all. It could never have noticed that the payload
  reported no measurement. It is kept (the capacity column is still part of the
  contract) and the measurements are asserted separately, by MUTATION, in
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

    raw = "instance-site-deploy-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "instance-site-deploy", "test", ["read"])

    {:ok, _} =
      Auth.create_token(@admin_token, "instance-sd-admin", "test", ["read", "write", "admin"])

    {:ok, token: raw}
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

  describe "auth — the existing Bearer seam, no new surface" do
    test "401 without a token", %{conn: conn} do
      assert conn |> get(@route) |> json_response(401)
    end

    test "401 with a bogus token", %{conn: conn} do
      assert conn |> authed("not-a-real-token") |> get(@route) |> json_response(401)
    end
  end

  describe "the capability record" do
    test "200 with the six-key contract {configured, runner_alive, runner_queue_len, build_slots, door, serving}",
         %{conn: conn, token: token} do
      body = conn |> authed(token) |> get(@route) |> json_response(200)

      assert Enum.sort(Map.keys(body)) ==
               [
                 "build_slots",
                 "configured",
                 "door",
                 "runner_alive",
                 "runner_queue_len",
                 "serving"
               ]

      assert is_boolean(body["configured"])
      # The Runner is in the supervision tree UNCONDITIONALLY, so on a healthy
      # box this is true even with the feature off — the two facts are separate
      # fields precisely so `false` here can only mean CRASHED.
      assert body["runner_alive"] == true
      assert is_integer(body["runner_queue_len"])

      # The CAPACITY column, unchanged in name and value — a released `bp` may
      # read it. Note that both sides of this are the same constant; see the
      # moduledoc.
      assert body["build_slots"] == DeployRunner.build_slot_capacity()
      assert body["build_slots"] >= 1

      # ── the door's census ──
      door = body["door"]

      assert Enum.sort(Map.keys(door)) == [
               "capacity",
               "in_flight_slugs",
               "measured_at",
               "observed_in_flight",
               "refusals_since",
               "refusals_total"
             ]

      assert door["capacity"] == body["build_slots"]
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

    test "runner_alive is false and the queue is null — never a reassuring 0 — when the Runner is gone",
         %{conn: conn, token: token} do
      real = Process.whereis(DeployRunner)
      Process.unregister(DeployRunner)

      on_exit(fn ->
        if is_nil(Process.whereis(DeployRunner)), do: Process.register(real, DeployRunner)
      end)

      body = conn |> authed(token) |> get(@route) |> json_response(200)

      assert body["runner_alive"] == false
      # An absent runner does not have an empty mailbox; it has no mailbox.
      assert is_nil(body["runner_queue_len"])
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

      idle = build_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert idle["door"]["observed_in_flight"] == 0
      assert idle["door"]["in_flight_slugs"] == []
      refusals_before = idle["door"]["refusals_total"]

      assert %{"ok" => true} =
               build_conn()
               |> admin_conn()
               |> post("/v1/admin/site-deploy", %{
                 "slug" => "census-wire",
                 "build_id" => "b1",
                 "mode" => "deploy"
               })
               |> json_response(202)

      busy = build_conn() |> authed(token) |> get(@route) |> json_response(200)

      # THE NUMBER. A constant cannot do this.
      assert busy["door"]["observed_in_flight"] == 1
      assert busy["door"]["in_flight_slugs"] == ["census-wire"]
      assert busy["door"]["capacity"] == busy["build_slots"]

      # A second site is refused at the door while the first builds — and the
      # box now counts what it used to only mention in a log line.
      assert %{"error" => %{"code" => "box_at_capacity"}} =
               build_conn()
               |> admin_conn()
               |> post("/v1/admin/site-deploy", %{
                 "slug" => "census-wire-two",
                 "build_id" => "b2",
                 "mode" => "deploy"
               })
               |> json_response(409)

      refused = build_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert refused["door"]["refusals_total"] == refusals_before + 1
      assert is_binary(refused["door"]["refusals_since"])

      # And it falls back when the build ends — no operator action.
      assert await_in_flight(token, 0) == 0

      # A read that changed nothing did not invent a refusal.
      settled = build_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert settled["door"]["refusals_total"] == refusals_before + 1
    end
  end

  defp await_in_flight(token, target, budget_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + budget_ms
    do_await_in_flight(token, target, deadline)
  end

  defp do_await_in_flight(token, target, deadline) do
    body = build_conn() |> authed(token) |> get(@route) |> json_response(200)
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

      off = build_conn() |> authed(token) |> get(@route) |> json_response(200)
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

      on = build_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert on["configured"] == true

      accepted =
        build_conn()
        |> admin_conn()
        |> post("/v1/admin/site-deploy", %{
          "slug" => "cap-probe-on",
          "build_id" => "b2",
          "mode" => "deploy"
        })

      assert %{"ok" => true} = json_response(accepted, 202)
    end
  end

  # ── MUTATION PROOF: no field makes a GenServer.call ─────────────────────
  #
  # The wedge is produced BY CONSTRUCTION, not by speed: a process that is
  # parked in `receive` for a message that never comes takes over the Runner's
  # registered name. Every caller that reaches for the Runner now piles into
  # that mailbox and is never answered — a D113-shaped wedge, deterministic on
  # any machine at any load. If ANY of the four fields called the Runner, this
  # request could not return.
  describe "a wedged Runner still gets answered" do
    test "200 inside a bounded time, and runner_queue_len RISES with the callers piling up",
         %{token: token} do
      # Short status budget so the piling-up callers give up quickly; their
      # `$gen_call` messages stay in the wedged door's mailbox regardless, which
      # is exactly what the queue length is measuring.
      put_runner_cfg(status_call_timeout_ms: 150)

      real = Process.whereis(DeployRunner)
      assert is_pid(real), "the DeployRunner singleton must be alive to be wedged"

      # Parked forever on a message nobody sends: never processes its mailbox.
      wedged = spawn(fn -> receive do: (:never -> :ok) end)
      Process.unregister(DeployRunner)
      Process.register(wedged, DeployRunner)

      on_exit(fn ->
        if Process.whereis(DeployRunner) == wedged, do: Process.unregister(DeployRunner)
        Process.exit(wedged, :kill)

        if Process.alive?(real) and is_nil(Process.whereis(DeployRunner)),
          do: Process.register(real, DeployRunner)
      end)

      before = build_conn() |> authed(token) |> get(@route) |> json_response(200)
      assert before["runner_alive"] == true
      assert before["runner_queue_len"] == 0

      # Six real callers do what the control plane does — poll status — and are
      # never answered.
      for i <- 1..6 do
        Task.start(fn -> DeployRunner.status("wedge-probe-#{i}") end)
      end

      # Wait for the mailbox to actually hold them (bounded, not a sleep-and-hope).
      assert {:message_queue_len, queued} = await_queue_len(wedged, 6, 2_000)
      assert queued >= 6

      started = System.monotonic_time(:millisecond)
      body = build_conn() |> authed(token) |> get(@route) |> json_response(200)
      elapsed = System.monotonic_time(:millisecond) - started

      # THE PROPERTY: the instrument built to report a wedge is not taken down
      # by one. A single GenServer.call anywhere in `show/2` would blow this.
      assert elapsed < 1_000,
             "the capability read must not wait on the Runner (took #{elapsed}ms)"

      assert body["runner_alive"] == true
      assert body["configured"] == DeployRunner.enabled?()
      assert body["build_slots"] == DeployRunner.build_slot_capacity()

      # And the HIGH-FLIP-RISK field earns its place: it ROSE, from 0, under a
      # wedge, with no help from the process being measured.
      assert body["runner_queue_len"] >= 6
      assert body["runner_queue_len"] > before["runner_queue_len"]
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
