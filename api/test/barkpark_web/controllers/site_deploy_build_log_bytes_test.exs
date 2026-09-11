defmodule BarkparkWeb.SiteDeployBuildLogBytesTest do
  @moduledoc """
  `dr-bl-recorder-http-read-path` c1 — THE BYTES DOOR on the box, through the real
  controller pipeline: `GET /v1/admin/site-deploy?slug=…&build_id=…&record=1&bytes=1`.

  THE HOLE THIS PINS. #17624 folded the recorded log's bytes at WRITE and stamped
  `log_scrub` on the terminal record; #16847 gave the control plane the structured
  record. Between them the BYTES were still unreadable over HTTP, and the record
  door says so in its own comment: "a door that serves bytes MUST read that field
  and refuse a nil; nothing here does yet, so nothing here serves bytes." This is
  that door, and these are the three properties it owes:

    * the bytes come back BY DEPLOYMENT (build) ID, off the durable record, for a
      build the Runner has long forgotten;
    * `log_scrub: nil` — bytes that were NEVER FOLDED — is a distinguishable
      REFUSAL (422 `build_log_unscrubbed`), never a served log and never an
      absence;
    * the size policy: a log over the cap serves a bounded TAIL carrying an honest
      truncated marker, and the whole file never enters memory.

  Every fixture here is a PROGRAMMED RECORDED FAILURE written to a run-state dir —
  hermetic, no box, no network. Nothing asserts anything about production.
  """
  # async: false — mutates the DeployRunner singleton's Application env.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Sites.BuildLogScrub
  alias Barkpark.Sites.DeployRunner

  @admin_token "barkpark-test-build-log-bytes-admin"

  setup do
    {:ok, _} =
      Auth.create_token(@admin_token, "build-log-bytes-admin", "test", ["read", "write", "admin"])

    run_state = Path.join(System.tmp_dir!(), "bp-bytes-#{System.unique_integer([:positive])}")
    File.mkdir_p!(run_state)

    prior = Application.get_env(:barkpark, DeployRunner)

    Application.put_env(
      :barkpark,
      DeployRunner,
      Keyword.merge(prior || [], enabled: true, run_state_dir: run_state)
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, DeployRunner, prior),
        else: Application.delete_env(:barkpark, DeployRunner)

      File.rm_rf(run_state)
    end)

    {:ok, run_state: run_state}
  end

  defp admin_conn(conn), do: put_req_header(conn, "authorization", "Bearer " <> @admin_token)

  defp put_cfg(overrides) do
    prior = Application.get_env(:barkpark, DeployRunner)
    Application.put_env(:barkpark, DeployRunner, Keyword.merge(prior || [], overrides))
  end

  # A PROGRAMMED RECORDED FAILURE: a terminal record on disk beside its log,
  # exactly the pair `cache_and_cleanup/4` leaves behind for a build that died.
  # `log_scrub` defaults to the CURRENT pattern-set version, i.e. already folded.
  defp record_failure(run_state, slug, build_id, log_body, opts \\ []) do
    log = Keyword.get(opts, :log_file, Path.join(run_state, "#{slug}-#{build_id}.log"))
    if log_body, do: File.write!(log, log_body)

    record =
      %{
        "slug" => slug,
        "build_id" => build_id,
        "run_tag" => build_id,
        "log_file" => log,
        "log_bytes" => if(log_body, do: byte_size(log_body)),
        "log_scrub" => Keyword.get(opts, :log_scrub, BuildLogScrub.version()),
        "log_state" => Keyword.get(opts, :log_state, "available"),
        "evicted_at" => Keyword.get(opts, :evicted_at),
        "exit_code" => 12,
        "failure_reason" => "BUILD failed (exit 12)",
        "stages" => [%{"name" => "BUILD", "status" => "failed"}],
        "unit_name" => "bp-site-build-#{slug}.service",
        "started_at" => "2026-09-01T10:00:00Z",
        "finished_at" => "2026-09-01T10:04:00Z"
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    File.write!(Path.join(run_state, "#{slug}-#{build_id}.terminal.json"), Jason.encode!(record))
    log
  end

  # AN UNSCRUBBED RECORD THAT CANNOT BE HEALED — the only shape the refusal is
  # actually reachable through, and finding that out is what writing this test
  # taught. `build_record/2` FOLDS an unstamped record whose log is still
  # writable and re-stamps it, so a merely-unstamped fixture is SERVED (healed),
  # never refused. The refusal exists for the case the Runner's own moduledoc
  # names: "a fold that hit an IO error".
  #
  # Reproduced exactly: the log lives in a READ-ONLY DIRECTORY, so
  # `BuildLogScrub.do_scrub_file/1` cannot create the `<path>.scrub-N` temp it
  # renames over the original. The file itself stays readable — this is a record
  # whose bytes are right there, unfolded, and unfoldable.
  #
  # (Chmodding the LOG did NOT work and the reason is worth keeping: the scrub
  # writes a sibling temp and `rename(2)`s it into place, which a writable
  # directory permits whatever the file's own mode says. A control that does not
  # actually break the thing it names is not a control.)
  defp record_unhealable(run_state, slug, build_id, log_body) do
    ro_dir = Path.join(run_state, "ro-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ro_dir)
    log = Path.join(ro_dir, "#{slug}-#{build_id}.log")
    File.write!(log, log_body)
    File.chmod!(ro_dir, 0o555)
    on_exit(fn -> File.chmod(ro_dir, 0o755) end)

    record_failure(run_state, slug, build_id, nil, log_scrub: nil, log_file: log)
    log
  end

  defp get_bytes(conn, slug, build_id) do
    conn
    |> admin_conn()
    |> get("/v1/admin/site-deploy?slug=#{slug}&build_id=#{build_id}&record=1&bytes=1")
  end

  ## 1. c0 — the bytes are readable BY BUILD ID -------------------------------

  describe "the bytes come back for a recorded failure, keyed by build id" do
    # THE RED-BEFORE ARM. Without the `bytes=1` branch in `status/2`, this same
    # request answers the RECORD — a 200 with no `tail` key at all — so the
    # `is_binary(body["tail"])` assertion is what the door has to exist to
    # satisfy. Asserted as a POSITIVE FACT about the bytes (the log's own text is
    # in the response), not as the absence of an error.
    test "an operator reads THAT build's bytes off the durable record", %{
      conn: conn,
      run_state: rs
    } do
      record_failure(rs, "boom", "bld-1", "npm ERR! 401 Unauthorized\nBUILD failed\n")

      body = conn |> get_bytes("boom", "bld-1") |> json_response(200)

      assert body["log_state"] == "available"
      assert is_binary(body["tail"])
      assert body["tail"] =~ "npm ERR! 401 Unauthorized"
      assert body["truncated"] == false
      assert body["tail_bytes"] == byte_size(body["tail"])
      assert body["log_bytes"] == body["tail_bytes"]
      assert body["build_id"] == "bld-1"
      assert body["log_scrub"] == BuildLogScrub.version()
    end

    # THE KEY IS THE BUILD, NOT THE SLUG — the property the build_id keying exists
    # for. A LATER build on the same slug must not move what the older one reads.
    # Positive fact: the OLDER build's own text comes back and the newer one's
    # does not, which a "no error" assertion could never distinguish.
    test "a later build on the same slug does not change what the older one reads", %{
      conn: conn,
      run_state: rs
    } do
      record_failure(rs, "boom", "bld-old", "the OLD build failed at BUILD\n")
      record_failure(rs, "boom", "bld-new", "the NEW build failed at HEALTH\n")

      body = conn |> get_bytes("boom", "bld-old") |> json_response(200)

      assert body["build_id"] == "bld-old"
      assert body["tail"] =~ "the OLD build"
      refute body["tail"] =~ "the NEW build"
    end

    # The three no-bytes states stay THREE ANSWERS, inherited from the record
    # door. Asserted as ONE comparison of the sorted status list, so collapsing
    # any two compares equal and FAILS — three separate status assertions would
    # not catch that.
    test "evicted / never recorded / unscrubbed are three DIFFERENT statuses", %{
      conn: conn,
      run_state: rs
    } do
      record_failure(rs, "gone", "bld-e", nil,
        log_state: "evicted",
        evicted_at: "2026-09-02T04:00:00Z"
      )

      record_unhealable(rs, "raw", "bld-u", "BARKPARK_TOKEN=bppat_neverfolded\n")

      evicted = conn |> get_bytes("gone", "bld-e") |> Map.get(:status)
      never = conn |> get_bytes("nothing-here", "bld-x") |> Map.get(:status)
      unscrubbed = conn |> get_bytes("raw", "bld-u") |> Map.get(:status)

      assert Enum.sort([evicted, never, unscrubbed]) == [200, 410, 422]
    end

    test "evicted is 410 and names when retention took the bytes", %{conn: conn, run_state: rs} do
      record_failure(rs, "gone", "bld-e", nil,
        log_state: "evicted",
        evicted_at: "2026-09-02T04:00:00Z"
      )

      body = conn |> get_bytes("gone", "bld-e") |> json_response(410)

      assert body["error"]["code"] == "build_log_evicted"
      assert body["evicted_at"] == "2026-09-02T04:00:00Z"
      assert body["tail"] == nil
    end

    test "a build nobody recorded is a 200 with a null tail, not a 404", %{conn: conn} do
      body = conn |> get_bytes("never-built", "bld-x") |> json_response(200)

      assert body["log_state"] == "never_recorded"
      assert body["tail"] == nil
      assert body["truncated"] == false
    end

    # THE FLAG IS AN OPT-IN, BOTH HALVES. `bytes=1` WITHOUT `record=1` must not
    # change the live status contract BoxRelay polls, and `record=1` without
    # `bytes=1` must keep answering exactly the record it always did.
    test "neither flag alone serves bytes", %{conn: conn, run_state: rs} do
      record_failure(rs, "boom", "bld-1", "npm ERR! 401 Unauthorized\n")

      # BYTE-IDENTICAL, asserted against the response with NO new flag at all —
      # stronger than a status check, and it is the property BoxRelay's poll
      # depends on. (Both are the 404 `build_id_mismatch` this slug/build pair
      # earns from the LIVE door, which is exactly the contract that must not
      # move.)
      plain = conn |> admin_conn() |> get("/v1/admin/site-deploy?slug=boom&build_id=bld-1")

      flagged =
        conn |> admin_conn() |> get("/v1/admin/site-deploy?slug=boom&build_id=bld-1&bytes=1")

      assert flagged.status == plain.status
      assert flagged.resp_body == plain.resp_body
      refute flagged.resp_body =~ "tail"

      record =
        conn
        |> admin_conn()
        |> get("/v1/admin/site-deploy?slug=boom&build_id=bld-1&record=1")
        |> json_response(200)

      assert record["log_state"] == "available"
      refute Map.has_key?(record, "tail")
    end
  end

  ## 2. c1 — the REFUSAL ------------------------------------------------------

  describe "a record whose log_scrub is nil is REFUSED, never served" do
    # THE CRITERION. A record stamped with NO `log_scrub` means the bytes were
    # never folded through the secret scrubber, so they may still carry a
    # plaintext credential. The proof is positive on BOTH sides: the refusal is
    # its own status AND the token that is really in the file on disk is really
    # absent from the response.
    test "422 build_log_unscrubbed, and the unfolded bytes do not reach the wire", %{
      conn: conn,
      run_state: rs
    } do
      secret = "BARKPARK_TOKEN=bppat_thismustnevercrosstheboundary"
      log = record_unhealable(rs, "raw", "bld-u", secret <> "\n")

      # THE CONTROL: the bytes this test claims are withheld really are on disk,
      # and really are unfolded. Without this the refusal could be passing over
      # an empty file.
      assert File.read!(log) =~ "bppat_"

      resp = get_bytes(conn, "raw", "bld-u")
      body = json_response(resp, 422)

      assert body["error"]["code"] == "build_log_unscrubbed"
      assert body["log_scrub"] == nil
      assert body["tail"] == nil

      # A REFUSAL, NOT AN ABSENCE: the operator is told the log is there.
      assert body["log_state"] == "available"
      assert body["log_bytes"] > 0

      refute resp.resp_body =~ "bppat_"
      refute resp.resp_body =~ "BARKPARK_TOKEN=bppat"
    end

    # THE HEAL IS NOT DEFEATED BY THE REFUSAL. `build_record/2` folds and
    # re-stamps an unstamped record whose log is still on disk, so the refusal is
    # reached only when healing is impossible. A record with no `log_scrub` whose
    # log is present is SERVED — after being folded — and the secret is gone from
    # the bytes rather than merely withheld.
    test "an unstamped record whose log is healable is folded, then served", %{
      conn: conn,
      run_state: rs
    } do
      log =
        record_failure(
          rs,
          "healme",
          "bld-h",
          "npm ERR! 401\nBARKPARK_TOKEN=bppat_healmenow\n",
          log_scrub: nil
        )

      assert File.read!(log) =~ "bppat_"

      body = conn |> get_bytes("healme", "bld-h") |> json_response(200)

      assert body["log_scrub"] == BuildLogScrub.version()
      assert body["tail"] =~ "npm ERR! 401"
      refute body["tail"] =~ "bppat_"
      assert body["tail"] =~ "[redacted]"

      # The STORED ARTIFACT changed, not just the response.
      refute File.read!(log) =~ "bppat_"
    end
  end

  ## 3. c2 — the size policy --------------------------------------------------

  describe "the size policy: a bounded tail with an honest marker" do
    # A log an order of magnitude over the cap. The assertions are on the three
    # things a size policy owes: the response is BOUNDED, the marker is HONEST
    # (it names how much is missing), and the bytes served are the TAIL — the
    # cause of a failure is at the bottom of a build log.
    test "a log over the cap serves a bounded TAIL with a truncated marker", %{
      conn: conn,
      run_state: rs
    } do
      put_cfg(max_build_log_tail_bytes: 4_096)

      filler = String.duplicate("this line is filler and must not be served\n", 2_000)
      body_text = "TOP OF THE LOG\n" <> filler <> "npm ERR! the REAL cause is last\n"
      record_failure(rs, "huge", "bld-big", body_text)

      body = conn |> get_bytes("huge", "bld-big") |> json_response(200)

      assert body["truncated"] == true
      assert body["log_bytes"] == byte_size(body_text)

      # BOUNDED: what came back is the cap plus the marker line, not the file.
      assert body["tail_bytes"] < 4_096 + 200
      assert body["tail_bytes"] < body["log_bytes"] / 10

      # THE TAIL, not the head.
      assert body["tail"] =~ "npm ERR! the REAL cause is last"
      refute body["tail"] =~ "TOP OF THE LOG"

      # HONEST: the marker is in the BYTES a human reads, and it names the real
      # numbers rather than saying "truncated" and leaving the size a mystery.
      assert body["tail"] =~ "truncated"
      assert body["tail"] =~ "#{byte_size(body_text)} bytes"
      assert String.starts_with?(body["tail"], "…[truncated")

      # NO HALF LINE at the top: the seek lands mid-line and that fragment is
      # dropped, so every line after the marker is a whole line.
      [_marker | lines] = String.split(body["tail"], "\n")
      assert hd(lines) == "this line is filler and must not be served"
    end

    # NEVER THE WHOLE FILE INTO MEMORY, proven by MEASURING the reading process
    # rather than by reading the implementation. The specific hazard is not
    # hypothetical: `File.read!/1 |> binary_part/3` is the obvious way to write
    # this function, and the sub-binary it returns REFERENCES the whole 4 MB
    # binary, so the file stays resident for as long as the response does. After
    # a forced GC the process must reference no binary near the file's size.
    test "the served tail does not hold the whole file in memory — measured, not asserted from source",
         %{run_state: rs} do
      put_cfg(max_build_log_tail_bytes: 4_096)

      big = String.duplicate("x", 4_000_000) <> "\nthe last line\n"
      record_failure(rs, "mem", "bld-mem", big)

      task =
        Task.async(fn ->
          {:ok, served} = DeployRunner.build_log_tail("mem", "bld-mem")
          :erlang.garbage_collect(self())

          {:binary, refs} = Process.info(self(), :binary)
          {served.tail, refs |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)}
        end)

      {tail, biggest_ref} = Task.await(task, 30_000)

      assert tail =~ "the last line"

      # THE CONTROL: the file really is 4 MB, so a passing measurement is a
      # measurement of something.
      assert File.stat!(Path.join(rs, "mem-bld-mem.log")).size > 4_000_000

      assert biggest_ref < 1_000_000,
             "the reading process still references a #{biggest_ref}-byte binary — " <>
               "that is the whole log, read in and sliced rather than seeked to"
    end

    test "a log UNDER the cap is served whole and is not marked truncated", %{
      conn: conn,
      run_state: rs
    } do
      put_cfg(max_build_log_tail_bytes: 4_096)
      whole = "npm ERR! short and complete\n"
      record_failure(rs, "small", "bld-s", whole)

      body = conn |> get_bytes("small", "bld-s") |> json_response(200)

      assert body["truncated"] == false
      assert body["tail"] == whole
      refute body["tail"] =~ "truncated"
    end

    # Build output is arbitrary process bytes. Invalid UTF-8 must not crash the
    # door (a JSON encoder raises on it) — the response is still JSON and still
    # carries the readable part.
    test "invalid UTF-8 in the log does not crash the door", %{conn: conn, run_state: rs} do
      record_failure(rs, "binary", "bld-bin", <<"npm ERR! ", 0xFF, 0xFE, "\ntail line\n">>)

      body = conn |> get_bytes("binary", "bld-bin") |> json_response(200)

      assert is_binary(body["tail"])
      assert body["tail"] =~ "npm ERR!"
    end
  end
end
