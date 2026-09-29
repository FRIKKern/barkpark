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
  alias BarkparkCloud.Health.ServingMemory
  alias BarkparkCloud.Web.Router

  @env "BARKPARK_GIT_SHA"
  @prov_env "BARKPARK_PROVISIONER_SHA"
  @router_opts Router.init([])

  setup do
    previous = System.get_env(@env)
    previous_prov = System.get_env(@prov_env)
    System.delete_env(@env)
    # Both env vars are OS-global and this file injects both. A leaked
    # provisioner sha would let one test answer another's read, so it is saved
    # and restored exactly like the app sha.
    System.delete_env(@prov_env)
    # serving_since is now durable and memoised per BEAM; drop this node's
    # sightings so one test's sha cannot answer another's read.
    ServingMemory.forget()

    on_exit(fn ->
      ServingMemory.forget()
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)

      if previous_prov,
        do: System.put_env(@prov_env, previous_prov),
        else: System.delete_env(@prov_env)
    end)

    :ok
  end

  # A sighting of `sha` as a deploy that happened before this BEAM existed.
  defp backdate!(sha, hours) do
    at = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)

    Repo.insert_all("serving_memories", [%{sha: sha, first_seen_at: at}],
      on_conflict: :nothing,
      conflict_target: :sha
    )

    at
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

  describe "serving_since (durable — clk-bl-cloud-health-serving-since-is-boot-local)" do
    # It USED to be VM-derived, and the test that stood here asserted exactly
    # that. A gauge a bare `docker restart` improves is the defect, not the
    # contract, so the assertion is inverted: the value must be OLDER than this
    # BEAM, which nothing computed from :erlang.system_info(:start_time) can be.
    test "predates this BEAM — it comes from the record, not from the VM's uptime" do
      sha = "ddddddd4444444444444444444444444444dddd"
      deployed_at = backdate!(sha, 4)
      System.put_env(@env, sha)

      serving = Health.serving()

      assert serving.serving_since == deployed_at

      assert DateTime.compare(serving.serving_since, serving.process_since) == :lt,
             "serving_since is not older than process_since — it is still boot-local"
    end

    test "a restart does not move it: same record, new BEAM, same instant" do
      sha = "dddddda4444444444444444444444444444dddd"
      System.put_env(@env, sha)

      before_restart = ok_body().serving_since
      assert %DateTime{} = before_restart

      # What a real restart does for free: this node forgets its sightings and
      # has nothing left but the durable record.
      ServingMemory.forget()

      assert ok_body().serving_since == before_restart
    end

    test "no sha means no clock — serving_sha and serving_since are nil together" do
      serving = Health.serving()

      assert Map.fetch!(serving, :serving_sha) == nil
      assert Map.fetch!(serving, :serving_since) == nil
      # process_since is unaffected: it never needed a sha.
      assert %DateTime{} = serving.process_since
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

    test "process_since and serving_since are both on the wire, and they are DIFFERENT clocks" do
      sha = "2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbb2222"
      deployed_at = backdate!(sha, 6)
      System.put_env(@env, sha)

      body = health_body()

      assert {:ok, %DateTime{} = process_since, _} =
               DateTime.from_iso8601(Map.fetch!(body, "process_since"))

      assert {:ok, %DateTime{} = serving_since, _} =
               DateTime.from_iso8601(Map.fetch!(body, "serving_since"))

      # They were the SAME value before this fix, which is precisely why a
      # deploy-lag reading taken against serving_since shrank on every restart.
      assert DateTime.compare(serving_since, deployed_at) == :eq
      assert DateTime.compare(serving_since, process_since) == :lt
      refute body["process_since"] == body["serving_since"]
    end

    test "serving_since ships a basis string naming WHICH state produced it" do
      # THE GUARD. Drop the key from serving/0 and this reds: the wire loses the
      # only place that says whether serving_since is a durable record, an
      # unknown sha, or an unreachable store. Its wording must no longer confess
      # to being process-derived — that confession was the old defect's label.
      System.put_env(@env, "3333333ccccccccccccccccccccccccccc33333")

      basis = Map.fetch!(health_body(), "serving_since_basis")

      assert is_binary(basis) and basis != ""
      down = String.downcase(basis)
      assert down =~ "durable"
      assert down =~ "restart"
      refute down =~ "process-derived"
    end

    test "an unknown sha renders serving_sha and serving_since as JSON null, together" do
      body = health_body()

      assert Map.fetch!(body, "serving_sha") == nil
      assert Map.fetch!(body, "serving_since") == nil
      assert String.downcase(Map.fetch!(body, "serving_since_basis")) =~ "unknown"
      # process_since survives: it is boot-local on purpose and needs no sha.
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(Map.fetch!(body, "process_since"))
    end
  end

  describe "provisioner_sha (pdf-bl-cp-version-endpoint c1)" do
    # The app sha and the provisioner sha are TWO readings of TWO things. The
    # provisioner is cross-built on the runner at the run's headSha; the app is
    # `git pull --ff-only`-ed on the box and can land AHEAD of it under
    # back-to-back merges. Every assertion below pins an injected VALUE, never
    # presence: a reader that returned `git_sha` under a new key, or a hardcoded
    # constant, would pass a presence check and reds here.

    test "reports the INSTALLED binary's sha, and it is NOT the app sha" do
      System.put_env(@env, "1111111aaaaaaaaaaaaaaaaaaaaaaaaaaa11111")
      System.put_env(@prov_env, "2222222bbbbbbbbbbbbbbbbbbbbbbbbbbb22222")

      serving = Health.serving()

      assert serving.provisioner_sha == "2222222bbbbbbbbbbbbbbbbbbbbbbbbbbb22222"
      assert serving.git_sha == "1111111aaaaaaaaaaaaaaaaaaaaaaaaaaa11111"

      # THE DIVERGENCE. One "version" field could not express this state, and a
      # reader that fell back to the app sha would make the two agree by
      # construction — the exact inference this field exists to kill.
      refute serving.provisioner_sha == serving.git_sha
    end

    test "the RENDERED /health body carries it beside git_sha and serving_sha" do
      System.put_env(@env, "4444444ddddddddddddddddddddddddddd44444")
      System.put_env(@prov_env, "5555555eeeeeeeeeeeeeeeeeeeeeeeeeee55555")

      body = health_body()

      assert Map.fetch!(body, "provisioner_sha") == "5555555eeeeeeeeeeeeeeeeeeeeeeeeeee55555"
      assert Map.fetch!(body, "git_sha") == "4444444ddddddddddddddddddddddddddd44444"
      assert Map.fetch!(body, "serving_sha") == "4444444ddddddddddddddddddddddddddd44444"
    end

    test "it READS — a changed env changes the answer within one VM" do
      System.put_env(@prov_env, "6666666ffffffffffffffffffffffffff666666")
      assert ok_body().provisioner_sha == "6666666ffffffffffffffffffffffffff666666"

      System.put_env(@prov_env, "7777777aaaaaaaaaaaaaaaaaaaaaaaaaaa77777")
      assert ok_body().provisioner_sha == "7777777aaaaaaaaaaaaaaaaaaaaaaaaaaa77777"
    end

    # ── THE ABSENT CASE, both of its shapes ────────────────────────────────
    # This is the decision the implementation had to make, so it is tested
    # rather than assumed. Map.fetch! (not Map.get) throughout: dropping the key
    # REDS with a KeyError instead of quietly reading as nil.

    test "UNSET is nil — a CP older than the deploy-side capture answers honestly" do
      # A control plane deployed before cp-deploy.sh grew the capture block, or
      # any local run, never sees this var at all.
      System.put_env(@env, "8888888bbbbbbbbbbbbbbbbbbbbbbbbbbb88888")

      assert Map.fetch!(Health.serving(), :provisioner_sha) == nil
      assert Map.fetch!(health_body(), "provisioner_sha") == nil

      # It declines rather than SUBSTITUTES: the app sha is right there and is
      # not borrowed. Reporting it would be a plausible, wrong answer.
      assert Health.serving().git_sha == "8888888bbbbbbbbbbbbbbbbbbbbbbbbbbb88888"
    end

    test "EMPTY is nil too — that is how deploy says the binary carried no stamp" do
      # cp-deploy.sh's contract is "strictly 40 lowercase hex OR EMPTY": it
      # exports "" when `bp-provisioner --version` gave nothing (a plain
      # `go build`, or a binary older than the flag). Republishing "" would put
      # a value-shaped non-answer on an anonymous surface.
      System.put_env(@prov_env, "")

      assert Map.fetch!(Health.serving(), :provisioner_sha) == nil
      assert Map.fetch!(health_body(), "provisioner_sha") == nil
    end

    test "whitespace-only is nil; a padded sha is the sha" do
      System.put_env(@prov_env, "   \n ")
      assert Map.fetch!(Health.serving(), :provisioner_sha) == nil

      System.put_env(@prov_env, " 9999999cccccccccccccccccccccccccc999999\n")
      assert Health.serving().provisioner_sha == "9999999cccccccccccccccccccccccccc999999"
    end

    test "a malformed value is shown RAW, not hidden as nil" do
      # Deliberate: cp-deploy.sh already validates and logs, so a non-sha
      # arriving here means something bypassed it. It is visibly not a sha and
      # cannot be mistaken for one; nil-ing it would hide the misconfiguration
      # behind the same answer an un-deployed box gives.
      System.put_env(@prov_env, "refs/heads/main")

      assert Health.serving().provisioner_sha == "refs/heads/main"
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
  alias BarkparkCloud.Health.ServingMemory

  @env "BARKPARK_GIT_SHA"
  @prov_env "BARKPARK_PROVISIONER_SHA"

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(BarkparkCloud.Repo, :manual)
    previous = System.get_env(@env)
    previous_prov = System.get_env(@prov_env)
    System.delete_env(@env)
    System.delete_env(@prov_env)
    ServingMemory.forget()

    on_exit(fn ->
      ServingMemory.forget()
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)

      if previous_prov,
        do: System.put_env(@prov_env, previous_prov),
        else: System.delete_env(@prov_env)
    end)

    :ok
  end

  test "the {:error, ...} arm carries the injected sha, and DECLINES to invent a serving_since" do
    System.put_env(@env, "9999999777777777777777777777777799999")

    assert {:error, body} = Health.health()
    assert body.db == :down
    assert body.git_sha == "9999999777777777777777777777777799999"

    # The sha is the whole reason this arm carries serving data at all, and it
    # is still here. serving_since is not: the durable record is IN the Postgres
    # that just failed, and the old fallback — this BEAM's boot instant — is the
    # very gauge a restart improves. Declining is the safe direction.
    assert Map.fetch!(body, :serving_since) == nil
    assert String.downcase(body.serving_since_basis) =~ "unavailable"
  end

  test "an unreachable store does not raise, and does not fall back to the boot clock" do
    System.put_env(@env, "8888888666666666666666666666666688888")

    assert {:error, body} = Health.health()

    assert %DateTime{} = body.process_since
    assert Map.fetch!(body, :serving_since) == nil
    refute body.serving_since == body.process_since
  end

  test "the DB-down arm states the PROVISIONER sha too — and still does not borrow the app sha" do
    # The provisioner sha is env-read, not DB-read, so a dead Postgres has no
    # excuse to drop it. This is the state you most want both clocks for.
    System.put_env(@env, "1010101aaaaaaaaaaaaaaaaaaaaaaaaaaa10101")
    System.put_env(@prov_env, "2020202bbbbbbbbbbbbbbbbbbbbbbbbbbb20202")

    assert {:error, body} = Health.health()
    assert body.db == :down
    assert body.provisioner_sha == "2020202bbbbbbbbbbbbbbbbbbbbbbbbbbb20202"
    refute body.provisioner_sha == body.git_sha
  end

  test "a DB-down box with NO provisioner env says nil on that arm too" do
    System.put_env(@env, "3030303cccccccccccccccccccccccccc303030")

    assert {:error, body} = Health.health()
    assert Map.fetch!(body, :provisioner_sha) == nil
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
