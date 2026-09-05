defmodule Barkpark.CycleFleet.ReleaseCaptureAdapterTest do
  use ExUnit.Case, async: false

  alias Barkpark.CycleFleet.ReleaseCaptureAdapter
  alias Barkpark.CycleFleet.ReleaseCaptureAdapter.Production

  test "public smoke loads its configured adapter after a cold boot" do
    previous = Application.get_env(:barkpark, :cycle_release_capture_adapter)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:barkpark, :cycle_release_capture_adapter, previous),
        else: Application.delete_env(:barkpark, :cycle_release_capture_adapter)

      Code.ensure_loaded!(Production)
    end)

    Application.put_env(:barkpark, :cycle_release_capture_adapter, Production)
    :code.purge(Production)
    :code.delete(Production)

    refute Code.loaded?(Production)

    refute ReleaseCaptureAdapter.public_smoke(%{}) ==
             {:error, :public_release_smoke_unavailable}

    assert Code.loaded?(Production)
  end

  # Coverage for the sole spawn path (bounded_cmd/4 → collect_command/4). Both
  # violation branches — the deadline `after` clause ({"", 124}) and the over-cap
  # clause ({"", 125}) — are private and reachable only through the public
  # capture/1 door, so each test satisfies capture_http via a Bypass stub, then
  # exercises capture_headless against a shell stub wired in as :bp_path. The
  # branch's effect is proven by WALL-CLOCK: the deadline test asserts the run is
  # cut at the bound (well below its stub's sleep); the over-cap test asserts the
  # port is closed the instant the cap is crossed (sub-second, not the deadline).
  # Both are mutation-proven — deleting either branch flips the assertion red.
  # See release_capture_adapter.ex collect_command/4.
  #
  # THE BOUND IS DIALLED DOWN UNDER TEST, AND THE STUBS WITH IT. Production's
  # deadline is 30 s; asserting on it cost ~30 s of dead wall clock on every run
  # of the required Elixir gate — the largest single stall in it
  # (task-18f209f185f5b3f1). What the wall clock has to separate is a run that was
  # CUT at the bound from a run that waited out its stub, and that separation is a
  # RATIO, not a magnitude: at a 3 s bound against a 20 s stub the two outcomes are
  # as far apart as 30 s against 45 s, and further. The mutation proof is
  # unchanged — delete `after remaining ->` and the deadline arm waits the stub's
  # 20 s, blowing its ceiling; delete the over-cap clause and the cap arm falls
  # through to the deadline, blowing its ceiling.
  describe "collect_command/4 bounds (via the capture/1 spawn path)" do
    @deployment_digest String.duplicate("a", 64)
    # The deadline under test. Production's default (30_000) is untouched.
    @test_deadline_ms 3_000

    setup do
      previous = %{
        adapter: Application.get_env(:barkpark, :cycle_release_capture_adapter),
        token: Application.get_env(:barkpark, :cycle_release_capture_token),
        bp_path: Application.get_env(:barkpark, :cycle_release_capture_bp_path),
        digest: Application.get_env(:barkpark, :release_deployment_digest),
        deadline: Application.get_env(:barkpark, :cycle_release_capture_command_timeout_ms)
      }

      on_exit(fn ->
        restore(:cycle_release_capture_adapter, previous.adapter)
        restore(:cycle_release_capture_token, previous.token)
        restore(:cycle_release_capture_bp_path, previous.bp_path)
        restore(:release_deployment_digest, previous.digest)
        restore(:cycle_release_capture_command_timeout_ms, previous.deadline)
      end)

      Application.put_env(:barkpark, :cycle_release_capture_adapter, Production)
      Application.put_env(:barkpark, :cycle_release_capture_token, "release-capture-test-token")
      Application.put_env(:barkpark, :release_deployment_digest, @deployment_digest)

      Application.put_env(
        :barkpark,
        :cycle_release_capture_command_timeout_ms,
        @test_deadline_ms
      )

      bypass = Bypass.open()

      # capture_http fires four GETs (campaign|successor × source_json|public_html);
      # every one must return 200 with the surface's content type, or capture/1
      # short-circuits before it ever reaches the headless spawn under test.
      Bypass.expect(bypass, fn conn ->
        content_type =
          if String.contains?(conn.request_path, "source_json"),
            do: "application/json",
            else: "text/html"

        conn
        |> Plug.Conn.put_resp_header("content-type", content_type)
        |> Plug.Conn.resp(200, "{}")
      end)

      {:ok, bypass: bypass}
    end

    @tag timeout: 120_000
    test "the deadline branch cuts the spawn at its bound (124), well before the stub exits", %{
      bypass: bypass
    } do
      # Stub produces no output and would run for 20s; the 3s deadline must cut it.
      write_bp_stub("""
      #!/bin/sh
      sleep 20
      """)

      {elapsed_us, result} = :timer.tc(fn -> ReleaseCaptureAdapter.capture(request(bypass)) end)

      assert result == {:error, :headless_capture_failed}

      # Lower bound: the deadline actually elapsed (not an instant misconfig
      # failure). Anything that fails before the spawn returns in milliseconds.
      assert elapsed_us > 2_000_000,
             "expected the run to reach the #{@test_deadline_ms}ms deadline, got #{div(elapsed_us, 1000)}ms"

      # Upper bound: the run was CUT — it did not wait out the stub's 20s sleep.
      # Deleting the `after remaining ->` clause makes collect_command block until
      # the stub exits at ~20s, flipping this assertion red.
      assert elapsed_us < 12_000_000,
             "expected the deadline to cut the run below the stub's 20s sleep, got #{div(elapsed_us, 1000)}ms"
    end

    @tag timeout: 120_000
    test "the over-cap branch closes the port the moment the cap is crossed (125)", %{
      bypass: bypass
    } do
      # This arm keeps a LONG deadline on purpose, and it is free: when the cap
      # branch exists the run never reaches the deadline, so a 20s bound costs
      # zero wall clock on a green run. It is what the arm DISCRIMINATES AGAINST —
      # delete the cap clause and the flooded chunks stop matching, the stub never
      # exits, and the run only unblocks at 20s, twice this arm's ceiling.
      Application.put_env(:barkpark, :cycle_release_capture_command_timeout_ms, 20_000)

      # Stub floods >2MB (the @max_command_output_bytes cap) then hangs. With the
      # cap branch the port is closed the instant the cap is crossed.
      write_bp_stub("""
      #!/bin/sh
      yes aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa | head -c 3000000
      sleep 45
      """)

      {elapsed_us, result} = :timer.tc(fn -> ReleaseCaptureAdapter.capture(request(bypass)) end)

      assert result == {:error, :headless_capture_failed}

      # The cap fires at once; without it the run falls through to the 20s
      # deadline. A 10s ceiling separates the two outcomes with room for a
      # loaded runner on either side.
      assert elapsed_us < 10_000_000,
             "expected the cap to close the port at once, got #{div(elapsed_us, 1000)}ms"
    end

    defp restore(key, nil), do: Application.delete_env(:barkpark, key)
    defp restore(key, value), do: Application.put_env(:barkpark, key, value)

    defp write_bp_stub(contents) do
      path =
        Path.join(
          System.tmp_dir!(),
          "bp_release_capture_stub_#{System.unique_integer([:positive])}.sh"
        )

      File.write!(path, contents)
      File.chmod!(path, 0o755)
      Application.put_env(:barkpark, :cycle_release_capture_bp_path, path)
      on_exit(fn -> File.rm(path) end)
      path
    end

    defp request(bypass) do
      origin = BarkparkWeb.Endpoint.url()

      %{
        "format" => "cycle-release-capture-request-v1",
        "canonical_origin" => origin,
        "deployment_digest" => @deployment_digest,
        "readers" => %{
          "campaign" => reader_set(bypass, "campaign"),
          "successor" => reader_set(bypass, "successor")
        }
      }
    end

    defp reader_set(bypass, role) do
      %{
        "source_json" => %{
          "method" => "GET",
          "url" => "http://127.0.0.1:#{bypass.port}/#{role}/source_json"
        },
        "public_html" => %{
          "method" => "GET",
          "url" => "http://127.0.0.1:#{bypass.port}/#{role}/public_html"
        },
        "cli" => %{"argv" => ["bp", "release-capture"]}
      }
    end
  end
end
