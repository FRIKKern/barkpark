defmodule Barkpark.Dedup.ScanSeamInertnessTest do
  @moduledoc """
  THE LOCK ON "THE SEAM CANNOT CHANGE PRODUCTION BEHAVIOUR WHEN UNSET".

  A test-only seam that a production node can reach is WORSE than the untested
  branch it exists to cover, so the inertness is structural and this file is
  what keeps it structural. It reds on each of the three things a future edit
  would have to do to make the seam reachable in production:

    1. downgrade `Application.compile_env/3` to a runtime read
       (`get_env`/`fetch_env`), which would let a running node flip it;
    2. set `:dedup_scan_seam` in a config file other than `test.exs`;
    3. widen the seam past `exit/1` — give it a caller-supplied function, a
       return value the fetch branches on, or any reach into the Repo — so that
       an armed seam could do something other than force the refusal the module
       already produces for a real outage.

  It also pins the premise the whole argument rests on: the `if` that chooses
  between the armed and the inert implementation is at the MODULE BODY, so the
  compiler resolves it once and emits ONE of the two. This build (which sets the
  key) exports `arm/2`; a build that does not set the key therefore emits the
  other branch, in which `check!/1` is a literal `:ok` and the
  process-dictionary read does not exist in the BEAM.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Dedup.ScanSeam

  @seam_path Path.expand("../../../lib/barkpark/dedup/scan_seam.ex", __DIR__)
  @config_dir Path.expand("../../../config", __DIR__)
  @key "dedup_scan_seam"

  defp seam_source do
    assert File.exists?(@seam_path), "#{@seam_path} does not exist — this test measures nothing"
    File.read!(@seam_path)
  end

  test "THE PRECONDITION: the instrument reads the real files" do
    # An empty read would pass every absence assertion below, forever, green.
    src = seam_source()
    assert src =~ "defmodule Barkpark.Dedup.ScanSeam"
    assert src =~ @key, "the seam source does not mention #{@key} — extractor is pointed wrong"

    configs = Path.wildcard(Path.join(@config_dir, "*.exs"))

    assert length(configs) >= 4,
           "found #{length(configs)} config files under #{@config_dir} — expected the full set"

    assert Enum.any?(configs, &(Path.basename(&1) == "prod.exs"))
    assert Enum.any?(configs, &(Path.basename(&1) == "runtime.exs"))
  end

  test "LAYER 1: the gate is a COMPILE-time read, never a runtime one" do
    src = seam_source()

    assert src =~ ~r/Application\.compile_env\(:barkpark, :dedup_scan_seam/,
           "the seam must read its gate with Application.compile_env/3"

    refute src =~ ~r/Application\.(get_env|fetch_env|fetch_env!)\(/,
           "a runtime env read in the seam would make it flippable on a live node"

    refute src =~ ~r/System\.get_env/,
           "an environment-variable read would make the seam flippable at boot"
  end

  test "LAYER 1b: the armed/inert choice is resolved by the COMPILER, not per call" do
    # This build sets the key, so it must have compiled the ARMED branch. That
    # can only be true if the `if` ran at compile time on the module body —
    # which is exactly why a build WITHOUT the key emits the inert branch, with
    # no Process.get and no arming functions at all.
    assert ScanSeam.enabled?()
    assert function_exported?(ScanSeam, :arm, 2)
    assert function_exported?(ScanSeam, :disarm, 0)

    src = seam_source()

    assert src =~ ~r/\n  if @enabled do\n/,
           "the branch must sit at the module body; inside a function it would be a runtime if"

    assert src =~
             ~r/\n  else\n    @spec check!\(surface\(\)\) :: :ok\n    def check!\(_surface\), do: :ok\n/,
           "the inert branch must be a literal :ok with no other work in it"
  end

  test "LAYER 2: :dedup_scan_seam is set in config/test.exs and NOWHERE else" do
    offenders =
      @config_dir
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.reject(&(Path.basename(&1) == "test.exs"))
      |> Enum.filter(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.any?(fn line ->
          trimmed = String.trim_leading(line)
          not String.starts_with?(trimmed, "#") and String.contains?(line, @key)
        end)
      end)

    assert offenders == [],
           """
           :dedup_scan_seam is set outside config/test.exs: #{inspect(offenders)}

           That would compile the fault injector into a non-test build. The seam's
           whole safety argument is that only test.exs sets this key.
           """

    # And the positive half: test.exs DOES set it, so LAYER 1b above is not
    # passing because the key happens to be on by accident somewhere else.
    assert @config_dir |> Path.join("test.exs") |> File.read!() =~ "config :barkpark, #{@key}:"
  end

  test "LAYER 3: the seam's entire power is exit/1 — it runs no caller code and no query" do
    src = seam_source()

    assert src =~ ~r/exit\(reason\)/, "the seam must be able to exit — that is its only job"

    for forbidden <- ["Barkpark.Repo", "Ecto.", "apply(", "fun.(", "spawn", "send("] do
      refute String.contains?(src, forbidden),
             "the seam must not be able to #{forbidden} — widen it and it stops being inert"
    end

    # `arm/2` accepts a REASON, not a function: there is no way to hand the seam
    # code to run, so the worst an armed seam can do is force the refusal the
    # module already produces for a real outage.
    assert src =~ ~r/def arm\(surface, reason\) when surface in \[/
    refute src =~ ~r/is_function\(/
  end

  test "LAYER 3b: arming is PROCESS-LOCAL, so it cannot leak into an async neighbour" do
    src = seam_source()

    assert src =~ "Process.put(@key,"
    assert src =~ "Process.get(@key)"

    refute src =~ ~r/:ets\./, "an ETS table would outlive the test that armed it"
    refute src =~ ~r/Application\.put_env/, "application env would be global and leak"

    # Observed, not merely read: this process never armed anything, and the
    # sibling test that DOES arm runs async alongside it.
    assert ScanSeam.check!(:content_dedup_wall) == :ok
    assert ScanSeam.check!(:tasks_dedup) == :ok
  end

  test "both dedup moduledocs document the seam" do
    for path <- [
          Path.expand("../../../lib/barkpark/content/dedup_wall.ex", __DIR__),
          Path.expand("../../../lib/barkpark/tasks/dedup.ex", __DIR__)
        ] do
      src = File.read!(path)
      [moduledoc | _] = String.split(src, ~s(\n  """\n  import), parts: 2)

      assert moduledoc =~ "Barkpark.Dedup.ScanSeam",
             "#{Path.basename(path)}'s moduledoc does not name the seam"

      assert moduledoc =~ "catch :exit",
             "#{Path.basename(path)}'s moduledoc does not say what the seam proves"
    end
  end
end
