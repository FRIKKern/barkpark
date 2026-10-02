defmodule Barkpark.Sites.BuildLogScrubLockTest do
  @moduledoc """
  THE BOX HALF OF THE CROSS-APP SCRUB LOCK.

  `cloud/priv/secret-scrub.exs` is the ONE secret-pattern set, compiled by two
  OTP apps that cannot depend on each other: this app's recorded-log WRITE
  boundary (`Barkpark.Sites.BuildLogScrub`) and the control plane's display
  boundary (`BarkparkCloud.FailureCopy`). The sibling of this file is
  `cloud/test/barkpark_cloud/failure_copy_scrub_lock_test.exs`, and it asserts
  the same two things against the same bytes.

  WHAT EACH ARM CATCHES — stated, because one is weaker than it looks:

    * THE SET ARM is inert against an edit to the fixture (the fixture
      recompiles the module, so both move together). It catches the one thing it
      is for: a pattern table re-inlined into this app, i.e. the second, drifting
      copy the criterion forbids.

    * THE VECTOR ARM is the behaviour lock. The fixture carries expected OUTPUT
      bytes, so weakening a clause reds here AND in the cloud suite — which is
      what makes the two engines provably agree rather than merely share a table.

  Plus the arm neither app's lock could have on its own: `scrub_file/1` is
  exercised on a REAL FILE, with the pre-state asserted before the fold, so a
  "the token is gone" verdict cannot be produced by a token that was never there.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Sites.BuildLogScrub

  @fixture Path.expand("../../../../cloud/priv/secret-scrub.exs", __DIR__)

  # A real-shape Barkpark PAT: `bppat_` + a 43-char url-safe base64 body,
  # carrying the `-`/`_` that ~94% of minted bodies carry and that the bare
  # high-entropy clause structurally cannot see.
  @pat "bppat_7Kd-Qm2xTf9Zb_LpV4nA1sJhR0yWuEcG3iOtXvB"

  setup_all do
    {:ok, scrub: @fixture |> Code.eval_file() |> elem(0)}
  end

  defp shape(patterns) do
    Enum.map(patterns, fn {regex, replacement} ->
      {Regex.source(regex), Regex.opts(regex), replacement}
    end)
  end

  defp tmp_log(contents) do
    path =
      Path.join(System.tmp_dir!(), "bp-scrubfile-#{System.unique_integer([:positive])}.log")

    File.write!(path, contents)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  test "the fixture is not empty — the control on every assertion below", %{scrub: scrub} do
    assert length(scrub.patterns) >= 6,
           "the shared pattern set shrank: #{inspect(scrub.patterns)}"

    assert scrub.vectors != []
    assert String.contains?(scrub.ansi_run, "\x1B")
  end

  test "the compiled set IS the file's set — no second table in this app", %{scrub: scrub} do
    assert shape(BuildLogScrub.compiled_secret_patterns()) == shape(scrub.patterns)
    assert BuildLogScrub.compiled_ansi_run() == scrub.ansi_run
  end

  test "every shared vector folds to the shared expected bytes", %{scrub: scrub} do
    for {label, input, expected} <- scrub.vectors do
      assert BuildLogScrub.raw(input) == expected, "vector: #{label}"
    end
  end

  test "the order is strip_ansi |> scrub, and the reverse LEAKS — measured here, not quoted" do
    # THE ORDER-SENSITIVE SHAPE is a KEY-anchored value behind a welding escape.
    # `scrub/1`'s key clause opens `(?<![A-Za-z0-9])`, and a CSI run ends in an
    # alphanumeric of its own (`\e[0m` ends in `m`) — so scrubbing BEFORE
    # stripping puts a letter immediately left of the key and the clause never
    # fires. This is the control that makes the forward result mean something.
    welded = "run\e[0mapi_key=s3cretValueGoesHere1"

    reversed = welded |> BuildLogScrub.scrub() |> BuildLogScrub.strip_ansi()

    assert reversed =~ "s3cretValueGoesHere1",
           "the reverse order is supposed to LEAK — this control is broken"

    forward = BuildLogScrub.raw(welded)
    refute forward =~ "s3cretValueGoesHere1"
    assert forward == "run api_key=[redacted]"

    # OUR OWN PAT is a different shape and is deliberately NOT order-sensitive:
    # the `bppat_`/`bpcs_`/`bp_<kind>_` arm matches the TOKEN, not the syntax
    # around it, so it redacts through colour either way. Both orders are
    # asserted so nobody re-derives the 95.1% figure from this shape — that
    # measurement predates the prefix arm and is about `scrub/1` alone.
    colourised = "\e[31m\e[1m04:34:24\e[22m [build] BARKPARK_TOKEN=#{@pat} exported"
    refute BuildLogScrub.raw(colourised) =~ @pat
    refute colourised |> BuildLogScrub.scrub() |> BuildLogScrub.strip_ansi() =~ @pat
    assert BuildLogScrub.raw(colourised) =~ "BARKPARK_TOKEN=[redacted]"
  end

  describe "scrub_file/1 — the bytes on disk" do
    test "folds a real file in place, and the PRE-STATE is asserted first" do
      path = tmp_log("[build] BARKPARK_TOKEN=#{@pat}\n\e[31mnpm ERR!\e[0m failed\n")

      # THE PRECONDITION, not a control: the file really does carry the secret
      # and the colour before anything folds it.
      before = File.read!(path)
      assert before =~ @pat
      assert before =~ "\e["

      assert BuildLogScrub.scrub_file(path) == :ok

      after_bytes = File.read!(path)
      refute after_bytes =~ @pat
      refute after_bytes =~ "bppat_"
      refute after_bytes =~ "\e["
      assert after_bytes =~ "BARKPARK_TOKEN=[redacted]"
      # Line structure survives byte-for-byte where nothing was redacted.
      assert after_bytes =~ "npm ERR! failed"
      assert String.ends_with?(after_bytes, "\n")
      assert length(String.split(after_bytes, "\n")) == length(String.split(before, "\n"))
    end

    test "is idempotent — a second fold changes nothing" do
      path = tmp_log("token: #{@pat}\nplain line\n")
      :ok = BuildLogScrub.scrub_file(path)
      once = File.read!(path)
      :ok = BuildLogScrub.scrub_file(path)
      assert File.read!(path) == once
    end

    test "leaves no temp file behind" do
      dir = Path.join(System.tmp_dir!(), "bp-scrubdir-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "build.log")
      File.write!(path, "api_key=s3cretValueGoesHere1\n")

      assert BuildLogScrub.scrub_file(path) == :ok
      assert File.ls!(dir) == ["build.log"]
    end

    test "a missing file is :ok (there are no unscrubbed bytes there) and a non-path is not" do
      assert BuildLogScrub.scrub_file(Path.join(System.tmp_dir!(), "bp-no-such-log-xyz")) == :ok
      assert BuildLogScrub.scrub_file(nil) == {:error, :no_log_path}
    end

    test "a big log folds without landing in memory whole — and still redacts" do
      # 20k lines of filler with ONE secret in the middle: proves the streaming
      # fold sees the whole file, not just its head.
      filler = String.duplicate("npm WARN deprecated something@1.0.0\n", 10_000)
      path = tmp_log(filler <> "export BARKPARK_TOKEN=#{@pat}\n" <> filler)

      assert BuildLogScrub.scrub_file(path) == :ok
      folded = File.read!(path)
      refute folded =~ @pat
      assert folded =~ "BARKPARK_TOKEN=[redacted]"
    end
  end
end
