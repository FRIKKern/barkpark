defmodule Barkpark.Sites.DeployRunnerDoorVsUnitReviewTest do
  @moduledoc """
  INDEPENDENT REVIEW of the door-vs-unit race — dr-w3-s5 criterion 11, clause B.

  PR #9827's body claims the race is closed because "the census is inside one
  `handle_call`, so serialization is structural". That claim is TRUE and
  INSUFFICIENT. Serializing two *triggers* is not the same thing as serializing
  a trigger against a *unit*, and the door-vs-unit race is the second one.

  `box_at_capacity?/2` does not ask "did I already launch something?" — it asks
  `building_slugs/1`, which for the systemd path re-derives liveness by shelling
  out to `systemctl is-active <unit>` and counting only `@active_states`
  (`active`/`activating`/`reloading`). `systemd-run` REGISTERS-and-returns, so
  there is a documented beat in which a unit this BEAM itself just launched
  reports `inactive`. The module already knows about that beat — it is the
  entire reason `@spawn_grace_ms 3_000` exists, and `observe_unit/2` applies a
  grace for it. `building_slugs/1` applies NONE.

  During that beat the detached engine has also not yet reached
  `build_gate_acquire`, so nothing is in `/proc/locks` either, and the second
  opinion says "free" too. Both signals read free while a build is in flight,
  and the door admits.

  Why the shipped suite cannot see this: `config/test.exs:223` pins
  `runner_mode: :port`, and the door's own concurrency test inherits it. The
  Port path records `state: :running` into `state.runs` SYNCHRONOUSLY inside
  `open_port_and_record/2`, so `building_slugs/1` sees it with no external
  probe and the race genuinely cannot occur there. Every existing systemd-path
  test uses a `fake_systemd_run` that runs the engine SYNCHRONOUSLY ("the 'unit'
  simply completes before the call returns"), so no existing test ever has a
  live unit and a second trigger at the same time.

  These tests drive the SYSTEMD path with a launcher that is faithful to the
  real one: it registers, detaches the engine, and returns 0 immediately.
  """
  # async: false — mutates the singleton Runner + Application env.
  use ExUnit.Case, async: false

  alias Barkpark.Sites.DeployRequest
  alias Barkpark.Sites.DeployRunner
  alias Barkpark.Sites.Provisioner

  setup do
    base = Path.join(System.tmp_dir!(), "bp-dvu-#{System.unique_integer([:positive])}")
    sites = Path.join(base, "sites")
    template = Path.join(base, "template")
    File.mkdir_p!(template)
    File.write!(Path.join(template, "package.json"), ~s({"name":"stub"}))

    prior = Application.get_env(:barkpark, Provisioner)
    Application.put_env(:barkpark, Provisioner, sites_dir: sites, template_dir: template)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, Provisioner, prior),
        else: Application.delete_env(:barkpark, Provisioner)

      File.rm_rf(base)
    end)

    :ok
  end

  describe "the door-vs-unit race (dr-w3-s5 criterion 11, clause B)" do
    test "CONTROL: when systemd reports the launched unit ACTIVE, the door DOES refuse" do
      # The harness is capable of producing box_at_capacity on the systemd path.
      # Without this control, a green race test below would be indistinguishable
      # from plumbing that never reaches the door at all.
      dir = run_dir()

      put_cfg(
        enabled: true,
        run_state_dir: dir,
        runner_mode: :systemd,
        systemd_run_command: {detaching_systemd_run(), []},
        # `active_only_for/1`, not a blanket "active": on the singleton Runner an
        # always-active stub also lies about every OTHER slug's leftover unit,
        # which would refuse alpha itself and make this control vacuous.
        is_active_cmd: {active_only_for("dvu-ctl-alpha"), []},
        proc_locks_path: empty_locks_file(),
        command: stub("sleep 2; exit 0")
      )

      assert DeployRunner.trigger(req("dvu-ctl-alpha")) == {:ok, :started}
      assert DeployRunner.trigger(req("dvu-ctl-beta")) == {:error, :box_at_capacity}
    end

    test "RACE: a unit this BEAM just launched is INVISIBLE to the door, and a second deploy is admitted" do
      # `is_active` answering "inactive" is not a contrivance: it is the beat
      # `@spawn_grace_ms 3_000` and `observe_unit/2`'s grace comment both name
      # verbatim ("right after launch systemd may report `inactive` for a beat
      # before the unit goes active"). `building_slugs/1` has no such grace.
      dir = run_dir()

      put_cfg(
        enabled: true,
        run_state_dir: dir,
        runner_mode: :systemd,
        systemd_run_command: {detaching_systemd_run(), []},
        is_active_cmd: {echo_script("inactive"), []},
        proc_locks_path: empty_locks_file(),
        command: stub("sleep 2; exit 0")
      )

      assert DeployRunner.trigger(req("dvu-alpha")) == {:ok, :started}

      # The Runner tracks the unit: this is NOT "the launch failed".
      assert DeployRunner.status("dvu-alpha").state == :running

      # PINNED DEFECT. The criterion's contract is `{:error, :box_at_capacity}`.
      # On origin/main the box admits a SECOND concurrent build instead.
      # Flip this to a refusal the day `building_slugs/1` counts a tracked unit
      # inside its spawn grace — this assertion is the tripwire for that fix.
      assert DeployRunner.trigger(req("dvu-beta")) == {:ok, :started}
    end

    test "COST: the un-refused second deploy PAYS ingest_prebuilt — the exact D86/D87 cost the door exists to prevent" do
      dir = run_dir()
      {b64, sha} = prebuilt_artifact()

      put_cfg(
        enabled: true,
        run_state_dir: dir,
        runner_mode: :systemd,
        systemd_run_command: {detaching_systemd_run(), []},
        is_active_cmd: {echo_script("inactive"), []},
        proc_locks_path: empty_locks_file(),
        command: stub("sleep 2; exit 0")
      )

      assert DeployRunner.trigger(req("dvu-cost-alpha")) == {:ok, :started}

      assert DeployRunner.trigger(req("dvu-cost-beta", artifact_b64: b64, artifact_sha256: sha)) ==
               {:ok, :started}

      # Criterion 1 pins that a REFUSED deploy never extracts. This one was not
      # refused, so it extracted — the box paid for the deploy the door was
      # supposed to decline.
      assert File.exists?(Path.join(dir, "dvu-cost-beta.prebuilt"))
    end
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

  defp stub(script), do: {"bash", ["-c", script]}

  defp req(slug, opts \\ []) do
    params =
      %{"slug" => slug, "build_id" => "b1", "mode" => "deploy"}
      |> maybe_put("artifact_b64", Keyword.get(opts, :artifact_b64))
      |> maybe_put("artifact_sha256", Keyword.get(opts, :artifact_sha256))

    {:ok, request} = DeployRequest.new(params)
    request
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp prebuilt_artifact do
    tar = Path.join(System.tmp_dir!(), "bp-dvu-pb-#{System.unique_integer([:positive])}.tar.gz")
    on_exit(fn -> File.rm(tar) end)

    :ok =
      :erl_tar.create(String.to_charlist(tar), [{~c"index.html", "<h1>x</h1>"}], [:compressed])

    raw = File.read!(tar)
    {Base.encode64(raw), :sha256 |> :crypto.hash(raw) |> Base.encode16(case: :lower)}
  end

  defp write_script(body) do
    path = Path.join(System.tmp_dir!(), "bp-dvu-#{System.unique_integer([:positive])}.sh")
    File.write!(path, body)
    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp echo_script(word), do: write_script("#!/usr/bin/env bash\necho #{word}\n")

  # `systemctl is-active` that answers "active" for ONE slug's units and
  # "inactive" for everything else — the existing suite's helper, copied because
  # the singleton Runner carries units tracked by earlier tests.
  defp active_only_for(slug) do
    write_script("""
    #!/usr/bin/env bash
    case "$1" in
      bp-site-build-#{slug}-*) echo active ;;
      *) echo inactive ;;
    esac
    """)
  end

  # A `/proc/locks` body with no FLOCK entry for the build gate — faithful to
  # the window under test: the detached engine has not yet reached
  # `build_gate_acquire`, so the second opinion has nothing to see either.
  defp empty_locks_file do
    path = Path.join(System.tmp_dir!(), "bp-dvu-locks-#{System.unique_integer([:positive])}")
    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)
    path
  end

  # The FAITHFUL `systemd-run` stand-in. The module's own comment: "`systemd-run`
  # REGISTERS the transient unit and returns immediately — the build runs
  # detached". The existing suite's `fake_systemd_run` runs the engine
  # synchronously instead, which is why no existing test can hold a live unit
  # across a second trigger.
  defp detaching_systemd_run do
    write_script("""
    #!/usr/bin/env bash
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
    ( "${cmd[@]}" ) >/dev/null 2>&1 &
    exit 0
    """)
  end

  defp run_dir do
    dir = Path.join(System.tmp_dir!(), "bp-dvu-runstate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
