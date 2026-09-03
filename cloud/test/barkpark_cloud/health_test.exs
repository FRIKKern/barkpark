defmodule BarkparkCloud.HealthTest do
  @moduledoc """
  The serving-sha CLOCK on the control plane's own health probe (dr-w20-s1).

  barkpark.cloud could not say which commit it was running, so a deploy that
  silently did not take looked identical to one that did. `Health.serving/0`
  makes the box state its own sha, and health/0 merges it into BOTH arms.

  Every assertion here pins a VALUE this test injected — never mere presence.
  A presence-only assertion (`Map.has_key?`) would survive a reader that never
  reads (a hardcoded constant), which is exactly the regression this file
  exists to catch: `git_sha` is asserted equal to two DIFFERENT injected shas,
  and to `nil` (via `Map.fetch!`, so deleting the key REDS rather than passing).

  async: false — these tests mutate the OS environment, which is process-global.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test

  alias BarkparkCloud.Health
  alias BarkparkCloud.Web.Router

  @env "BARKPARK_GIT_SHA"
  @router_opts Router.init([])

  setup do
    previous = System.get_env(@env)
    System.delete_env(@env)

    on_exit(fn ->
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
    end)

    :ok
  end

  defp ok_body do
    assert {:ok, body} = Health.health()
    body
  end

  # The RENDERED /health bytes, decoded — what an operator actually sees.
  defp health_body do
    conn = Router.call(conn(:get, "/health"), @router_opts)
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  describe "serving/0 + health/0 git_sha" do
    test "reports the sha it was given" do
      System.put_env(@env, "aaaaaaa1111111111111111111111111111aaaa")

      assert Health.serving().git_sha == "aaaaaaa1111111111111111111111111111aaaa"
      assert ok_body().git_sha == "aaaaaaa1111111111111111111111111111aaaa"
    end

    test "reports a DIFFERENT sha when the env changes — it reads, it does not remember" do
      System.put_env(@env, "bbbbbbb2222222222222222222222222222bbbb")
      assert ok_body().git_sha == "bbbbbbb2222222222222222222222222222bbbb"

      # Same VM, new deploy value: the read is at CALL time, not compile time
      # and not boot time.
      System.put_env(@env, "ccccccc3333333333333333333333333333cccc")
      assert ok_body().git_sha == "ccccccc3333333333333333333333333333cccc"
    end

    test "ABSENT MEANS nil — never \"unknown\", never 0, never a raise" do
      # Map.fetch! (not Map.get): if the key is dropped from the map entirely
      # this REDS with a KeyError instead of quietly reading as nil.
      assert Map.fetch!(Health.serving(), :git_sha) == nil
      assert Map.fetch!(ok_body(), :git_sha) == nil
    end
  end

  describe "serving_since" do
    test "is VM-derived: it tracks the BEAM's own uptime, not any env value" do
      uptime_ms =
        System.convert_time_unit(
          :erlang.monotonic_time() - :erlang.system_info(:start_time),
          :native,
          :millisecond
        )

      independent = DateTime.add(DateTime.utc_now(), -uptime_ms, :millisecond)

      drift = DateTime.diff(Health.serving().serving_since, independent, :millisecond)
      assert abs(drift) < 2000, "serving_since drifted #{drift}ms from a recomputed VM uptime"
    end

    test "is a real DateTime on the ok arm and is not moved by the env" do
      System.put_env(@env, "ddddddd4444444444444444444444444444dddd")
      assert %DateTime{} = serving_since = ok_body().serving_since
      # In the past (the VM started before now) but within this VM's lifetime.
      assert DateTime.compare(serving_since, DateTime.utc_now()) == :lt
    end
  end

  describe "GET /health through the real Router (no router change needed)" do
    test "the wire body carries the injected sha and an ISO-8601 serving_since" do
      System.put_env(@env, "eeeeeee5555555555555555555555555555eeee")

      conn = Router.call(conn(:get, "/health"), @router_opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["db"] == "up"
      assert body["git_sha"] == "eeeeeee5555555555555555555555555555eeee"
      assert {:ok, %DateTime{}, _offset} = DateTime.from_iso8601(body["serving_since"])
    end

    test "/up carries it too — both aliases run the same send_health/1" do
      System.put_env(@env, "fffffff6666666666666666666666666666ffff")

      conn = Router.call(conn(:get, "/up"), @router_opts)

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["git_sha"] == "fffffff6666666666666666666666666666ffff"
    end
  end

  describe "D417 clock vocabulary, over the RENDERED /health bytes" do
    # Everything here decodes conn.resp_body — the bytes an operator actually
    # sees — never Health.serving/0's term. A key that never survives JSON
    # encoding must red HERE, not in a unit test that reads the map directly.
    test "serving_sha is git_sha — same source, same call, both keys on the wire" do
      System.put_env(@env, "1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaa1111")

      body = health_body()

      assert body["serving_sha"] == "1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaa1111"
      assert Map.fetch!(body, "serving_sha") == Map.fetch!(body, "git_sha")
    end

    test "serving_sha tracks git_sha into nil — an alias, not a second reader" do
      # No env: both must be nil, and both keys must still be PRESENT
      # (Map.fetch! reds on a dropped key instead of reading as nil).
      body = health_body()

      assert Map.fetch!(body, "serving_sha") == nil
      assert Map.fetch!(body, "git_sha") == nil
    end

    test "process_since is on the wire as ISO-8601, alongside serving_since" do
      System.put_env(@env, "2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbb2222")

      body = health_body()

      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(Map.fetch!(body, "process_since"))
      # No key was removed: serving_since is still there, still a timestamp.
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(Map.fetch!(body, "serving_since"))
      assert body["process_since"] == body["serving_since"]
    end

    test "serving_since ships a basis string that says it is process-derived and restart-improvable" do
      # THE GUARD. Delete @serving_since_basis (or drop the key from serving/0)
      # and this test reds: the wire loses the only place that admits a bare
      # restart makes the lag read smaller.
      basis = Map.fetch!(health_body(), "serving_since_basis")

      assert is_binary(basis) and basis != ""
      down = String.downcase(basis)
      assert down =~ "process-derived"
      assert down =~ "restart"
      assert down =~ "smaller"
    end
  end
end

defmodule BarkparkCloud.HealthErrorArmTest do
  @moduledoc """
  The DB-DOWN arm must ALSO state the sha — that is the state you most want a
  sha for: "the control plane is broken; is it even running the commit we
  think?".

  This module deliberately does NOT `use BarkparkCloud.DataCase`: with the Ecto
  sandbox in :manual mode and no checkout, `Repo.query!` raises a
  DBConnection.OwnershipError, which is exactly the rescue path health/0 takes
  when its Postgres is unreachable. async: false so it never overlaps a test
  that put the sandbox in shared mode.

  The setup re-asserts :manual mode rather than trusting test_helper.exs: an
  earlier async: false module leaves the pool in SHARED mode with an owner that
  has since exited, and a checkout against a dead shared owner **exits** instead
  of raising — which `rescue` does not catch, so the test failed on some seeds
  and passed on others. Pinning the mode makes the DB-down arm deterministic.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Health

  @env "BARKPARK_GIT_SHA"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(BarkparkCloud.Repo, :manual)
    previous = System.get_env(@env)
    System.delete_env(@env)

    on_exit(fn ->
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)
    end)

    :ok
  end

  test "the {:error, ...} arm carries the injected sha and serving_since" do
    System.put_env(@env, "9999999777777777777777777777777799999")

    assert {:error, body} = Health.health()
    assert body.db == :down
    assert body.git_sha == "9999999777777777777777777777777799999"
    assert %DateTime{} = body.serving_since
  end

  test "a DB-down box with no sha env says nil, honestly, instead of raising" do
    assert {:error, body} = Health.health()
    assert body.db == :down
    assert Map.fetch!(body, :git_sha) == nil
  end

  test "the 503 reason is a fixed category; the raw exception text goes to the log only" do
    # Two-sided fence: the raw message MUST reach the log (so an operator can
    # still diagnose) and MUST NOT reach the unauthenticated wire body.
    {result, log} = ExUnit.CaptureLog.with_log(fn -> Health.health() end)

    assert {:error, body} = result
    assert Map.fetch!(body, :reason) == "database_unavailable"

    [raw] = Regex.run(~r/SELECT 1 failed: (.+)/, log, capture: :all_but_first)
    assert raw =~ "cannot find ownership process"
    refute Jason.encode!(body) =~ String.slice(raw, 0, 40)
  end
end
