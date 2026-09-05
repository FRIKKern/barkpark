defmodule Barkpark.Sites.DeployRunnerTest do
  @moduledoc """
  Unit tests for `Barkpark.Sites.DeployRunner` — the site-deploy remote-exec
  executor (site-spawner charter D22/D23/D24).

  Stub commands only, never the real `deploy/site-deploy.sh`. The four things
  that MUST hold, each of which is a live-deploy bug if it does not:

    * the single-flight slot is PER SLUG (not global like SelfUpdate.Runner's,
      which a box's own post-merge self-update would occupy);
    * the child's env PRESERVES PATH (asdf's npm) and REMOVES BARKPARK_KEK /
      BARKPARK_CLOAK_KEY — proven by a stub that dumps its OWN env, because an
      allow-list-shaped `env: [...]` reads like a scrub and leaks;
    * the six BPSTAGE stages survive a 900-line log flood (the log ring evicts
      the oldest — the stages must not live in it);
    * a typed exit code carries the REAL reason line out of the child's stream.
  """
  # async: false — mutates the singleton Runner + Application/OS env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Sites.DeployRequest
  alias Barkpark.Sites.DeployRunner
  alias Barkpark.Sites.Provisioner

  # Every `deploy` now provisions FIRST (charter D33/D34) — so point the
  # Provisioner at a TMP sites dir + a TMP stand-in template for the whole
  # module, or every deploy trigger would try (and fail) to write
  # /opt/barkpark/sites. A `rollback` never provisions, so those tests are
  # unaffected by this.
  setup do
    base = Path.join(System.tmp_dir!(), "bp-dr-prov-#{System.unique_integer([:positive])}")
    sites = Path.join(base, "sites")
    template = Path.join(base, "template")
    File.mkdir_p!(template)
    File.write!(Path.join(template, "package.json"), ~s({"name":"stub"}))

    # A node stand-in template too (charter D63) so a runtime_target=node deploy
    # provisions successfully before its port opens — otherwise a node dispatch
    # test would die at provision, never reaching command_for.
    node_template = Path.join(base, "node-template")
    File.mkdir_p!(node_template)
    File.write!(Path.join(node_template, "package.json"), ~s({"name":"node-stub"}))

    prior = Application.get_env(:barkpark, Provisioner)

    Application.put_env(:barkpark, Provisioner,
      sites_dir: sites,
      template_dir: template,
      node_template_dir: node_template
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Provisioner, prior),
        else: Application.delete_env(:barkpark, Provisioner)

      File.rm_rf(base)
    end)

    {:ok, sites: sites, template: template}
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp put_cfg(overrides) do
    prior = Application.get_env(:barkpark, DeployRunner)
    Application.put_env(:barkpark, DeployRunner, Keyword.merge(prior || [], overrides))

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, DeployRunner, prior),
        else: Application.delete_env(:barkpark, DeployRunner)
    end)
  end

  defp put_self_update_cfg(overrides) do
    prior = Application.get_env(:barkpark, Barkpark.SelfUpdate.Runner)

    Application.put_env(
      :barkpark,
      Barkpark.SelfUpdate.Runner,
      Keyword.merge(prior || [], overrides)
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Barkpark.SelfUpdate.Runner, prior),
        else: Application.delete_env(:barkpark, Barkpark.SelfUpdate.Runner)
    end)
  end

  # A stub `bash -c` command standing in for deploy/site-deploy.sh.
  defp stub(script), do: {"bash", ["-c", script]}

  defp req(slug, opts \\ []) do
    params =
      %{
        "slug" => slug,
        "build_id" => Keyword.get(opts, :build_id, "b1"),
        "mode" => Keyword.get(opts, :mode, "deploy")
      }
      |> maybe_put("content_rev", Keyword.get(opts, :content_rev))
      |> maybe_put("runtime_target", Keyword.get(opts, :runtime_target))
      |> maybe_put("env", Keyword.get(opts, :env))
      |> maybe_put("artifact_b64", Keyword.get(opts, :artifact_b64))
      |> maybe_put("artifact_sha256", Keyword.get(opts, :artifact_sha256))

    {:ok, request} = DeployRequest.new(params)
    request
  end

  # A minimal but REAL prebuilt bundle: a one-file `dist/` as a .tar.gz, plus
  # the digest of the exact bytes. `:erl_tar` is fine for WRITING one (the ban
  # is on handing an untrusted gzip stream to it for READING).
  defp prebuilt_artifact(files \\ [{"index.html", "<h1>prebuilt</h1>"}]) do
    tar = Path.join(System.tmp_dir!(), "bp-pb-#{System.unique_integer([:positive])}.tar.gz")
    on_exit(fn -> File.rm(tar) end)

    entries = for {name, data} <- files, do: {String.to_charlist(name), data}
    :ok = :erl_tar.create(String.to_charlist(tar), entries, [:compressed])

    raw = File.read!(tar)
    {Base.encode64(raw), :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp await_done(slug, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 15_000

    case DeployRunner.status(slug) do
      %{state: :done} = status ->
        status

      status ->
        if System.monotonic_time(:millisecond) >= deadline do
          status
        else
          Process.sleep(25)
          await_done(slug, deadline)
        end
    end
  end

  # `env` output → a map. Only well-formed NAME=VALUE lines (a multi-line value
  # would spill, and none of the vars we assert on has one).
  defp parse_env_dump(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/\A([A-Za-z_][A-Za-z0-9_]*)=(.*)\z/s, line) do
        [_all, key, value] -> [{key, value}]
        _no_match -> []
      end
    end)
    |> Map.new()
  end

  # ── fail-closed ─────────────────────────────────────────────────────────

  describe "enabled?/0 (fail-closed)" do
    test "config.exs default is OFF — a trigger can execute nothing" do
      refute DeployRunner.enabled?()
      assert DeployRunner.trigger(req("off-by-default")) == {:error, :disabled}
    end
  end

  # ── per-slug single-flight (charter D23) ────────────────────────────────

  describe "single-flight is PER SLUG" do
    test "the same slug twice while in flight is :already_running" do
      put_cfg(enabled: true, command: stub("sleep 0.6; exit 0"))

      assert DeployRunner.trigger(req("same-slug")) == {:ok, :started}
      assert DeployRunner.trigger(req("same-slug", build_id: "b2")) == {:error, :already_running}

      assert %{state: :done, exit_code: 0} = await_done("same-slug")
    end

    test "a different slug is refused by the BOX's build slot, not by this slug's — and its own slot stays free" do
      # The per-slug slot is still per-slug: `site-bravo` has NOT started, so
      # its own single-flight slot is untouched (`:idle`, not `:running`). What
      # refuses it is the box-wide build slot the ENGINE serializes on, and the
      # refusal is its own typed code — never `already_running`, which would
      # send an operator hunting for a run of a site that never started.
      put_cfg(enabled: true, command: stub("sleep 0.4; exit 0"))

      assert DeployRunner.trigger(req("site-alpha")) == {:ok, :started}
      assert DeployRunner.trigger(req("site-bravo")) == {:error, :box_at_capacity}

      assert %{state: :running} = DeployRunner.status("site-alpha")
      assert %{state: :idle} = DeployRunner.status("site-bravo")

      assert %{state: :done, exit_code: 0} = await_done("site-alpha")

      # The build ended, so the box's slot is free again — no operator action,
      # no lock to clear.
      assert DeployRunner.trigger(req("site-bravo")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("site-bravo")
    end

    test "a self-update in flight does NOT block a site deploy" do
      # This is exactly the live failure this runner exists to avoid: guerrilla
      # auto-deploys on every merge, so SelfUpdate.Runner's GLOBAL slot is
      # routinely busy for reasons that have nothing to do with a site.
      put_self_update_cfg(enabled: true, command: stub("sleep 0.5; exit 0"))
      put_cfg(enabled: true, command: stub("exit 0"))

      assert Barkpark.SelfUpdate.Runner.trigger() == {:ok, :started}
      assert Barkpark.SelfUpdate.Runner.running?()

      assert DeployRunner.trigger(req("unblocked-site")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("unblocked-site")

      # Leave the self-update singleton at rest for the next test.
      await_self_update_idle()
    end

    test "a finished run's slot is released — the same slug can deploy again" do
      put_cfg(enabled: true, command: stub("exit 0"))

      assert DeployRunner.trigger(req("redeployable", build_id: "b1")) == {:ok, :started}
      assert %{state: :done} = await_done("redeployable")

      assert DeployRunner.trigger(req("redeployable", build_id: "b2")) == {:ok, :started}
      assert %{state: :done, build_id: "b2"} = await_done("redeployable")
    end
  end

  defp await_self_update_idle(attempts \\ 100) do
    case Barkpark.SelfUpdate.Runner.status() do
      %{state: :running} when attempts > 0 ->
        Process.sleep(25)
        await_self_update_idle(attempts - 1)

      _ ->
        :ok
    end
  end

  # ── the box's build-slot door (deploy-reliability wave 4) ───────────────
  #
  # The engine runs ONE build at a time box-wide (`BUILD_GATE_SLOTS=1`). Before
  # this door existed the box answered 202 and the SECOND build discovered the
  # gate from inside its own unit, where it sat parked in `flock -w 900`
  # burning its 30-minute deadline — a queue an operator reads as a hang.

  describe "the box's build-slot door" do
    test "two triggers RACING from separate processes: exactly one is admitted" do
      # The census lives in the same serialized GenServer critical section as
      # start_run, so there is no window in which both callers see a free slot.
      put_cfg(enabled: true, command: stub("sleep 0.4; exit 0"))

      replies =
        ["race-one", "race-two"]
        |> Enum.map(fn slug -> Task.async(fn -> DeployRunner.trigger(req(slug)) end) end)
        |> Task.await_many(10_000)

      assert Enum.count(replies, &(&1 == {:ok, :started})) == 1
      assert Enum.count(replies, &(&1 == {:error, :box_at_capacity})) == 1

      admitted = Enum.find(~w(race-one race-two), &(DeployRunner.status(&1).state == :running))
      assert admitted
      assert %{state: :done, exit_code: 0} = await_done(admitted)
    end

    test "a deploy refused at the door never unpacks the caller's artifact (D86/D87)" do
      # The check sits BEFORE start_run/2, whose first act is ingest_prebuilt/1.
      # A refusal that had already extracted a tarball to disk would have made
      # the box pay for the deploy it declined.
      dir = run_dir()
      {b64, sha} = prebuilt_artifact()

      put_cfg(enabled: true, run_state_dir: dir, command: stub("sleep 0.4; exit 0"))

      assert DeployRunner.trigger(req("door-holder")) == {:ok, :started}

      assert DeployRunner.trigger(req("door-prebuilt", artifact_b64: b64, artifact_sha256: sha)) ==
               {:error, :box_at_capacity}

      refute File.exists?(Path.join(dir, "door-prebuilt.prebuilt"))
      assert %{state: :idle} = DeployRunner.status("door-prebuilt")

      assert %{state: :done, exit_code: 0} = await_done("door-holder")
    end

    test "a rollback and a teardown are NEVER refused — they take no build slot" do
      put_cfg(
        enabled: true,
        command: stub("sleep 0.5; exit 0"),
        rollback_command: stub("echo ROLLED; exit 0"),
        teardown_command: stub("echo TORN_DOWN=1; exit 0")
      )

      assert DeployRunner.trigger(req("door-busy")) == {:ok, :started}

      assert DeployRunner.trigger(req("door-rb", mode: "rollback")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("door-rb")

      assert DeployRunner.trigger(req("door-td", mode: "teardown")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("door-td")

      assert %{state: :done, exit_code: 0} = await_done("door-busy")
    end

    test "the SECOND OPINION refuses a FOREIGN holder — matched on MAJ:MIN:INO, never on a PID" do
      # The census's blind spot is a build this BEAM did not launch (a human
      # running site-deploy.sh by hand, or a unit that outlived a restart).
      # /proc/locks covers it with a READ — the pid below does not exist, and
      # the door must not care: one live probe named a pid `ps` could not find,
      # because the lock's fd had been inherited by a child.
      lock = tmp_lock_file()
      {:ok, triple} = DeployRunner.lock_triple(lock)
      assert triple =~ ~r/\A[0-9a-f]{2,}:[0-9a-f]{2,}:\d+\z/

      locks =
        fake_proc_locks("""
        1: POSIX  ADVISORY  WRITE 1 00:14:9999 0 EOF
        2: FLOCK  ADVISORY  WRITE 999999999 #{triple} 0 EOF
        """)

      put_cfg(
        enabled: true,
        command: stub("exit 0"),
        build_gate_lock: lock,
        proc_locks_path: locks
      )

      assert DeployRunner.trigger(req("foreign-held")) == {:error, :box_at_capacity}
      assert %{state: :idle} = DeployRunner.status("foreign-held")
    end

    test "an entry for another file, or a POSIX lock on ours, does NOT refuse" do
      lock = tmp_lock_file()
      {:ok, triple} = DeployRunner.lock_triple(lock)

      locks =
        fake_proc_locks("""
        1: POSIX  ADVISORY  WRITE 4020570 #{triple} 0 EOF
        2: FLOCK  ADVISORY  WRITE 4020571 00:99:424242 0 EOF
        """)

      put_cfg(
        enabled: true,
        command: stub("exit 0"),
        build_gate_lock: lock,
        proc_locks_path: locks
      )

      assert DeployRunner.trigger(req("not-our-lock")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("not-our-lock")
    end

    test "the door FAILS OPEN — an unreadable lock read ADMITS, with a warning, and never refuses" do
      # build_gate_acquire itself fails open in three cases (no flock(1), an
      # undeletable lock dir, an unopenable lock file) and writes nothing to
      # /proc/locks in any of them — so the door can never be the barrier. When
      # the door cannot see, the build goes through and the engine's own 900s
      # flock decides.
      unreadable =
        Path.join(System.tmp_dir!(), "bp-dr-locks-dir-#{System.unique_integer([:positive])}")

      File.mkdir_p!(unreadable)
      on_exit(fn -> File.rm_rf(unreadable) end)

      put_cfg(
        enabled: true,
        command: stub("exit 0"),
        build_gate_lock: tmp_lock_file(),
        # A DIRECTORY where /proc/locks should be: File.read/1 fails :eisdir.
        proc_locks_path: unreadable
      )

      log =
        capture_log(fn ->
          assert DeployRunner.trigger(req("door-fail-open")) == {:ok, :started}
          assert %{state: :done, exit_code: 0} = await_done("door-fail-open")
        end)

      assert log =~ "ADMITTING"

      # And the same when the path is simply absent (no procfs at all).
      put_cfg(proc_locks_path: Path.join(unreadable, "nope/locks"))
      assert DeployRunner.trigger(req("door-no-procfs")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("door-no-procfs")
    end

    test "the lock path mirrors site-deploy-common.sh: env override, /var/lock, ${TMPDIR:-/tmp} — never /run/lock" do
      prior_lock = System.get_env("BARKPARK_BUILD_GATE_LOCK")
      prior_tmp = System.get_env("TMPDIR")

      on_exit(fn ->
        restore_env("BARKPARK_BUILD_GATE_LOCK", prior_lock)
        restore_env("TMPDIR", prior_tmp)
      end)

      put_cfg(enabled: true, build_gate_lock: nil)
      System.delete_env("BARKPARK_BUILD_GATE_LOCK")
      System.put_env("TMPDIR", "/tmpish")

      candidates = DeployRunner.build_gate_lock_candidates()

      assert candidates == [
               "/var/lock/barkpark-site-build.lock",
               "/tmpish/barkpark-site-build.lock"
             ]

      refute Enum.any?(candidates, &String.starts_with?(&1, "/run/lock"))

      # $BARKPARK_BUILD_GATE_LOCK wins, and the tmp fallback is STILL read —
      # the engine picks it when the lock dir cannot be created, and a door
      # that read only one path would miss exactly that box.
      System.put_env("BARKPARK_BUILD_GATE_LOCK", "/custom/build.lock")

      assert DeployRunner.build_gate_lock_candidates() == [
               "/custom/build.lock",
               "/tmpish/barkpark-site-build.lock"
             ]
    end

    test "the probe NEVER shells out to flock — a read cannot steal the box's slot" do
      # `flock -n` was measured and refused: on a FREE lock it ACQUIRES (and
      # flock wakeups are unordered, so it can take the slot from a unit
      # already queued in `flock -w 900`), and it leaks fd 7 by inheritance —
      # a live build showed three holders of it (bash, npm, tee). This is the
      # tripwire for that decision.
      source = File.read!("lib/barkpark/sites/deploy_runner.ex")

      refute source =~ ~s("flock")
      refute source =~ "flock -n 7"
    end

    test "a 409 renders code EXACTLY box_at_capacity and a NON-EMPTY message" do
      # The control plane renders a box refusal as "<code> — <message>" and
      # classifies on the head of that split. A code with an EMPTY message
      # collides with the request-id the relay appends, and the deferral lands
      # unclassified — so both halves are the contract.
      put_cfg(enabled: true, command: stub("sleep 0.4; exit 0"))

      assert DeployRunner.trigger(req("door-409-holder")) == {:ok, :started}

      conn =
        BarkparkWeb.SiteDeployController.trigger(
          Phoenix.ConnTest.build_conn(),
          %{"slug" => "door-409-other", "build_id" => "b1", "mode" => "deploy"}
        )

      assert conn.status == 409
      assert %{"error" => %{"code" => code, "message" => message}} = Jason.decode!(conn.resp_body)
      assert code == "box_at_capacity"
      assert is_binary(message) and String.trim(message) != ""
      assert message =~ "1 of 1"

      assert %{state: :done, exit_code: 0} = await_done("door-409-holder")
    end

    test "the 409 NAMES the peer slug holding the build slot" do
      # THE LOSS THIS CLOSES. The door computed `building_slugs(state)` and
      # interpolated it into a log line on the box; the refusal that crossed the
      # wire said "another site is building" and nothing else. 42% of the
      # fleet's sampled deployments are this refusal, and not one of them could
      # say WHO. `holder: "peer"` is the other half: ordinary contention, a
      # retry works, no operator needed.
      put_cfg(enabled: true, command: stub("sleep 0.4; exit 0"))

      assert DeployRunner.trigger(req("named-holder-alpha")) == {:ok, :started}

      conn =
        BarkparkWeb.SiteDeployController.trigger(
          Phoenix.ConnTest.build_conn(),
          %{"slug" => "named-holder-beta", "build_id" => "b1", "mode" => "deploy"}
        )

      assert conn.status == 409
      assert %{"error" => error} = Jason.decode!(conn.resp_body)

      # The code and the capacity clause are BYTE-STABLE — the control plane's
      # deferral taxonomy matches the literal code, and the CLI keys its exit
      # code on it. The holder rides in ADDED FIELDS and the message TAIL.
      assert error["code"] == "box_at_capacity"

      assert error["message"] =~
               "the box is at its build capacity (1 of 1 build slots in use) — "

      assert error["holder"] == "peer"
      assert error["holding_slugs"] == ["named-holder-alpha"]
      assert error["build_slots_in_use"] == 1
      assert error["build_slot_capacity"] == 1
      assert error["message"] =~ "named-holder-alpha"
      refute Map.has_key?(error, "holder_lock")

      assert %{state: :done, exit_code: 0} = await_done("named-holder-alpha")
    end

    test "the 409 distinguishes a FOREIGN holder from a peer build" do
      # A foreign holder is a build this instance did not launch — a hand-run
      # engine, or a unit that outlived a previous BEAM. It is OPERATOR-
      # ACTIONABLE and a retry may never clear it, where a peer build clears
      # itself in minutes. Both used to answer with the same bare code.
      lock = tmp_lock_file()
      {:ok, triple} = DeployRunner.lock_triple(lock)

      locks =
        fake_proc_locks("""
        1: FLOCK  ADVISORY  WRITE 999999999 #{triple} 0 EOF
        """)

      put_cfg(
        enabled: true,
        command: stub("exit 0"),
        build_gate_lock: lock,
        proc_locks_path: locks
      )

      conn =
        BarkparkWeb.SiteDeployController.trigger(
          Phoenix.ConnTest.build_conn(),
          %{"slug" => "foreign-409", "build_id" => "b1", "mode" => "deploy"}
        )

      assert conn.status == 409
      assert %{"error" => error} = Jason.decode!(conn.resp_body)

      assert error["code"] == "box_at_capacity"

      assert error["message"] =~
               "the box is at its build capacity (1 of 1 build slots in use) — "

      assert error["holder"] == "foreign"
      assert error["holding_slugs"] == []
      assert error["holder_lock"] == lock
      assert error["message"] =~ "did not launch"
      assert error["message"] =~ "operator"

      # And it is NOT the peer wording — the two refusals are now separable by
      # a reader that has only the payload.
      refute error["message"] =~ "retry when it finishes"

      assert %{state: :idle} = DeployRunner.status("foreign-409")
    end

    test "a door-open ADMISSION is counted, by reason — the fail-open leak is measurable" do
      # The door fails OPEN on purpose in named cases, and until now it did so
      # SILENTLY: each one is a build the door SHOULD have refused (or at least
      # could not vouch for) with no counter and no ledger row. This is the
      # counter, and the fixture below actually PRODUCES two admissions — an
      # unreadable /proc/locks and an absent one — not an assertion at zero.
      unreadable =
        Path.join(System.tmp_dir!(), "bp-dr-open-#{System.unique_integer([:positive])}")

      File.mkdir_p!(unreadable)
      on_exit(fn -> File.rm_rf(unreadable) end)

      put_cfg(
        enabled: true,
        command: stub("exit 0"),
        build_gate_lock: tmp_lock_file(),
        # A DIRECTORY where /proc/locks should be: File.read/1 fails :eisdir.
        proc_locks_path: unreadable
      )

      before = DeployRunner.door_census()
      assert is_integer(before.door_open_admissions_total)
      assert is_map(before.door_open_admissions)

      base_unreadable = Map.get(before.door_open_admissions, "proc_locks_unreadable", 0)
      base_absent = Map.get(before.door_open_admissions, "no_proc_locks", 0)

      capture_log(fn ->
        assert DeployRunner.trigger(req("door-open-counted")) == {:ok, :started}
        assert %{state: :done, exit_code: 0} = await_done("door-open-counted")
      end)

      # No procfs at all — the other named fail-open case, counted apart so the
      # dev-box reason never hides the operator one.
      put_cfg(proc_locks_path: Path.join(unreadable, "nope/locks"))
      assert DeployRunner.trigger(req("door-open-counted-2")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("door-open-counted-2")

      after_census = DeployRunner.door_census()

      assert after_census.door_open_admissions_total == before.door_open_admissions_total + 2
      assert after_census.door_open_admissions["proc_locks_unreadable"] == base_unreadable + 1
      assert after_census.door_open_admissions["no_proc_locks"] == base_absent + 1
    end

    test "a REFUSAL is not a door-open admission — the two counters never move together" do
      # The non-vacuity guard on the counter above: a door that counted every
      # trigger would pass that test while measuring nothing. /proc/locks is
      # READABLE here, so the refusal path takes no fail-open branch.
      lock = tmp_lock_file()
      locks = fake_proc_locks("1: POSIX  ADVISORY  WRITE 4020570 00:99:424242 0 EOF\n")

      put_cfg(
        enabled: true,
        command: stub("sleep 0.4; exit 0"),
        build_gate_lock: lock,
        proc_locks_path: locks
      )

      assert DeployRunner.trigger(req("open-vs-refuse-alpha")) == {:ok, :started}

      before = DeployRunner.door_census()
      assert DeployRunner.trigger(req("open-vs-refuse-beta")) == {:error, :box_at_capacity}
      after_census = DeployRunner.door_census()

      assert after_census.refusals_total == before.refusals_total + 1
      assert after_census.door_open_admissions_total == before.door_open_admissions_total

      assert %{state: :done, exit_code: 0} = await_done("open-vs-refuse-alpha")
    end
  end

  # A world-readable stand-in for the box's fleet build lock.
  defp tmp_lock_file do
    path = Path.join(System.tmp_dir!(), "bp-dr-gate-#{System.unique_integer([:positive])}.lock")
    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)
    path
  end

  # A file in the exact shape the kernel prints /proc/locks in.
  defp fake_proc_locks(body) do
    path = Path.join(System.tmp_dir!(), "bp-dr-locks-#{System.unique_integer([:positive])}")
    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  # ── the child's environment (charter D24) ───────────────────────────────

  describe "child environment" do
    test "PATH is preserved; BARKPARK_KEK/BARKPARK_CLOAK_KEY are REMOVED; ambient build vars cannot shadow" do
      dump = Path.join(System.tmp_dir!(), "bp-site-env-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dump) end)

      # The box's real condition: master keys AND stale build vars in the BEAM's
      # own environment. `npm ci` runs third-party postinstall code, so an
      # inherited env is a key leak; an inherited BARKPARK_TOKEN/DATASET would
      # silently build the site against the WRONG content (site-deploy.sh reads
      # them ambiently via ${!v}).
      System.put_env("BARKPARK_KEK", "kek-master-secret")
      System.put_env("BARKPARK_CLOAK_KEY", "cloak-master-secret")
      System.put_env("BARKPARK_TOKEN", "ambient-token-must-not-leak")
      System.put_env("BARKPARK_DATASET", "ambient-dataset-must-not-leak")

      on_exit(fn ->
        System.delete_env("BARKPARK_KEK")
        System.delete_env("BARKPARK_CLOAK_KEY")
        System.delete_env("BARKPARK_TOKEN")
        System.delete_env("BARKPARK_DATASET")
      end)

      put_cfg(enabled: true, command: stub("env > #{dump}; exit 0"))

      request =
        req("envprobe",
          build_id: "bid-42",
          content_rev: "rev-7",
          env: %{
            "BARKPARK_API_URL" => "http://127.0.0.1:4000",
            "BARKPARK_TOKEN" => "per-site-token"
          }
        )

      assert DeployRunner.trigger(request) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("envprobe")

      child = dump |> File.read!() |> parse_env_dump()

      # PATH survives — this is where asdf's npm shims live. Removing it (or
      # rebuilding the env from scratch) is how you get a phantom "npm: command
      # not found" on a box that has npm.
      assert Map.has_key?(child, "PATH")
      assert child["PATH"] != ""

      # The scrub. `{~c"NAME", false}` is the ONLY thing that removes a var —
      # an allow-list-shaped `env:` would leave both of these in the child.
      refute Map.has_key?(child, "BARKPARK_KEK")
      refute Map.has_key?(child, "BARKPARK_CLOAK_KEY")

      # Request wins over ambient…
      assert child["BARKPARK_TOKEN"] == "per-site-token"
      assert child["BARKPARK_API_URL"] == "http://127.0.0.1:4000"
      # …and an ambient build var the request did NOT supply is REMOVED, not
      # inherited — no silent shadowing of the per-site content binding.
      refute Map.has_key?(child, "BARKPARK_DATASET")

      # The engine reads slug/build/rev from the environment (site-deploy.sh).
      assert child["SITE_SLUG"] == "envprobe"
      assert child["BUILD_ID"] == "bid-42"
      assert child["CONTENT_REV"] == "rev-7"
    end

    test "a rollback carries no BUILD_ID (the engine reads .previous)" do
      dump = Path.join(System.tmp_dir!(), "bp-site-env-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(dump) end)

      put_cfg(enabled: true, rollback_command: stub("env > #{dump}; exit 0"))

      assert DeployRunner.trigger(req("rb-env", mode: "rollback")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("rb-env")

      child = dump |> File.read!() |> parse_env_dump()

      assert child["SITE_SLUG"] == "rb-env"
      refute Map.has_key?(child, "BUILD_ID")
    end
  end

  # ── prebuilt artifacts (charter D86/D87 — the build leaves the box) ──────

  describe "a prebuilt artifact" do
    test "reaches the Port child as PREBUILT_DIR + PREBUILT_SHA256, and the dir HOLDS the bytes" do
      dir = run_dir()
      dump = Path.join(dir, "env.dump")
      {b64, sha} = prebuilt_artifact()

      put_cfg(enabled: true, run_state_dir: dir, command: stub("env > #{dump}; exit 0"))

      request = req("pb-port", artifact_b64: b64, artifact_sha256: sha)
      assert DeployRunner.trigger(request) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("pb-port")

      child = dump |> File.read!() |> parse_env_dump()

      assert child["PREBUILT_SHA256"] == sha
      assert child["PREBUILT_DIR"] == Path.join(dir, "pb-port.prebuilt")

      # Not just an env var pointing at nothing: the staged tree is really there.
      assert File.read!(Path.join(child["PREBUILT_DIR"], "index.html")) =~ "prebuilt"
    end

    test "reaches the systemd EnvironmentFile too — THE LANDMINE (an interactive-only plumb silently rebuilds under systemd)" do
      dir = run_dir()
      argv_dump = Path.join(dir, "argv.dump")
      {b64, sha} = prebuilt_artifact()

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {fake_systemd_run(argv_dump), []},
        is_active_cmd: {active_only_for("pb-unit"), []},
        command: stub("exit 0")
      )

      request = req("pb-unit", artifact_b64: b64, artifact_sha256: sha)
      assert DeployRunner.trigger(request) == {:ok, :started}

      # Keyed on the BUILD, not the slug (deploy-reliability D21).
      env_contents = File.read!(Path.join(dir, "pb-unit-b1.env"))
      assert env_contents =~ "PREBUILT_DIR=#{Path.join(dir, "pb-unit.prebuilt")}"
      assert env_contents =~ "PREBUILT_SHA256=#{sha}"

      # …and the manifest survives the JSON round-trip, so a re-attach after a
      # BEAM restart still knows this run was prebuilt.
      manifest = dir |> Path.join("pb-unit.manifest.json") |> File.read!() |> Jason.decode!()
      assert manifest["prebuilt_dir"] == Path.join(dir, "pb-unit.prebuilt")
      assert manifest["prebuilt_sha256"] == sha
    end

    test "a BOX BUILD carries NEITHER var, on either sink" do
      dir = run_dir()
      dump = Path.join(dir, "env.dump")

      put_cfg(enabled: true, run_state_dir: dir, command: stub("env > #{dump}; exit 0"))

      assert DeployRunner.trigger(req("pb-none")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("pb-none")

      child = dump |> File.read!() |> parse_env_dump()
      refute Map.has_key?(child, "PREBUILT_DIR")
      refute Map.has_key?(child, "PREBUILT_SHA256")
    end

    test "a REFUSED artifact starts NOTHING and never degrades to a box build" do
      dir = run_dir()
      ran = Path.join(dir, "engine.ran")
      {_ok_b64, _ok_sha} = prebuilt_artifact()

      # A symlink entry: refused, not sanitized (a staged symlink is SERVED).
      tar = Path.join(System.tmp_dir!(), "bp-evil-#{System.unique_integer([:positive])}.tar.gz")
      on_exit(fn -> File.rm(tar) end)
      link = Path.join(System.tmp_dir!(), "bp-evil-link-#{System.unique_integer([:positive])}")
      File.ln_s!("/etc/passwd", link)
      on_exit(fn -> File.rm(link) end)

      :ok =
        :erl_tar.create(
          String.to_charlist(tar),
          [{~c"leak.txt", String.to_charlist(link)}],
          [:compressed, :dereference_disabled]
        )

      raw = File.read!(tar)
      b64 = Base.encode64(raw)
      sha = :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)

      put_cfg(enabled: true, run_state_dir: dir, command: stub("touch #{ran}; exit 0"))

      request = req("pb-evil", artifact_b64: b64, artifact_sha256: sha)

      assert {:error, {:artifact_rejected, "E_SYMLINK", message}} =
               DeployRunner.trigger(request)

      assert message =~ "symlink"

      # Nothing ran, nothing staged, and the slug is still idle — a refusal is
      # not a slot-holder either.
      refute File.exists?(ran)
      refute File.exists?(Path.join(dir, "pb-evil.prebuilt"))
      assert %{state: :idle} = DeployRunner.status("pb-evil")
    end

    test "a digest mismatch is refused before anything is staged" do
      dir = run_dir()
      {b64, _sha} = prebuilt_artifact()

      put_cfg(enabled: true, run_state_dir: dir, command: stub("exit 0"))

      request =
        req("pb-digest", artifact_b64: b64, artifact_sha256: String.duplicate("0", 64))

      assert {:error, {:artifact_rejected, "E_DIGEST_MISMATCH", _}} =
               DeployRunner.trigger(request)

      refute File.exists?(Path.join(dir, "pb-digest.prebuilt"))
    end
  end

  # ── BPSTAGE parsing (charter D23 — stages outlive the log ring) ─────────

  describe "stage parsing" do
    test "all six stages survive a 900-line log flood that evicts the log ring" do
      put_cfg(
        enabled: true,
        # PLAN + BUILD:started are printed BEFORE 900 lines of npm noise — with
        # a 500-line ring they are provably gone from `log` by the time the run
        # ends. The stage list must be untouched by that.
        command:
          stub("""
          echo 'BPSTAGE name=PLAN status=ok build_id=b9'
          echo 'BPSTAGE name=BUILD status=started build_id=b9'
          for i in $(seq 1 900); do echo "npm noise line $i"; done
          echo 'BPSTAGE name=BUILD status=ok build_id=b9'
          echo 'BPSTAGE name=STAGE status=ok build_id=b9'
          echo 'BPSTAGE name=HEALTH status=ok build_id=b9'
          echo 'BPSTAGE name=SWITCH status=ok build_id=b9'
          echo 'BPSTAGE name=RETIRE status=ok build_id=b9'
          exit 0
          """)
      )

      assert DeployRunner.trigger(req("flooded", build_id: "b9")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = status = await_done("flooded")

      assert Enum.map(status.stages, & &1.name) == ~w(PLAN BUILD STAGE HEALTH SWITCH RETIRE)
      assert Enum.all?(status.stages, &(&1.status == "ok"))
      assert Enum.all?(status.stages, &(&1.build_id == "b9"))

      # Protective: the ring DID evict the early lines — so the six stages above
      # are not passing by accident on an accidentally-unbounded log.
      assert length(status.log) == 500
      refute Enum.any?(status.log, &String.contains?(&1, "name=PLAN"))
      refute Enum.any?(status.log, &(String.trim(&1) == "npm noise line 1"))
      # …while the tail (where a failure reason comes from) is intact.
      assert Enum.any?(status.log, &String.contains?(&1, "name=RETIRE"))
    end

    test "a stage is upserted, not appended — started is superseded by its outcome" do
      put_cfg(
        enabled: true,
        command:
          stub("""
          echo 'BPSTAGE name=BUILD status=started build_id=b1'
          echo 'BPSTAGE name=BUILD status=failed build_id=b1'
          exit 12
          """)
      )

      assert DeployRunner.trigger(req("upsert")) == {:ok, :started}
      assert %{state: :done} = status = await_done("upsert")

      assert [%{name: "BUILD", status: "failed"}] = status.stages
    end

    # The engine hangs the REAL reason off the terminal stage line as detail=…
    # (npm's 401, HEALTH's marker miss). The control plane reads that key and the
    # CLI prints it as the failed stage's message — so if it is dropped here, every
    # failure silently degrades to a canned "the build failed" with the true cause
    # nowhere on screen. Pin it end to end.
    test "detail= on a terminal stage line survives into the stage (the real reason)" do
      put_cfg(
        enabled: true,
        command:
          stub("""
          echo 'BPSTAGE name=BUILD status=started build_id=b1'
          echo 'BPSTAGE name=BUILD status=failed build_id=b1 detail="FATAL: 401 Unauthorized - the site read token is invalid"'
          exit 12
          """)
      )

      assert DeployRunner.trigger(req("detail")) == {:ok, :started}
      assert %{state: :done} = status = await_done("detail")

      assert [
               %{
                 name: "BUILD",
                 status: "failed",
                 detail: "FATAL: 401 Unauthorized - the site read token is invalid"
               }
             ] = status.stages
    end

    # HEALTH's detail is the marker miss — the one message that explains WHY a
    # build that compiled fine is being refused. It must not be swallowed.
    test "detail= rides an empty build_id (the engine emits build_id= before it resolves one)" do
      put_cfg(
        enabled: true,
        command:
          stub("""
          echo 'BPSTAGE name=PLAN status=noop build_id= detail="nothing to do"'
          echo 'BPSTAGE name=HEALTH status=failed build_id=b2 detail="bp-content-rev marker is empty - the build lost its content link"'
          exit 14
          """)
      )

      assert DeployRunner.trigger(req("detail-empty-bid")) == {:ok, :started}
      assert %{state: :done} = status = await_done("detail-empty-bid")

      assert [
               %{name: "PLAN", status: "noop", detail: "nothing to do"},
               %{
                 name: "HEALTH",
                 status: "failed",
                 detail: "bp-content-rev marker is empty - the build lost its content link"
               }
             ] = status.stages
    end

    test "a stage with no detail= reports detail: nil, never a phantom string" do
      put_cfg(
        enabled: true,
        command:
          stub("""
          echo 'BPSTAGE name=SWITCH status=ok build_id=b3'
          exit 0
          """)
      )

      assert DeployRunner.trigger(req("no-detail")) == {:ok, :started}
      assert %{state: :done} = status = await_done("no-detail")

      assert [%{name: "SWITCH", status: "ok", detail: nil, build_id: "b3"}] = status.stages
    end

    test "a garbage or unknown BPSTAGE line is log, never a stage" do
      put_cfg(
        enabled: true,
        command:
          stub("""
          echo 'BPSTAGE name=PWNED status=ok build_id=b1'
          echo 'BPSTAGE name=BUILD status=bogus build_id=b1'
          echo 'BPSTAGE garbage'
          echo 'BPSTAGE name=PLAN status=ok build_id=b1'
          exit 0
          """)
      )

      assert DeployRunner.trigger(req("garbage")) == {:ok, :started}
      assert %{state: :done} = status = await_done("garbage")

      assert Enum.map(status.stages, & &1.name) == ["PLAN"]
    end
  end

  # ── typed exit codes → honest failure reasons ───────────────────────────

  describe "failure_reason" do
    test "exit 12 carries the REAL npm reason line, not a generic message" do
      put_cfg(
        enabled: true,
        command:
          stub("""
          echo 'BPSTAGE name=BUILD status=started build_id=b1'
          echo 'npm ERR! code E401'
          echo 'npm ERR! 401 Unauthorized - GET https://registry.example/@scope%2fpkg'
          echo 'BPSTAGE name=BUILD status=failed build_id=b1'
          echo "[site-deploy] BUILD failed for 'reason-401' build b1 — live release untouched"
          exit 12
          """)
      )

      assert DeployRunner.trigger(req("reason-401")) == {:ok, :started}
      assert %{state: :done, exit_code: 12} = status = await_done("reason-401")

      assert status.failure_reason =~ "BUILD failed (exit 12)"
      assert status.failure_reason =~ "401 Unauthorized"
      assert status.failure_reason =~ "live release untouched"
      assert [%{name: "BUILD", status: "failed"}] = status.stages
    end

    test "every typed exit code maps to its own honest label + the stream's reason" do
      # Exit 23 is deliberately ABSENT from this deploy-request table: the shell
      # only produces 23 for a NON-deploy mode refused by the per-site lock (a
      # blocked DEPLOY queues on `flock -w 1200` and times out as 15 — it can
      # never exit 23). The old pin here drove {23, "rollback: …"} under a
      # deploy request, a state the shell cannot produce; the honest 23 pins
      # live below, driven under the modes that CAN exit 23.
      for {code, fragment, slug} <- [
            {13, "STAGE failed", "exit-13"},
            {14, "HEALTH gate failed", "exit-14"},
            # Exit 15 has TWO producers — the box's fleet build gate and the
            # site's own deploy lock — and the label may not name just one.
            {15, "gave up waiting for a deploy lock", "exit-15"},
            {16, "SWITCH failed", "exit-16"},
            {21, "rollback: no previous release", "exit-21"},
            {22, "rollback: not supported", "exit-22"},
            {24, "rollback failed", "exit-24"}
          ] do
        put_cfg(enabled: true, command: stub("echo 'the real reason #{code}'; exit #{code}"))

        assert DeployRunner.trigger(req(slug)) == {:ok, :started}
        assert %{state: :done, exit_code: ^code} = status = await_done(slug)

        assert status.failure_reason =~ fragment
        assert status.failure_reason =~ "the real reason #{code}"
      end
    end

    # ── teardown speaks teardown (Port fallback path) ─────────────────────
    #
    # REACHABILITY, framed honestly: the typed 23/25 exit-code arms below are
    # user-visible on THIS Port fallback path only (handle_info exit_status →
    # finish_run → failure_reason). On the systemd path the exit code is swept
    # by `--collect`, so the same copy is minted from the LOG markers instead
    # (TEARDOWN_FAILED= / lock_held — see "systemd unit path — finalize"); the
    # exit-code arms are LATENT there. The -1 abnormal-end opener, by contrast,
    # is live on EVERY teardown failure path, both sinks.

    test "exit 23 under a ROLLBACK keeps its rollback voice — the state the shell produces" do
      put_cfg(enabled: true, rollback_command: stub("echo 'deploy lock held'; exit 23"))

      assert DeployRunner.trigger(req("rb-23", mode: "rollback")) == {:ok, :started}
      assert %{state: :done, exit_code: 23, mode: :rollback} = status = await_done("rb-23")
      assert status.failure_reason =~ "rollback: a deploy is in flight (exit 23)"
    end

    test "exit 23 under a TEARDOWN speaks the lock sentence — no rollback verb, no dead deploy" do
      put_cfg(
        enabled: true,
        teardown_command:
          stub(
            "echo \"deploy lock held for 'td-23' — refusing to teardown while a deploy runs (lock_held)\"; exit 23"
          )
      )

      assert DeployRunner.trigger(req("td-23", mode: "teardown")) == {:ok, :started}
      assert %{state: :done, exit_code: 23, mode: :teardown} = status = await_done("td-23")

      assert status.failure_reason =~
               "a deploy is running on the box — try again once it finishes (exit 23)"

      refute status.failure_reason =~ "rollback"
      refute status.failure_reason =~ "deploy process died abnormally"
    end

    test "exit 25 under a TEARDOWN is teardown-voiced and carries the script's own detail" do
      put_cfg(
        enabled: true,
        teardown_command:
          stub("""
          echo 'TEARDOWN FAILED — the /sites/td-25 route is still being served'
          echo 'TEARDOWN_FAILED=td-25 detail="the /sites/td-25 route is still being served"'
          exit 25
          """)
      )

      assert DeployRunner.trigger(req("td-25", mode: "teardown")) == {:ok, :started}
      assert %{state: :done, exit_code: 25, mode: :teardown} = status = await_done("td-25")

      assert status.failure_reason =~ "teardown failed — the site was not torn down (exit 25)"
      assert status.failure_reason =~ "route is still being served"
      refute status.failure_reason =~ "deploy failed"
      refute status.failure_reason =~ "deploy process died abnormally"
    end

    test "exit 0 has no failure_reason" do
      put_cfg(enabled: true, command: stub("echo fine; exit 0"))

      assert DeployRunner.trigger(req("clean")) == {:ok, :started}
      assert %{state: :done, exit_code: 0, failure_reason: nil} = await_done("clean")
    end

    test "a run that outlives its deadline is force-closed — the slug's slot cannot wedge" do
      put_cfg(enabled: true, command: stub("sleep 30"), run_deadline_ms: 60)

      assert DeployRunner.trigger(req("wedged")) == {:ok, :started}
      assert %{state: :done, exit_code: -2} = status = await_done("wedged")
      assert status.failure_reason =~ "deadline"

      # The slot is free again.
      put_cfg(enabled: true, command: stub("exit 0"), run_deadline_ms: 60_000)
      assert DeployRunner.trigger(req("wedged", build_id: "b2")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("wedged")
    end

    test "a missing executable is a start failure, never a Runner crash" do
      pid = Process.whereis(DeployRunner)
      put_cfg(enabled: true, command: {"bp-no-such-executable-9f2a", []})

      assert DeployRunner.trigger(req("no-exe")) == {:error, :start_failed}
      assert Process.whereis(DeployRunner) == pid
      assert %{state: :idle} = DeployRunner.status("no-exe")
    end
  end

  # ── mode ────────────────────────────────────────────────────────────────

  describe "mode" do
    test "rollback runs the rollback command, deploy runs the deploy command" do
      put_cfg(
        enabled: true,
        command: stub("echo DEPLOY_RAN; exit 0"),
        rollback_command: stub("echo ROLLBACK_RAN; exit 0")
      )

      assert DeployRunner.trigger(req("mode-d")) == {:ok, :started}
      assert %{state: :done, mode: :deploy} = deployed = await_done("mode-d")
      assert Enum.any?(deployed.log, &String.contains?(&1, "DEPLOY_RAN"))

      assert DeployRunner.trigger(req("mode-r", mode: "rollback")) == {:ok, :started}
      assert %{state: :done, mode: :rollback} = rolled = await_done("mode-r")
      assert Enum.any?(rolled.log, &String.contains?(&1, "ROLLBACK_RAN"))
    end
  end

  # ── runtime_target dispatch (charter D63 — the second serve-backend) ──────

  describe "runtime_target" do
    test "a node deploy runs the node engine script; static runs the static one" do
      put_cfg(
        enabled: true,
        command: stub("echo STATIC_DEPLOY_RAN; exit 0"),
        node_command: stub("echo NODE_DEPLOY_RAN; exit 0")
      )

      # Default (absent) runtime_target ⇒ :static ⇒ the static engine.
      assert DeployRunner.trigger(req("rt-static")) == {:ok, :started}
      assert %{state: :done, runtime_target: :static} = st = await_done("rt-static")
      assert Enum.any?(st.log, &String.contains?(&1, "STATIC_DEPLOY_RAN"))
      refute Enum.any?(st.log, &String.contains?(&1, "NODE_DEPLOY_RAN"))

      # runtime_target=node ⇒ the node-slot SSR engine.
      assert DeployRunner.trigger(req("rt-node", runtime_target: "node")) == {:ok, :started}
      assert %{state: :done, runtime_target: :node} = nd = await_done("rt-node")
      assert Enum.any?(nd.log, &String.contains?(&1, "NODE_DEPLOY_RAN"))
      refute Enum.any?(nd.log, &String.contains?(&1, "STATIC_DEPLOY_RAN"))
    end

    test "a node rollback runs the node rollback script, not the static one" do
      put_cfg(
        enabled: true,
        rollback_command: stub("echo STATIC_ROLLBACK_RAN; exit 0"),
        node_rollback_command: stub("echo NODE_ROLLBACK_RAN; exit 0")
      )

      assert DeployRunner.trigger(req("rt-node-rb", mode: "rollback", runtime_target: "node")) ==
               {:ok, :started}

      assert %{state: :done, mode: :rollback, runtime_target: :node} =
               rolled = await_done("rt-node-rb")

      assert Enum.any?(rolled.log, &String.contains?(&1, "NODE_ROLLBACK_RAN"))
      refute Enum.any?(rolled.log, &String.contains?(&1, "STATIC_ROLLBACK_RAN"))
    end

    test "the default node engine script is deploy/site-deploy-node.sh (argv, not env)" do
      # No command override: prove the SHIPPED default command names the node
      # script — the box's real dispatch when the CP sends runtime_target=node.
      # A node rollback (no build_id, no provision) exercises the argv without
      # needing the script to exist: bash reports "No such file" and exits
      # non-zero, but the log carries the exact relative path we dispatched to.
      #
      # `cd:` is LOAD-BEARING, do not drop it: run_cd honors config[:cd] first
      # (deploy_runner.ex:374), so bash runs from a scriptless tmp dir where
      # `deploy/site-deploy-node.sh` cannot resolve — it prints the path in a
      # "No such file or directory" error on EVERY host and the real script
      # never runs. Without it, run_cd falls back to the repo root where the
      # real script EXISTS, so on a flock-present host (Linux CI) it executes,
      # logs "not_supported", and never echoes its own path → non-hermetic red.
      scriptless_tmp =
        Path.join(System.tmp_dir!(), "bp-scriptless-#{System.unique_integer([:positive])}")

      File.mkdir_p!(scriptless_tmp)
      on_exit(fn -> File.rm_rf(scriptless_tmp) end)

      put_cfg(enabled: true, cd: scriptless_tmp)

      assert DeployRunner.trigger(req("rt-default", mode: "rollback", runtime_target: "node")) ==
               {:ok, :started}

      assert %{state: :done} = status = await_done("rt-default")
      assert Enum.any?(status.log, &String.contains?(&1, "deploy/site-deploy-node.sh"))
      # The real script must NOT have executed — its bespoke log lines prove it did.
      refute Enum.any?(status.log, &String.contains?(&1, "not_supported"))
      refute Enum.any?(status.log, &String.contains?(&1, "no live route"))
    end
  end

  # ── status ──────────────────────────────────────────────────────────────

  describe "status/1" do
    test "a slug that has never deployed is :idle, not an error" do
      assert %{state: :idle, slug: "never-seen", stages: [], log: []} =
               DeployRunner.status("never-seen")
    end
  end

  # ── PROVISION runs before the port (charter D33/D34) ─────────────────────

  describe "provisioning" do
    test "a deploy materializes the site source BEFORE the deploy port opens", %{sites: sites} do
      put_cfg(enabled: true, command: stub("exit 0"))

      assert DeployRunner.trigger(req("prov-blog")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("prov-blog")

      # The template landed at exactly the <sites_dir>/<slug>/src the engine
      # reads — proof the source now exists for BUILD (no more exit-10).
      src = Path.join([sites, "prov-blog", "src"])
      assert File.exists?(Path.join(src, "package.json"))
      assert File.regular?(Path.join(src, ".bp-provisioned"))
    end

    test "a provision failure short-circuits like an open_port failure (no run, no port)" do
      pid = Process.whereis(DeployRunner)

      # Point the template at nothing — provision fails fail-closed, so the
      # deploy must never start (exactly like a missing executable does).
      Application.put_env(:barkpark, Provisioner,
        sites_dir:
          Path.join(System.tmp_dir!(), "bp-dr-fail-#{System.unique_integer([:positive])}"),
        template_dir:
          Path.join(System.tmp_dir!(), "bp-no-template-#{System.unique_integer([:positive])}")
      )

      put_cfg(enabled: true, command: stub("exit 0"))

      # A NAMED typed refusal, not a bare :start_failed (deploy-reliability
      # D26). The two have different operators and different fixes, and folding
      # them together is what sent 25 consecutive %File.Error{}s to journald and
      # nowhere else.
      assert {:error, {:provision_failed, reason}} = DeployRunner.trigger(req("prov-fail"))
      assert is_binary(reason)
      # The PATH survives into the reason — the missing template's identity IS
      # the diagnosis. A bare :start_failed named nothing at all.
      assert reason =~ "site template not found"
      assert reason =~ "bp-no-template-"
      # The Runner survived the fail-closed provision…
      assert Process.whereis(DeployRunner) == pid
      # …and no run was recorded — the slug is still idle.
      assert %{state: :idle} = DeployRunner.status("prov-fail")
    end

    test "a %File.Error{} provision failure keeps its ACTION and PATH in the typed refusal",
         %{template: template} do
      # An UNWRITABLE sites dir is the shape that hid 63% of this fleet's
      # failures: File.mkdir_p!/cp_r! RAISE a %File.Error{}, the Provisioner
      # degrades it to {:provision_failed, error}, and the old arm inspected it
      # into a Logger line nobody read. The action + path must survive to the
      # caller.
      Application.put_env(:barkpark, Provisioner,
        sites_dir: "/dev/null/bp-unwritable-sites",
        template_dir: template
      )

      put_cfg(enabled: true, command: stub("exit 0"))

      assert {:error, {:provision_failed, reason}} = DeployRunner.trigger(req("prov-eacces"))
      assert reason =~ "could not make directory"
      assert reason =~ "/dev/null/bp-unwritable-sites"
      # The errno is RENDERED, not left as a bare atom nobody can act on.
      refute reason =~ "enotdir"
      assert %{state: :idle} = DeployRunner.status("prov-eacces")
    end

    test "the typed provision refusal SCRUBS a secret out of its reason" do
      # A reason string crosses an HTTP boundary as a 500 body, and the shared
      # display scrubber leaks this box's own `bppat_` token shape 95.1% of the
      # time — so the refusal redacts locally and explicitly. A token can reach a
      # reason through any path component the box was configured with.
      leaky_dir =
        Path.join(
          System.tmp_dir!(),
          "bp-missing-BARKPARK_TOKEN=bppat_livetokenvalue123-#{System.unique_integer([:positive])}"
        )

      Application.put_env(:barkpark, Provisioner,
        sites_dir: Path.join(System.tmp_dir!(), "bp-scrub-#{System.unique_integer([:positive])}"),
        template_dir: leaky_dir
      )

      put_cfg(enabled: true, command: stub("exit 0"))

      assert {:error, {:provision_failed, reason}} = DeployRunner.trigger(req("prov-secret"))
      refute reason =~ "bppat_livetokenvalue123"
      assert reason =~ "[REDACTED]"
      # …and the diagnosis still survives the redaction.
      assert reason =~ "site template not found"
    end

    # The two reason shapes the provisioner's swap produces (provisioner.ex:202
    # and :240) are the ONLY two whose operator sentence lives beside its
    # producer. Nothing asserted these before, so a future move of either clause
    # would have degraded the log line to Elixir tuple jargon in silence.
    test "the swap-aside failure renders as an operator sentence, not a tuple" do
      assert DeployRunner.describe_provision_reason({:swap_aside_failed, :eacces}) ==
               "could not move the live site source aside before swapping in the new one: permission denied"
    end

    test "a lock the other deploy holds renders as an operator sentence, not a tuple" do
      assert DeployRunner.describe_provision_reason({:lock_aborted, "search-capstone"}) ==
               "another deploy of search-capstone holds the provision lock and it could not be acquired"
    end

    test "a rollback does NOT provision — its source is already there", %{sites: sites} do
      put_cfg(enabled: true, rollback_command: stub("exit 0"))

      assert DeployRunner.trigger(req("rb-noprov", mode: "rollback")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = await_done("rb-noprov")

      # No src materialized for a rollback.
      refute File.exists?(Path.join([sites, "rb-noprov", "src"]))
    end
  end

  # ── request validation (nothing reaches argv/env unvalidated) ───────────

  describe "DeployRequest.new/1" do
    test "accepts a well-formed deploy" do
      assert {:ok, %DeployRequest{slug: "my-blog", build_id: "a1.b2_c3-d4", mode: :deploy}} =
               DeployRequest.new(%{"slug" => "my-blog", "build_id" => "a1.b2_c3-d4"})
    end

    test "rejects a path-traversing or shell-ish slug" do
      for bad <- [
            "../etc",
            "My-Blog",
            "-leading",
            "a/b",
            "a;rm -rf /",
            "",
            String.duplicate("a", 64)
          ] do
        assert {:error, "invalid_slug", _} =
                 DeployRequest.new(%{"slug" => bad, "build_id" => "b1"})
      end
    end

    test "a trailing newline cannot smuggle past the slug regex" do
      # `^…$` in Elixir also matches before a trailing \n — \A…\z is why this fails.
      assert {:error, "invalid_slug", _} =
               DeployRequest.new(%{"slug" => "ok\n../../etc", "build_id" => "b1"})
    end

    test "rejects a bad or missing build_id on a deploy" do
      assert {:error, "invalid_build_id", _} = DeployRequest.new(%{"slug" => "s"})

      assert {:error, "invalid_build_id", _} =
               DeployRequest.new(%{"slug" => "s", "build_id" => "../x"})
    end

    test "a rollback needs no build_id and drops one that is passed" do
      assert {:ok, %DeployRequest{mode: :rollback, build_id: nil}} =
               DeployRequest.new(%{"slug" => "s", "mode" => "rollback", "build_id" => "b1"})
    end

    test "rejects an unknown mode (never String.to_atom on request data)" do
      assert {:error, "invalid_deploy_mode", _} =
               DeployRequest.new(%{"slug" => "s", "mode" => "nuke"})
    end

    test "runtime_target defaults to :static and accepts the closed enum (charter D63)" do
      # Absent ⇒ :static (backward-compatible with every pre-node caller).
      assert {:ok, %DeployRequest{runtime_target: :static}} =
               DeployRequest.new(%{"slug" => "s", "build_id" => "b1"})

      assert {:ok, %DeployRequest{runtime_target: :static}} =
               DeployRequest.new(%{
                 "slug" => "s",
                 "build_id" => "b1",
                 "runtime_target" => "static"
               })

      assert {:ok, %DeployRequest{runtime_target: :node}} =
               DeployRequest.new(%{"slug" => "s", "build_id" => "b1", "runtime_target" => "node"})
    end

    test "rejects an unknown runtime_target (never String.to_atom on request data)" do
      # An open string here would reach an engine-script argv and, later, a
      # systemd slot unit NAME — so a garbage value is a 400, never an atom.
      for bad <- ["docker", "Node", "node ", "", "systemctl-injected"] do
        assert {:error, "invalid_runtime_target", message} =
                 DeployRequest.new(%{"slug" => "s", "build_id" => "b1", "runtime_target" => bad})

        assert message =~ "static"
        assert message =~ "node"
      end
    end

    test "template defaults to nil and accepts the closed enum (search-template D7)" do
      # Absent ⇒ nil (the Provisioner derives the template from runtime_target,
      # so every pre-template caller is unaffected).
      assert {:ok, %DeployRequest{template: nil}} =
               DeployRequest.new(%{"slug" => "s", "build_id" => "b1"})

      assert {:ok, %DeployRequest{template: :astro_starter}} =
               DeployRequest.new(%{
                 "slug" => "s",
                 "build_id" => "b1",
                 "template" => "astro-starter"
               })

      assert {:ok, %DeployRequest{template: :next_starter}} =
               DeployRequest.new(%{
                 "slug" => "s",
                 "build_id" => "b1",
                 "template" => "next-starter"
               })

      assert {:ok, %DeployRequest{template: :search_starter}} =
               DeployRequest.new(%{
                 "slug" => "s",
                 "build_id" => "b1",
                 "template" => "search-starter"
               })
    end

    test "rejects an unknown template (it indexes a filesystem path — never String.to_atom)" do
      # An open string here would index `templates/<value>` — a path-traversal /
      # arbitrary-source seam — so a garbage value is a 400, never an atom.
      for bad <- ["../etc", "search_starter", "Search-Starter", "", "wp-starter", "a/b"] do
        assert {:error, "invalid_template", message} =
                 DeployRequest.new(%{"slug" => "s", "build_id" => "b1", "template" => bad})

        assert message =~ "search-starter"
      end
    end

    test "rejects an unknown env var rather than silently dropping it" do
      assert {:error, "invalid_env", message} =
               DeployRequest.new(%{
                 "slug" => "s",
                 "build_id" => "b1",
                 "env" => %{"BARKPARK_KEK" => "nice try"}
               })

      assert message =~ "BARKPARK_KEK"
    end

    test "rejects a control character in an env value" do
      assert {:error, "invalid_env", _} =
               DeployRequest.new(%{
                 "slug" => "s",
                 "build_id" => "b1",
                 "env" => %{"BARKPARK_TOKEN" => "tok\nBPSTAGE name=SWITCH status=ok"}
               })
    end
  end

  # ── systemd transient-unit path: observer + finalizer + re-attach ─────────
  #
  # (search-template W6 D29/D31/D32/D33) On a systemd box the build no longer
  # hangs off the BEAM — it runs as a SIBLING transient unit that survives a
  # barkpark.service restart, and the Runner OBSERVES its durable status/log
  # files + FINALIZES from them. These tests stub `systemd-run` and
  # `systemctl is-active` (absent on macOS/CI) so the whole path runs hermetically.

  # Writes an executable script to a tmp file and returns its path.
  defp write_script(body) do
    path = Path.join(System.tmp_dir!(), "bp-dr-#{System.unique_integer([:positive])}.sh")
    File.write!(path, body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  # A stand-in for `systemd-run`: parses `--property=EnvironmentFile=`, sources it
  # (so the engine sees BARKPARK_SITE_STATUS_FILE/LOG_FILE + the build vars), and
  # execs the engine command. It also dumps its OWN argv so a test can prove the
  # unit flags — and prove NO secret rides argv. Runs SYNCHRONOUSLY, which is
  # faithful: `systemd-run` registers-and-returns, and here the "unit" simply
  # completes before the call returns, after which is-active reports it gone.
  defp fake_systemd_run(argv_dump) do
    write_script("""
    #!/usr/bin/env bash
    printf '%s\\n' "$@" > #{argv_dump}
    envfile=""
    cmd=()
    for arg in "$@"; do
      case "$arg" in
        --property=EnvironmentFile=*) envfile="${arg#--property=EnvironmentFile=}" ;;
        --unit=*|--property=*|--collect) ;;
        *) cmd+=("$arg") ;;
      esac
    done
    if [ -n "$envfile" ]; then set -a; . "$envfile"; set +a; fi
    # `systemd-run` exits 0 on REGISTRATION success — the unit's own exit code is
    # async and irrelevant here. Run the engine, then always exit 0.
    "${cmd[@]}"
    exit 0
    """)
  end

  defp echo_script(word), do: write_script("#!/usr/bin/env bash\necho #{word}\n")

  # `systemctl is-active <unit>` that answers "active" for ONE slug's units and
  # "inactive" for everything else. An always-active stub lies about every OTHER
  # slug's unit too — and the box's build-slot door reads exactly that, so on
  # the singleton Runner a unit some earlier test left tracked would refuse this
  # test's deploy with `box_at_capacity`.
  defp active_only_for(slug) do
    write_script("""
    #!/usr/bin/env bash
    case "$1" in
      bp-site-build-#{slug}-*) echo active ;;
      *) echo inactive ;;
    esac
    """)
  end

  # A control-plane stub that HANGS for `secs` before echoing `word` and exiting
  # 0 — stands in for a wedged `systemd-run` / `systemctl` (a stuck D-Bus, a
  # unit that won't stop). An UNBOUNDED System.cmd blocks the caller the full
  # `secs`; the deadline wrapper must cut it off far sooner.
  defp slow_ctl_script(secs, word),
    do: write_script("#!/usr/bin/env bash\nsleep #{secs}\necho #{word}\n")

  # A run-state dir isolated per test (must survive a "restart" — a fresh
  # GenServer — so it is a real dir, not deleted mid-test).
  defp run_dir do
    dir = Path.join(System.tmp_dir!(), "bp-dr-runstate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # Start a FRESH Runner instance (its own init/1 re-attaches) — the app's
  # singleton already booted, so re-attach must be exercised on a new process.
  defp start_fresh_runner do
    name = :"dr_reattach_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(DeployRunner, [], name: name)
    # A bare `Process.alive?/1` guard is racy: the re-attach paths (e.g. the
    # "terminal unit on boot" test) let the runner finalize and self-terminate,
    # so the process can die BETWEEN the alive? check and GenServer.stop, which
    # then exits :noproc and reds the whole suite from on_exit. Swallow that
    # already-dead exit — a live runner still stops normally.
    on_exit(fn ->
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  # Simulate a build a PRIOR BEAM launched: manifest + (partial) status/log +
  # a 0600 secret env file on disk, named for a still-or-once-live unit.
  defp seed_manifest(dir, slug, opts) do
    unit = "bp-site-build-#{slug}-#{Keyword.get(opts, :build_id, "b1")}-1.service"
    status_file = Path.join(dir, "#{slug}.status")
    log_file = Path.join(dir, "#{slug}.log")
    env_file = Path.join(dir, "#{slug}.env")

    File.write!(status_file, Keyword.get(opts, :status, ""))
    File.write!(log_file, Keyword.get(opts, :log, ""))
    File.write!(env_file, "BARKPARK_TOKEN=secret\n")
    File.chmod!(env_file, 0o600)

    manifest = %{
      "slug" => slug,
      "build_id" => Keyword.get(opts, :build_id, "b1"),
      "content_rev" => "rev-1",
      "mode" => "deploy",
      "runtime_target" => "static",
      "unit_name" => unit,
      "status_file" => status_file,
      "log_file" => log_file,
      "build_env_file" => env_file,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    File.write!(Path.join(dir, "#{slug}.manifest.json"), Jason.encode!(manifest))
    %{unit: unit, status_file: status_file, env_file: env_file}
  end

  describe "systemd unit path — spawn + finalize" do
    test "spawns a transient unit, writes a 0600 EnvironmentFile (no secret on argv), reconstructs :done from the status file" do
      dir = run_dir()
      argv_dump = Path.join(dir, "argv.dump")

      engine =
        stub("""
        echo 'BPSTAGE name=PLAN status=ok build_id=b9' >> "$BARKPARK_SITE_STATUS_FILE"
        echo 'BPSTAGE name=BUILD status=started build_id=b9' >> "$BARKPARK_SITE_STATUS_FILE"
        echo 'npm build output here' >> "$BARKPARK_SITE_LOG_FILE"
        echo 'BPSTAGE name=BUILD status=ok build_id=b9' >> "$BARKPARK_SITE_STATUS_FILE"
        echo 'BPSTAGE name=SWITCH status=ok build_id=b9' >> "$BARKPARK_SITE_STATUS_FILE"
        exit 0
        """)

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {fake_systemd_run(argv_dump), []},
        is_active_cmd: {echo_script("inactive"), []},
        command: engine
      )

      request =
        req("unitspawn",
          build_id: "b9",
          content_rev: "rev-7",
          env: %{
            "BARKPARK_API_URL" => "http://127.0.0.1:4000",
            "BARKPARK_TOKEN" => "per-site-token"
          }
        )

      assert DeployRunner.trigger(request) == {:ok, :started}

      # The EnvironmentFile is 0600 and CARRIES the secret; argv does NOT.
      env_file = Path.join(dir, "unitspawn-b9.env")
      assert File.exists?(env_file)
      %{mode: mode} = File.stat!(env_file)
      assert Bitwise.band(mode, 0o777) == 0o600
      env_contents = File.read!(env_file)
      assert env_contents =~ "BARKPARK_TOKEN=per-site-token"
      assert env_contents =~ "BARKPARK_SITE_STATUS_FILE="
      assert env_contents =~ ~r/^PATH=/m

      argv = File.read!(argv_dump)
      assert argv =~ ~r/^--unit=bp-site-build-unitspawn-b9-\d+\.service$/m
      assert argv =~ "--property=MemoryMax=1500M"
      assert argv =~ "--property=CPUQuota=150%"
      assert argv =~ "--property=EnvironmentFile=#{env_file}"
      assert argv =~ "--collect"
      # The secret NEVER reaches a ps-visible command line.
      refute argv =~ "per-site-token"

      # is-active reports the unit gone ⇒ finalize :done from the durable fold.
      status = DeployRunner.status("unitspawn")
      assert status.state == :done
      assert status.exit_code == 0
      assert status.build_id == "b9"
      assert Enum.map(status.stages, & &1.name) == ~w(PLAN BUILD SWITCH)
      # started was superseded by ok (upsert), and build_id preserved.
      assert Enum.all?(status.stages, &(&1.build_id == "b9"))
      assert Enum.any?(status.log, &String.contains?(&1, "npm build output here"))

      # The secret env file is swept once the run finalizes.
      refute File.exists?(env_file)
    end

    test "a failed unit reconstructs its typed exit + the real reason from the fold" do
      dir = run_dir()

      engine =
        stub("""
        echo 'BPSTAGE name=BUILD status=started build_id=b1' >> "$BARKPARK_SITE_STATUS_FILE"
        echo 'npm ERR! 401 Unauthorized' >> "$BARKPARK_SITE_LOG_FILE"
        echo 'BPSTAGE name=BUILD status=failed build_id=b1 detail="FATAL: 401 Unauthorized - the site read token is invalid"' >> "$BARKPARK_SITE_STATUS_FILE"
        exit 12
        """)

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        is_active_cmd: {echo_script("failed"), []},
        command: engine
      )

      assert DeployRunner.trigger(req("unitfail", build_id: "b1")) == {:ok, :started}

      status = DeployRunner.status("unitfail")
      assert status.state == :done
      assert status.exit_code == 12
      assert status.failure_reason =~ "BUILD failed (exit 12)"
      assert status.failure_reason =~ "401 Unauthorized - the site read token is invalid"
      assert [%{name: "BUILD", status: "failed"}] = status.stages
    end

    test "a successful rollback finalizes exit 0 + the flipped-to build, not an abnormal death" do
      dir = run_dir()

      # A rollback is a pointer flip, NOT a deploy: it emits NO BPSTAGE — only the
      # human/machine lines the engine prints (`ROLLED BACK` + `TARGET_BUILD=<id>`).
      # The old finalizer folded its empty stages through the deploy path and read
      # `stages == []` as `-1` abnormal death — reporting every SUCCESSFUL rollback
      # as a failure. The mode-aware path must read the rollback's own contract.
      engine =
        stub("""
        echo 'ROLLED BACK: current -> releases/b2 (was b7)' >> "$BARKPARK_SITE_LOG_FILE"
        echo 'TARGET_BUILD=b2' >> "$BARKPARK_SITE_LOG_FILE"
        echo "ROLLED BACK — 'unitrb' now at b2" >> "$BARKPARK_SITE_LOG_FILE"
        exit 0
        """)

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        is_active_cmd: {echo_script("inactive"), []},
        rollback_command: engine
      )

      assert DeployRunner.trigger(req("unitrb", mode: "rollback")) == {:ok, :started}

      status = DeployRunner.status("unitrb")
      assert status.state == :done
      assert status.exit_code == 0
      assert status.failure_reason == nil
      # The reply names the release now serving, parsed from `TARGET_BUILD=`.
      assert status.build_id == "b2"
      # A rollback emits no BPSTAGE — the finalizer must NOT read that as death.
      assert status.stages == []
    end

    test "a no_previous rollback finalizes its typed 21, not an abnormal death" do
      dir = run_dir()

      # Unit mode has no exit code (`--collect` sweeps it), so the typed rollback
      # failure is derived from the engine's own `(no_previous)` log marker.
      engine =
        stub("""
        echo "no previous release recorded for 'unitrb21' (no_previous)" >> "$BARKPARK_SITE_LOG_FILE"
        exit 21
        """)

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        is_active_cmd: {echo_script("inactive"), []},
        rollback_command: engine
      )

      assert DeployRunner.trigger(req("unitrb21", mode: "rollback")) == {:ok, :started}

      status = DeployRunner.status("unitrb21")
      assert status.state == :done
      assert status.exit_code == 21
      assert status.failure_reason =~ "no previous release (exit 21)"
    end

    test "a successful teardown finalizes exit 0, not an abnormal death" do
      dir = run_dir()

      # A teardown emits no BPSTAGE (like a rollback) — the engine prints a
      # `TORN_DOWN=<slug>` line to the durable log on success. The finalizer must
      # read that as exit 0, not fold its empty stages into a `-1` abnormal death.
      engine =
        stub("""
        echo 'disarmed caddy /sites/gone route' >> "$BARKPARK_SITE_LOG_FILE"
        echo 'TORN_DOWN=gone' >> "$BARKPARK_SITE_LOG_FILE"
        exit 0
        """)

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        is_active_cmd: {echo_script("inactive"), []},
        teardown_command: engine
      )

      assert DeployRunner.trigger(req("gone", mode: "teardown")) == {:ok, :started}

      status = DeployRunner.status("gone")
      assert status.state == :done
      assert status.exit_code == 0
      assert status.failure_reason == nil
      assert status.stages == []
    end

    test "a teardown whose log carries no typed marker is an abnormal end (-1) — teardown-voiced" do
      dir = run_dir()

      engine =
        stub("""
        echo 'caddy validate rejected the disarm — reverting' >> "$BARKPARK_SITE_LOG_FILE"
        exit 1
        """)

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        is_active_cmd: {echo_script("inactive"), []},
        teardown_command: engine
      )

      assert DeployRunner.trigger(req("halfgone", mode: "teardown")) == {:ok, :started}

      status = DeployRunner.status("halfgone")
      assert status.state == :done
      assert status.exit_code == -1
      # The -1 opener is the LIVE arm on every teardown failure (both sinks): it
      # must speak teardown — the old copy opened every teardown 422 with
      # "deploy process died abnormally", telling a user who pressed Delete that
      # a deploy died.
      assert status.failure_reason =~ "the teardown did not complete"
      assert status.failure_reason =~ "caddy validate rejected the disarm"
      refute status.failure_reason =~ "deploy process died abnormally"
    end

    test "a teardown TEARDOWN_FAILED= log finalizes typed 25 with the script's own detail" do
      dir = run_dir()

      # systemd sweeps the exit code (`--collect`), so the typed 25 is recovered
      # from the engine's own TEARDOWN_FAILED= marker — on this path the LOG
      # marker is what is live; the exit-CODE arm never fires here.
      engine =
        stub("""
        echo 'TEARDOWN FAILED — the /sites/unittd25 route is still being served' >> "$BARKPARK_SITE_LOG_FILE"
        echo 'TEARDOWN_FAILED=unittd25 detail="the /sites/unittd25 route is still being served"' >> "$BARKPARK_SITE_LOG_FILE"
        exit 25
        """)

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        is_active_cmd: {echo_script("inactive"), []},
        teardown_command: engine
      )

      assert DeployRunner.trigger(req("unittd25", mode: "teardown")) == {:ok, :started}

      status = DeployRunner.status("unittd25")
      assert status.state == :done
      assert status.exit_code == 25
      assert status.failure_reason =~ "teardown failed — the site was not torn down (exit 25)"
      assert status.failure_reason =~ "the /sites/unittd25 route is still being served"
      refute status.failure_reason =~ "deploy process died abnormally"
    end

    test "a teardown refused by the deploy lock finalizes typed 23 with the lock sentence" do
      dir = run_dir()

      # The engine logs `… (lock_held)` and exits 23 for ANY non-deploy mode the
      # per-site lock refuses; the sentence matches the CP's own lock_held copy
      # (cloud/sites/deploy.ex) so both refusal surfaces speak identically.
      engine =
        stub("""
        echo "deploy lock held for 'unittd23' — refusing to teardown while a deploy runs (lock_held)" >> "$BARKPARK_SITE_LOG_FILE"
        exit 23
        """)

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        is_active_cmd: {echo_script("inactive"), []},
        teardown_command: engine
      )

      assert DeployRunner.trigger(req("unittd23", mode: "teardown")) == {:ok, :started}

      status = DeployRunner.status("unittd23")
      assert status.state == :done
      assert status.exit_code == 23

      assert status.failure_reason =~
               "a deploy is running on the box — try again once it finishes (exit 23)"

      refute status.failure_reason =~ "rollback"
      refute status.failure_reason =~ "deploy process died abnormally"
    end
  end

  describe "systemd unit path — re-attach on init (D32)" do
    test "re-attaches to a live unit: :running, fold repopulated, same-slug re-trigger 409s" do
      dir = run_dir()

      seed_manifest(dir, "reattach-live",
        build_id: "b7",
        status:
          "BPSTAGE name=PLAN status=ok build_id=b7\nBPSTAGE name=BUILD status=started build_id=b7\n"
      )

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        is_active_cmd: {echo_script("active"), []},
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        command: stub("exit 0")
      )

      pid = start_fresh_runner()

      status = GenServer.call(pid, {:status, "reattach-live"})
      assert status.state == :running
      assert status.build_id == "b7"
      assert Enum.map(status.stages, & &1.name) == ~w(PLAN BUILD)
      assert %{name: "BUILD", status: "started"} = List.last(status.stages)

      # The single-flight slot was re-claimed across the "restart".
      assert GenServer.call(pid, {:trigger, req("reattach-live", build_id: "b8")}) ==
               {:error, :already_running}
    end

    test "finalizes a terminal unit on boot: :done from the status file, env file swept" do
      dir = run_dir()

      seeded =
        seed_manifest(dir, "reattach-done",
          build_id: "b3",
          status:
            "BPSTAGE name=PLAN status=ok build_id=b3\nBPSTAGE name=BUILD status=failed build_id=b3 detail=\"disk full during npm ci\"\n",
          log: "npm ERR! ENOSPC\n"
        )

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        is_active_cmd: {echo_script("inactive"), []},
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        command: stub("exit 0")
      )

      pid = start_fresh_runner()

      # init re-attach saw the unit gone ⇒ it swept the secret env file.
      refute File.exists?(seeded.env_file)

      status = GenServer.call(pid, {:status, "reattach-done"})
      assert status.state == :done
      assert status.exit_code == 12
      assert status.failure_reason =~ "BUILD failed (exit 12)"
      assert status.failure_reason =~ "disk full during npm ci"
      assert Enum.map(status.stages, & &1.name) == ~w(PLAN BUILD)
    end
  end

  # ── control-plane System.cmd deadlines (never wedge the singleton) ─────────
  #
  # (felix W21) The three synchronous ctl commands — systemd-run (in {:trigger}),
  # `systemctl is-active` (in {:status}), and `systemctl stop` (in the
  # {:unit_deadline} watchdog) — run INSIDE the singleton GenServer. Unbounded, a
  # hung external process would freeze the Runner for every slug (and safe_call
  # cannot rescue the handle_info watchdog). Each test drives a HANGING stub under
  # a SHRUNK ctl_cmd_timeout_ms and asserts the RAW GenServer.call returns under a
  # wall-clock cut (~deadline, well below the stub's sleep) + a degraded result —
  # so it REDS on the unbounded code and greens only when the deadline fires.
  # These target the raw GenServer.call/:timer.tc, NEVER public status/1 (whose
  # safe_call masks the wedge by timing out at 5s and returning the fallback).
  describe "control-plane System.cmd deadlines" do
    test "a hung systemd-run is force-killed: {:trigger} returns start_failed under the deadline" do
      dir = run_dir()

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        systemd_run_command: {slow_ctl_script(2, "ok"), []},
        is_active_cmd: {echo_script("inactive"), []},
        command: stub("exit 0"),
        ctl_cmd_timeout_ms: 400
      )

      pid = Process.whereis(DeployRunner)

      {us, reply} =
        :timer.tc(fn -> GenServer.call(pid, {:trigger, req("slow-spawn")}, 10_000) end)

      # Degraded return: a hung launch is a start failure, never a crash.
      assert reply == {:error, :start_failed}
      # Wall-clock cut: bounded ~400ms; unbounded would block ≥2s (the stub sleep).
      assert us < 1_500_000,
             "trigger took #{div(us, 1000)}ms — the systemd-run deadline did not fire (unbounded?)"
    end

    test "a hung systemctl is-active degrades to \"unknown\": {:status} finalizes :done under the deadline" do
      dir = run_dir()

      seed_manifest(dir, "slow-active",
        build_id: "b7",
        status:
          "BPSTAGE name=PLAN status=ok build_id=b7\nBPSTAGE name=BUILD status=started build_id=b7\n"
      )

      # init re-attach sees the unit ACTIVE ⇒ it stays :running in state.units.
      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        is_active_cmd: {echo_script("active"), []},
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        command: stub("exit 0")
      )

      pid = start_fresh_runner()
      assert %{state: :running} = GenServer.call(pid, {:status, "slow-active"})

      # Now the liveness probe HANGS; the next observe must not block the caller.
      put_cfg(is_active_cmd: {slow_ctl_script(2, "active"), []}, ctl_cmd_timeout_ms: 400)

      {us, status} =
        :timer.tc(fn -> GenServer.call(pid, {:status, "slow-active"}, 10_000) end)

      # Degraded: "unknown" is terminal ⇒ the run finalizes rather than pinning :running.
      assert status.state == :done

      assert us < 1_500_000,
             "status took #{div(us, 1000)}ms — the is-active deadline did not fire (unbounded?)"
    end

    test "a hung systemctl stop is force-killed: {:unit_deadline} still finalizes :done/-2 under the deadline" do
      dir = run_dir()

      seed_manifest(dir, "slow-stop",
        build_id: "b4",
        status: "BPSTAGE name=BUILD status=started build_id=b4\n"
      )

      put_cfg(
        enabled: true,
        runner_mode: :systemd,
        run_state_dir: dir,
        is_active_cmd: {echo_script("active"), []},
        systemctl_stop_cmd: {slow_ctl_script(2, "stopped"), []},
        systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
        command: stub("exit 0"),
        ctl_cmd_timeout_ms: 400
      )

      pid = start_fresh_runner()
      assert %{state: :running} = GenServer.call(pid, {:status, "slow-stop"})

      # Fire the watchdog; its `systemctl stop` HANGS. A call queued behind the
      # handle_info measures its wall-clock (GenServer messages are serial).
      send(pid, {:unit_deadline, "slow-stop"})

      {us, status} =
        :timer.tc(fn -> GenServer.call(pid, {:status, "slow-stop"}, 10_000) end)

      # The watchdog finalizes regardless — the deadline only bounds HOW LONG.
      assert status.state == :done
      assert status.exit_code == -2

      assert us < 1_500_000,
             "unit_deadline finalize took #{div(us, 1000)}ms — the systemctl stop deadline did not fire (unbounded?)"
    end
  end

  # ── the durable per-BUILD record (deploy-reliability D21/D22/D23) ─────────
  #
  # The run-state files used to be keyed on the SLUG alone and truncated at
  # every launch, so deploy #2 of a slug destroyed deploy #1's build log —
  # observed live: 33,227 bytes at 23:36, 0 bytes at 23:39, across 25
  # consecutive failures of one site. These tests pin the three things that make
  # it honest: build-keyed paths, bounded retention, and an EVICTED deployment
  # reading back differently from one that never happened.

  # An engine that writes its own build_id into the durable log + a terminal
  # stage, so a log's BYTES identify which build wrote them.
  defp recording_engine do
    stub("""
    echo "build output for $BUILD_ID" >> "$BARKPARK_SITE_LOG_FILE"
    echo "BPSTAGE name=SWITCH status=ok build_id=$BUILD_ID" >> "$BARKPARK_SITE_STATUS_FILE"
    exit 0
    """)
  end

  defp recorder_cfg(dir, overrides \\ []) do
    put_cfg(
      Keyword.merge(
        [
          enabled: true,
          runner_mode: :systemd,
          run_state_dir: dir,
          systemd_run_command: {fake_systemd_run(Path.join(dir, "argv.dump")), []},
          is_active_cmd: {echo_script("inactive"), []},
          command: recording_engine()
        ],
        overrides
      )
    )
  end

  # Launch a build and drive it to its terminal record (is-active reports the
  # unit gone, so the first status/1 finalizes it).
  defp deploy_and_finalize(slug, build_id) do
    assert DeployRunner.trigger(req(slug, build_id: build_id)) == {:ok, :started}
    assert %{state: :done} = DeployRunner.status(slug)
  end

  describe "the durable build log is keyed on the BUILD" do
    test "a second build of the same slug does NOT destroy the first one's log" do
      dir = run_dir()
      recorder_cfg(dir)

      deploy_and_finalize("twicebuilt", "aaa")
      first_log = Path.join(dir, "twicebuilt-aaa.log")
      assert File.read!(first_log) =~ "build output for aaa"
      first_bytes = File.stat!(first_log).size
      assert first_bytes > 0

      deploy_and_finalize("twicebuilt", "bbb")

      # THE BUG: with a `<slug>.log` path this file was 0 bytes here.
      assert File.stat!(first_log).size == first_bytes
      assert File.read!(first_log) =~ "build output for aaa"
      assert File.read!(Path.join(dir, "twicebuilt-bbb.log")) =~ "build output for bbb"

      # …and each deployment is addressable BY ID, not merely present on disk.
      assert %{record: :terminal, log_state: :available, exit_code: 0} =
               first = DeployRunner.build_record("twicebuilt", "aaa")

      assert first.build_id == "aaa"
      assert first.log_path == first_log

      assert %{record: :terminal, build_id: "bbb", log_state: :available} =
               DeployRunner.build_record("twicebuilt", "bbb")
    end

    test "a rollback names no build and still cannot clobber a sibling's log" do
      dir = run_dir()

      recorder_cfg(dir,
        rollback_command:
          stub("""
          echo 'ROLLED BACK' >> "$BARKPARK_SITE_LOG_FILE"
          exit 0
          """)
      )

      deploy_and_finalize("rbkeyed", "d1")
      deploy_log = Path.join(dir, "rbkeyed-d1.log")
      assert File.read!(deploy_log) =~ "build output for d1"

      assert DeployRunner.trigger(req("rbkeyed", mode: "rollback")) == {:ok, :started}
      assert %{state: :done, exit_code: 0} = DeployRunner.status("rbkeyed")

      # The deploy's log survived the rollback that followed it.
      assert File.read!(deploy_log) =~ "build output for d1"
      rollback_logs = dir |> File.ls!() |> Enum.filter(&(&1 =~ ~r/\Arbkeyed-rollback-\d+\.log\z/))
      assert length(rollback_logs) == 1
    end

    test "the terminal record carries the EXACT unit name, so journald is addressable by name" do
      dir = run_dir()
      recorder_cfg(dir)

      deploy_and_finalize("unitrec", "u1")
      record = DeployRunner.build_record("unitrec", "u1")

      assert record.unit_name =~ ~r/\Abp-site-build-unitrec-u1-\d+\.service\z/
      # An EXACT -u query (measured 0.16s), never a glob (measured 121s).
      assert record.journal_command == "journalctl --no-pager -u #{record.unit_name}"
      refute record.journal_command =~ "*"
    end
  end

  describe "build-log retention (bytes AND count AND age)" do
    test "the COUNT cap bites, and the effective bound is reported" do
      dir = run_dir()
      recorder_cfg(dir)

      for id <- ~w(c1 c2 c3), do: deploy_and_finalize("capcount", id)

      # Tighten the cap AFTER the builds — a sweep also runs at every launch, so
      # a cap set up front would have evicted as it went and left this sweep
      # nothing to do (which is correct behaviour, and a vacuous assertion).
      put_cfg(max_build_logs: 1, max_build_log_bytes: 1_000_000_000)
      report = DeployRunner.retention_sweep()

      assert report.bound == :count
      assert report.evicted_by.count >= 2
      assert report.evicted_by.age == 0
      assert report.evicted_by.bytes == 0
      assert report.kept == 1
      assert report.caps.max_logs == 1
      assert length(Enum.filter(File.ls!(dir), &String.ends_with?(&1, ".log"))) == 1
    end

    test "the AGE cap bites independently of count and bytes" do
      dir = run_dir()
      recorder_cfg(dir, max_build_log_age_ms: 60_000, max_build_logs: 500)

      deploy_and_finalize("capage", "old1")
      deploy_and_finalize("capage", "new1")

      # Backdate ONE log an hour — count and bytes are nowhere near their caps,
      # so only age can condemn it.
      old_log = Path.join(dir, "capage-old1.log")
      File.touch!(old_log, System.os_time(:second) - 3_600)

      report = DeployRunner.retention_sweep()

      assert report.bound == :age
      assert report.evicted_by.age == 1
      assert report.evicted_by.count == 0
      assert report.evicted_by.bytes == 0
      refute File.exists?(old_log)
      assert File.exists?(Path.join(dir, "capage-new1.log"))
    end

    test "the BYTES cap bites independently, and the newest log is never the one evicted" do
      dir = run_dir()
      recorder_cfg(dir)

      for id <- ~w(b1 b2 b3), do: deploy_and_finalize("capbytes", id)

      # Age the two older logs apart EXPLICITLY. mtime has one-second resolution,
      # and three builds this cheap all finish inside the same second on a fast
      # box — which left "the newest" undefined and made this assertion depend on
      # directory order (it passed on a slow laptop and failed on CI). Spreading
      # the mtimes is what makes b3 provably the newest, so the survivor below
      # tests the recency rule rather than a tie-break. Still far inside the age
      # cap (7 days), so age condemns nothing.
      now = System.os_time(:second)
      File.touch!(Path.join(dir, "capbytes-b1.log"), now - 120)
      File.touch!(Path.join(dir, "capbytes-b2.log"), now - 60)
      File.touch!(Path.join(dir, "capbytes-b3.log"), now)

      # 1 byte: every log is over budget, so only the always-keep-the-newest rule
      # decides what survives. Applied after the builds (see the count test).
      put_cfg(max_build_log_bytes: 1, max_build_logs: 500)
      report = DeployRunner.retention_sweep()

      assert report.bound == :bytes
      assert report.evicted_by.bytes == 2
      assert report.evicted_by.count == 0
      assert report.evicted_by.age == 0
      # A bound that deletes the build you are reading is not a bound.
      assert report.kept == 1
      assert File.exists?(Path.join(dir, "capbytes-b3.log"))
    end

    test "logs that tie on mtime are evicted deterministically, not in directory order" do
      dir = run_dir()
      recorder_cfg(dir)

      for id <- ~w(t1 t2 t3), do: deploy_and_finalize("captie", id)

      # The case the filesystem cannot resolve: three logs stamped the SAME
      # second. Nothing on disk says which build finished last, so the sweep may
      # not consult `File.ls/1`'s arbitrary order to decide — that would let the
      # OS choose which build silently loses its log, and make two sweeps of an
      # identical directory disagree. The tie-break is the path, descending.
      same_second = System.os_time(:second)
      for id <- ~w(t1 t2 t3), do: File.touch!(Path.join(dir, "captie-#{id}.log"), same_second)

      put_cfg(max_build_log_bytes: 1, max_build_logs: 500)
      report = DeployRunner.retention_sweep()

      assert report.bound == :bytes
      assert report.evicted_by.bytes == 2
      assert report.kept == 1
      assert File.exists?(Path.join(dir, "captie-t3.log"))
      refute File.exists?(Path.join(dir, "captie-t1.log"))
      refute File.exists?(Path.join(dir, "captie-t2.log"))
    end

    test "terminal RECORDS that tie on mtime are pruned deterministically too" do
      dir = run_dir()
      recorder_cfg(dir)

      for id <- ~w(r1 r2 r3), do: deploy_and_finalize("recordtie", id)

      # The tombstones carry the SAME one-second mtime hazard as the logs, and
      # losing one is worse: a deployment whose terminal record is gone reads as
      # `:never_recorded` rather than `:evicted` — the exact dishonesty this PR
      # exists to end. Keep exactly one and pin WHICH one, so the assertion is
      # structurally able to catch directory order deciding it.
      same_second = System.os_time(:second)

      for id <- ~w(r1 r2 r3),
          do: File.touch!(Path.join(dir, "recordtie-#{id}.terminal.json"), same_second)

      put_cfg(max_terminal_records: 1)
      DeployRunner.retention_sweep()

      assert File.exists?(Path.join(dir, "recordtie-r3.terminal.json"))
      refute File.exists?(Path.join(dir, "recordtie-r1.terminal.json"))
      refute File.exists?(Path.join(dir, "recordtie-r2.terminal.json"))
    end

    test "a log whose unit is STILL RUNNING is never evicted" do
      dir = run_dir()
      recorder_cfg(dir, is_active_cmd: {active_only_for("liverun"), []}, max_build_logs: 0)

      assert DeployRunner.trigger(req("liverun", build_id: "l1")) == {:ok, :started}
      assert %{state: :running} = DeployRunner.status("liverun")

      report = DeployRunner.retention_sweep()

      assert report.protected == 1
      assert report.evicted == 0
      assert File.exists?(Path.join(dir, "liverun-l1.log"))
    end
  end

  describe "eviction is a DIFFERENT answer from 'never recorded'" do
    test "an evicted deployment keeps its outcome; a never-deployed one has none" do
      dir = run_dir()
      recorder_cfg(dir)

      deploy_and_finalize("evictme", "e1")
      log = Path.join(dir, "evictme-e1.log")
      assert File.exists?(log)

      # BEFORE: the log is there and the read says so.
      before_evict = DeployRunner.build_record("evictme", "e1")
      assert before_evict.log_state == :available

      # Drive PAST the count cap — the eviction branch has never run in prod
      # (@max_tracked_runs counts SLUGS, and this box has 16), so it is proven
      # here by forcing it, not by reading it.
      put_cfg(max_build_logs: 0)
      assert %{evicted: 1} = DeployRunner.retention_sweep()
      refute File.exists?(log)

      evicted = DeployRunner.build_record("evictme", "e1")
      never = DeployRunner.build_record("never-deployed-at-all", "zzz")

      # AFTER: different answers where there used to be one.
      assert evicted.log_state == :evicted
      assert never.log_state == :never_recorded
      refute evicted == never

      # The evicted one still knows WHAT HAPPENED — that is the whole point of a
      # tombstone written at finalize rather than at prune time.
      assert evicted.record == :terminal
      assert evicted.exit_code == 0
      assert evicted.unit_name =~ "bp-site-build-evictme-e1-"
      assert evicted.journal_command =~ "journalctl"
      assert evicted.evicted_at != nil

      # …and the never-deployed one honestly knows nothing.
      assert never.record == :none
      assert never.exit_code == nil
      assert never.unit_name == nil
    end

    test "status/1 stops reporting an evicted deployment as :idle" do
      dir = run_dir()
      recorder_cfg(dir)

      deploy_and_finalize("statusevict", "s1")

      # Lose the slug-keyed manifest (the manifest cap, or a newer run
      # overwriting it) AND the log.
      File.rm!(Path.join(dir, "statusevict.manifest.json"))
      put_cfg(max_build_logs: 0)
      assert %{evicted: 1} = DeployRunner.retention_sweep()

      evicted = DeployRunner.status("statusevict")
      never = DeployRunner.status("never-deployed-at-all")

      # This pair used to be identical apart from the slug.
      assert evicted.state == :done
      assert evicted.exit_code == 0
      assert evicted.log_state == :evicted
      assert evicted.unit_name =~ "bp-site-build-statusevict-s1-"

      assert never.state == :idle
      assert never.log_state == :never_recorded
      assert never.unit_name == nil
    end

    test "a log evicted before its run finalized is still not 'never recorded'" do
      dir = run_dir()
      recorder_cfg(dir)

      # A log from a run that never reached finalize (the BEAM died, the unit
      # vanished): bytes on disk, no terminal record.
      File.write!(Path.join(dir, "orphanlog-o1.log"), "partial output\n")
      refute File.exists?(Path.join(dir, "orphanlog-o1.terminal.json"))

      put_cfg(max_build_logs: 0)

      assert %{evicted: 1} = DeployRunner.retention_sweep()

      record = DeployRunner.build_record("orphanlog", "o1")
      assert record.log_state == :evicted
      assert record.exit_code == nil
      assert record.failure_reason =~ "evicted by retention before this run was finalized"
    end
  end

  # ── retention ordering, observed APART from the filesystem ────────────────
  #
  # The integration tests above stamp real tombstones and let `File.ls/1` order
  # them. That proves the sweep on THIS host's directory order — and one host's
  # order can happen to agree with the intended answer, which is exactly how the
  # log-side tie bug passed locally and failed on CI. These tests hand the
  # ordering its entries DIRECTLY, in every permutation, so the tie-break is
  # pinned on any host: collapse it to a bare mtime sort and the stable sort
  # falls through to the input order, which here DISAGREES with the answer.

  @tie_second 1_770_000_000

  defp tie_entry(name, ts \\ @tie_second),
    do: %{path: "/run/state/#{name}", size: 100, mtime: DateTime.from_unix!(ts)}

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(h <- list, t <- permutations(list -- [h]), do: [h | t])

  describe "retention eviction order is TOTAL, not the directory's" do
    @tying_records ~w(
      recordtie-r1.terminal.json
      recordtie-r2.terminal.json
      recordtie-r3.terminal.json
    )

    test "tombstones tying on mtime condemn the SAME two from every input order" do
      for order <- permutations(@tying_records) do
        evicted =
          order
          |> Enum.map(&tie_entry/1)
          |> DeployRunner.terminal_records_to_evict(1)
          |> Enum.map(&Path.basename(&1.path))

        assert evicted == ~w(recordtie-r2.terminal.json recordtie-r1.terminal.json),
               "input order #{inspect(order)} changed which tombstones the sweep condemned — " <>
                 "the eviction is following the listing, not a total order"
      end
    end

    test "the survivor of a tie is the same record however the directory listed them" do
      for order <- permutations(@tying_records) do
        kept = order |> Enum.map(&tie_entry/1) |> DeployRunner.order_newest_first() |> hd()

        assert Path.basename(kept.path) == "recordtie-r3.terminal.json",
               "input order #{inspect(order)} decided the survivor"
      end
    end

    test "mtime still decides when it differs — the path is a TIE-break, not a recency claim" do
      entries = [
        tie_entry("aaa-newest.terminal.json", @tie_second + 60),
        tie_entry("zzz-oldest.terminal.json", @tie_second)
      ]

      for order <- permutations(entries) do
        assert order |> DeployRunner.order_newest_first() |> Enum.map(&Path.basename(&1.path)) ==
                 ~w(aaa-newest.terminal.json zzz-oldest.terminal.json)
      end
    end
  end

  # ── the run-state dir census (dr-w23) ─────────────────────────────────────

  # A manifest planted BY HAND, so a sweep can be driven without 33 real builds
  # and so a manifest can name paths a real launch would never write (the whole
  # point of the containment test below). Fields mirror `encode_manifest/1`.
  defp plant_manifest(dir, slug, started_at, overrides \\ %{}) do
    payload =
      Map.merge(
        %{
          "slug" => slug,
          "run_tag" => "#{slug}-t1",
          "build_id" => "t1",
          "content_rev" => nil,
          "mode" => "deploy",
          "runtime_target" => "static",
          "unit_name" => "bp-site-build-#{slug}-t1-1.service",
          "status_file" => Path.join(dir, "#{slug}-t1.status"),
          "log_file" => Path.join(dir, "#{slug}-t1.log"),
          "build_env_file" => Path.join(dir, "#{slug}-t1.env"),
          "prebuilt_dir" => nil,
          "prebuilt_sha256" => nil,
          "started_at" => DateTime.to_iso8601(started_at)
        },
        overrides
      )

    File.write!(Path.join(dir, "#{slug}.manifest.json"), Jason.encode!(payload))
  end

  # @max_tracked_runs is 32 and the sweep only fires ABOVE it, so fill the dir
  # past the cap with manifests NEWER than the one under test — that makes the
  # one under test the eviction candidate. The fillers must still be OLDER than
  # `now`: the launch that DRIVES the sweep writes its own manifest at `now`,
  # and fillers dated into the FUTURE evict the very run driving the sweep —
  # which is how this helper first read as a passing containment test while the
  # drive's own quartet was the thing being deleted.
  defp fill_past_manifest_cap(dir, count \\ 34) do
    now = DateTime.utc_now()

    for i <- 1..count,
        do: plant_manifest(dir, "filler#{i}", DateTime.add(now, -60 - i, :second))
  end

  defp terminal_names(dir),
    do: dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".terminal.json")) |> Enum.sort()

  describe "every record in the run-state dir is swept with a stated bound (dr-w23)" do
    test "the 10,000-record cap is the REAL default, so the overridden one is a stand-in" do
      recorder_cfg(run_dir())

      assert DeployRunner.retention_caps().max_terminal_records == 10_000
    end

    test "the terminal-record cap prunes to the cap, keeps the NEWEST, and spares other names" do
      dir = run_dir()
      # 5, not 10_000: seeding the real cap means 10,001 real files. The cap is
      # read from config by the same expression prod reads, and the test above
      # pins the production default — so the path under test is the prod path.
      recorder_cfg(dir, max_terminal_records: 5)

      base = System.os_time(:second) - 10_000

      for i <- 1..12 do
        path = Path.join(dir, "census-r#{String.pad_leading("#{i}", 2, "0")}.terminal.json")
        File.write!(path, Jason.encode!(%{"slug" => "census", "run_tag" => "r#{i}"}))
        # Distinct mtimes: higher i is NEWER, so r08..r12 must survive.
        File.touch!(path, base + i)
      end

      # Names the record sweep must NOT touch: a different suffix, the
      # fixed-name serving-memory record, and a near-miss suffix.
      decoys = ~w(keepme.txt serving-memory.json census-r03.terminal.json.bak)
      for name <- decoys, do: File.write!(Path.join(dir, name), "keep me")

      report = DeployRunner.retention_sweep()

      assert report.caps.max_terminal_records == 5

      assert terminal_names(dir) == ~w(
               census-r08.terminal.json
               census-r09.terminal.json
               census-r10.terminal.json
               census-r11.terminal.json
               census-r12.terminal.json
             )

      for name <- decoys,
          do: assert(File.exists?(Path.join(dir, name)), "the sweep took #{name}")
    end

    test "a .status/.env/.prebuilt no manifest names any more is swept (it was unbounded)" do
      dir = run_dir()
      recorder_cfg(dir)

      # The orphan class: the manifest is slug-keyed and the files are
      # tag-keyed, so a REDEPLOY overwrites the only pointer to the previous
      # run's status/env — before this sweep nothing could name them again.
      orphans = ~w(gone-t1.status gone-t1.env)
      for name <- orphans, do: File.write!(Path.join(dir, name), "stranded")

      staging = Path.join(dir, "gone.prebuilt.staging-7")
      stale_tree = Path.join(dir, "gone.prebuilt")
      for d <- [staging, stale_tree], do: File.mkdir_p!(d)
      for d <- [staging, stale_tree], do: File.write!(Path.join(d, "index.html"), "<html>")

      # A run whose manifest DOES name its status file must survive the sweep
      # even when it is just as old — age is not what condemns an orphan.
      deploy_and_finalize("orphankeep", "k1")
      kept_status = Path.join(dir, "orphankeep-k1.status")
      assert File.exists?(kept_status)

      old = System.os_time(:second) - 7200

      for path <- [kept_status, staging, stale_tree | Enum.map(orphans, &Path.join(dir, &1))],
          do: File.touch!(path, old)

      # Inside the grace window: a launch writes its files BEFORE the manifest
      # that names them, so a fresh unreferenced file is not yet an orphan.
      fresh = Path.join(dir, "toonew-t9.status")
      File.write!(fresh, "in flight")

      assert %{orphans: 4} = DeployRunner.retention_sweep()

      for name <- orphans, do: refute(File.exists?(Path.join(dir, name)))
      refute File.exists?(staging)
      refute File.exists?(stale_tree)
      assert File.exists?(kept_status)
      assert File.exists?(fresh)
    end

    test "a record placed inside <slug>.prebuilt dies with the slug when the quartet is evicted" do
      dir = run_dir()
      recorder_cfg(dir)

      tree = Path.join(dir, "evicted.prebuilt")
      File.mkdir_p!(tree)
      inner = Path.join(tree, "note.json")
      File.write!(inner, ~s({"a":1}))

      status = Path.join(dir, "evicted-t1.status")
      File.write!(status, "BPSTAGE name=SWITCH status=ok build_id=t1")

      # Oldest of the lot, and the ONLY one naming a prebuilt tree.
      plant_manifest(dir, "evicted", DateTime.add(DateTime.utc_now(), -86_400, :second), %{
        "prebuilt_dir" => tree
      })

      fill_past_manifest_cap(dir)

      # The quartet sweep runs at LAUNCH — so drive a real launch.
      deploy_and_finalize("censusdrive", "d1")

      refute File.exists?(Path.join(dir, "evicted.manifest.json"))
      refute File.exists?(status)
      refute File.exists?(tree), "the staged tree survived its slug's eviction"

      refute File.exists?(inner),
             "a per-slug record inside <slug>.prebuilt survived the rm_rf — anything sited " <>
               "there is deleted WITH the slug, so nothing may rely on it"
    end

    test "a manifest naming a path OUTSIDE the run-state dir is refused, not followed" do
      dir = run_dir()
      recorder_cfg(dir)

      outside = Path.join(System.tmp_dir!(), "bp-dr-decoy-#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)

      decoy_status = Path.join(outside, "precious.status")
      decoy_log = Path.join(outside, "precious.log")
      decoy_env = Path.join(outside, "precious.env")
      decoy_tree = Path.join(outside, "precious.prebuilt")
      File.mkdir_p!(decoy_tree)
      for f <- [decoy_status, decoy_log, decoy_env], do: File.write!(f, "not yours")
      File.write!(Path.join(decoy_tree, "keep"), "not yours")

      plant_manifest(dir, "planted", DateTime.add(DateTime.utc_now(), -86_400, :second), %{
        "status_file" => decoy_status,
        "log_file" => decoy_log,
        "build_env_file" => decoy_env,
        "prebuilt_dir" => decoy_tree
      })

      fill_past_manifest_cap(dir)

      log = capture_log(fn -> deploy_and_finalize("censusdrive2", "d2") end)

      # NON-VACUITY: the sweep really did evict this manifest — so the decoys
      # surviving is containment, not a sweep that never ran.
      refute File.exists?(Path.join(dir, "planted.manifest.json"))
      assert log =~ "refused to follow"

      for f <- [decoy_status, decoy_log, decoy_env], do: assert(File.exists?(f))
      assert File.exists?(Path.join(decoy_tree, "keep"))
    end
  end
end
