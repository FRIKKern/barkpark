defmodule Barkpark.Sites.PrebuiltArtifactStreamFaultTest do
  @moduledoc """
  What an UNEXPECTED error inside the inflate loop does.

  `run_stream/3` catches an allowlist of zlib atoms. That narrowness is the
  design — a parser bug must not render as "the archive is malformed" — and its
  price is that every atom OUTSIDE the list kills the caller instead of
  answering one of the module's typed refusals, which is the one shape the whole
  ingest contract exists to avoid. It was seen once, on a memory-pressured
  131.5 s CI run, and four reruns on fixed seeds were clean: a real hazard with
  an unproven trigger. Arguing about it is not evidence, so this file FORCES it.

  ## How, and why it is a separate OS process

  The only seam between `drain/3` and the error is `:zlib` itself, so the probe
  replaces `:zlib` with a stub that hands back the plaintext the test already
  holds and raises a chosen atom on a chosen call. Replacing a stdlib module is
  a whole-VM act — visible to every other process on the node — so it happens in
  a VM of its own (`test/support/zlib_fault_probe.exs`) that exits when the
  probe does. Nothing in THIS node is swapped, stubbed or restored, and no
  `mix test` ordering makes that untrue.

  ## What each arm proves

  An injector armed on the wrong call site goes green while the hole under test
  never runs, so every arm asserts WHERE the fault fired, not merely that it
  did: the stub reports the `safeInflate` call index and the bytes of real tar
  it had already delivered, and the crash arms additionally assert the
  stacktrace names `drain/3`. `@fire_at` is 20 of ~85 calls, so 9 728 bytes —
  19 tar blocks, several whole entries — are through the state machine before
  the fault, exactly as in the sighting.

  The no-fault arm is the control on all of it: the SAME archive, the SAME stub,
  no raise, `{:ok, _}`. Without it every verdict below could be produced by an
  archive that was simply broken.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Sites.PrebuiltArtifact

  @probe Path.expand("../../support/zlib_fault_probe.exs", __DIR__)

  # Plaintext bytes the stub hands over per `safeInflate` call: one tar block, so
  # the call index IS the block index and `delivered` is checkable by hand.
  @chunk 512
  @fire_at 20
  @delivered_before_fault (@fire_at - 1) * @chunk

  setup_all do
    assert File.exists?(@probe),
           "the probe script is gone from #{@probe}; a move makes this file vacuous, not passing"

    elixir =
      System.find_executable("elixir") ||
        flunk("no `elixir` on PATH — this file drives a second VM and cannot run without one")

    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    assert Enum.any?(paths, &String.contains?(&1, "/barkpark/ebin")),
           "the probe VM needs barkpark's ebin on its path; found #{length(paths)} ebin dirs"

    {:ok, elixir: elixir, paths: paths}
  end

  setup do
    base = Path.join(System.tmp_dir!(), "bp-stream-fault-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  # ── a legitimate, multi-entry site bundle ─────────────────────────────────

  defp nul_pad(v, w), do: String.pad_trailing(v, w, <<0>>)
  defp octal(v, w), do: String.pad_leading(Integer.to_string(v, 8), w - 1, "0") <> <<0>>

  defp header(name, size) do
    body =
      nul_pad(name, 100) <>
        octal(0o644, 8) <>
        octal(0, 8) <>
        octal(0, 8) <>
        octal(size, 12) <>
        octal(0, 12) <>
        "        " <>
        "0" <>
        nul_pad("", 100) <>
        "ustar" <>
        <<0>> <>
        "00" <>
        nul_pad("", 32) <>
        nul_pad("", 32) <>
        octal(0, 8) <> octal(0, 8) <> nul_pad("", 155) <> nul_pad("", 12)

    512 = byte_size(body)
    <<pre::binary-size(148), _::binary-size(8), post::binary-size(356)>> = body
    sum = sum_bytes(pre) + sum_bytes(post) + 8 * ?\s
    <<pre::binary, octal(sum, 7)::binary, " ", post::binary>>
  end

  defp sum_bytes(b), do: b |> :binary.bin_to_list() |> Enum.sum()

  defp entry(name, content),
    do:
      header(name, byte_size(content)) <>
        content <> :binary.copy(<<0>>, rem(512 - rem(byte_size(content), 512), 512))

  defp site_tar do
    pages =
      for i <- 1..40 do
        entry("page#{i}.html", "<html>page #{i} " <> String.duplicate("x", 400) <> "</html>")
      end

    IO.iodata_to_binary(
      [entry("index.html", "<html>root</html>") | pages] ++ [:binary.copy(<<0>>, 1024)]
    )
  end

  # ── the injector ──────────────────────────────────────────────────────────

  defp inject(ctx, error, fire_at, dest \\ nil) do
    dest = dest || Path.join(ctx.base, "site-#{System.unique_integer([:positive])}")
    tar = site_tar()
    gz = :zlib.gzip(tar)
    sha = :crypto.hash(:sha256, gz) |> Base.encode16(case: :lower)

    request = Path.join(ctx.base, "request.bin")
    reply = Path.join(ctx.base, "reply-#{System.unique_integer([:positive])}.bin")

    File.write!(
      request,
      :erlang.term_to_binary(%{
        plain: tar,
        chunk: @chunk,
        fire_at: fire_at,
        error: error,
        artifact_b64: Base.encode64(gz),
        sha256: sha,
        dest: dest,
        opts: []
      })
    )

    args = Enum.flat_map(ctx.paths, &["-pa", &1]) ++ [@probe, request, reply]
    {out, code} = System.cmd(ctx.elixir, args, stderr_to_stdout: true)

    assert code == 0, "the probe VM itself failed (exit #{code}):\n#{out}"
    assert File.exists?(reply), "the probe VM wrote no reply:\n#{out}"

    result = reply |> File.read!() |> :erlang.binary_to_term()
    result |> Map.put(:tar_bytes, byte_size(tar)) |> Map.put(:dest, dest)
  end

  # Every `<dest>.staging-*` sibling on disk — the tree a refusal (or a crash)
  # must not leave behind. Listed from the PARENT, not globbed from a guessed
  # name, so a staging dir named any other way is still seen.
  defp staging_residue(dest) do
    prefix = Path.basename(dest) <> ".staging-"

    dest
    |> Path.dirname()
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.sort()
  end

  defp drain_frame(stacktrace) do
    Enum.find(stacktrace, fn
      {PrebuiltArtifact, :drain, 3, _} -> true
      _ -> false
    end)
  end

  # ── the control: the archive and the harness are both sound ───────────────

  test "CONTROL — the same archive through the same stub with NO fault stages clean", ctx do
    # `fire_at: 0` can never equal a 1-based call index, so the stub raises
    # nothing. If this reds, every verdict below is about a broken archive
    # rather than about the injected error.
    result = inject(ctx, :enomem, 0)

    assert {:returned, {:ok, summary}} = result.outcome
    assert summary.entries == 41
    assert result.delivered == result.tar_bytes
    assert result.calls > @fire_at, "the fault arms must fire mid-stream, not past the end"
  end

  # ── the reproduction: the allocation class used to kill the caller ────────

  for error <- [:enomem, :system_limit] do
    test "#{error} inside the stream is a TYPED refusal, not a dead caller", ctx do
      result = inject(ctx, unquote(error), @fire_at)

      # WHERE it fired, before WHAT it answered: the fault is on the 20th
      # `safeInflate` call, with 19 whole tar blocks already through the parser.
      assert result.calls == @fire_at
      assert result.delivered == @delivered_before_fault

      assert {:returned, {:error, "E_EXTRACT_EXHAUSTED", message}} = result.outcome
      assert message =~ to_string(unquote(error))

      # And it is filed against the BOX, not the caller's bytes: a caller who
      # repacks a perfectly good artifact is a caller who was told the wrong
      # thing.
      assert PrebuiltArtifact.internal_failure?("E_EXTRACT_EXHAUSTED")
      refute "E_EXTRACT_EXHAUSTED" in PrebuiltArtifact.caller_fault_codes()
    end
  end

  # ── the narrowness that must SURVIVE the widening ─────────────────────────

  for error <- [:badarg, :not_initialized, :not_on_controlling_process] do
    test "#{error} inside the stream STILL CRASHES LOUDLY", ctx do
      result = inject(ctx, unquote(error), @fire_at)

      assert result.calls == @fire_at
      assert result.delivered == @delivered_before_fault

      # BIND FIRST, then assert on a boolean. `assert pattern = expr, message`
      # evaluates the match as an ordinary `=`, so a mismatch raises MatchError
      # and this message never prints — on exactly the path it was written for.
      # That matters most HERE: if this arm ever reds it is because someone
      # widened the catch, and what they need to read is the sentence below, not
      # `no match of right hand side value: {:returned, {:error, "E_...", ...}}`.
      outcome = result.outcome

      assert match?({:raised, :error, unquote(error), _}, outcome),
             "#{unquote(error)} is a bug in this module or its caller, never a verdict about " <>
               "the archive. Typing it would file a bug under the caller's bytes. Got: " <>
               inspect(outcome)

      {:raised, :error, _kind, stacktrace} = outcome

      assert drain_frame(stacktrace),
             "the crash must come from inside drain/3 — if it does not, the injector fired " <>
               "somewhere the hole is not. Stack: #{inspect(Enum.take(stacktrace, 4))}"
    end
  end

  # ── the pre-existing class, unmoved ───────────────────────────────────────

  test "CONTROL — :data_error still answers E_MALFORMED, from the same call site", ctx do
    result = inject(ctx, :data_error, @fire_at)

    assert result.calls == @fire_at
    assert {:returned, {:error, "E_MALFORMED", message}} = result.outcome
    assert message =~ "corrupt"
    assert "E_MALFORMED" in PrebuiltArtifact.caller_fault_codes()
  end

  # ── a crash must not leave its staging tree behind ────────────────────────
  #
  # The crash arms above prove the raise is LOUD. These prove it is also CLEAN:
  # the `rm_rf` that makes "a refusal leaves NO partial tree" true used to run
  # only on `run_stream/3`'s RETURN path, so a process that died inside the
  # stream left the whole `<dest>.staging-<n>` tree — with 19 blocks of real tar
  # already written into it — on disk.

  for error <- [:badarg, :not_initialized, :not_on_controlling_process] do
    test "#{error} inside the stream crashes AND leaves no staging tree", ctx do
      result = inject(ctx, unquote(error), @fire_at)

      # The precondition, asserted: the fault fired mid-stream, after the parser
      # had already WRITTEN entries — a staging tree existed to leak.
      assert result.calls == @fire_at
      assert result.delivered == @delivered_before_fault

      outcome = result.outcome

      assert match?({:raised, :error, unquote(error), _}, outcome),
             "the cleanup must not swallow the crash. Got: #{inspect(outcome)}"

      {:raised, :error, _kind, stacktrace} = outcome

      assert drain_frame(stacktrace),
             "the re-raised crash must still name drain/3 as its origin — a cleanup that " <>
               "re-raises with a fresh stacktrace hides where the bug is. " <>
               "Stack: #{inspect(Enum.take(stacktrace, 4))}"

      residue = staging_residue(result.dest)

      assert residue == [],
             "a crash inside run_stream/3 leaked its staging tree: #{inspect(residue)} " <>
               "under #{Path.dirname(result.dest)}"

      refute File.exists?(result.dest), "a crash must not produce the destination either"
    end
  end

  # ── residue must not change a LATER verdict ───────────────────────────────
  #
  # How the leak was actually found: a probe VM reused a staging directory a
  # crashed predecessor had left, and answered `E_UNSAFE_PARENT — names
  # index.html more than once` about an archive that names it once. Two
  # independent holes had to line up for that: the crash leaked the tree, AND
  # the next run's staging NAME collided with it and was silently re-entered
  # (`System.unique_integer/1` restarts in every VM; `File.mkdir_p/1` accepts an
  # existing directory). Each arm below closes on one of them.

  test "a run after a CRASHED predecessor answers what a clean box answers", ctx do
    clean = inject(ctx, :enomem, 0)
    assert {:returned, {:ok, clean_summary}} = clean.outcome

    dest = Path.join(ctx.base, "site-after-crash")
    crashed = inject(ctx, :badarg, @fire_at, dest)
    crashed_outcome = crashed.outcome
    assert match?({:raised, :error, :badarg, _}, crashed_outcome), inspect(crashed_outcome)

    after_crash = inject(ctx, :enomem, 0, dest)
    after_outcome = after_crash.outcome

    assert match?({:returned, {:ok, _}}, after_outcome),
           "the predecessor's crash changed this run's verdict: #{inspect(after_outcome)}"

    {:returned, {:ok, after_summary}} = after_outcome
    assert after_summary.entries == clean_summary.entries
    assert after_summary.bytes == clean_summary.bytes
    assert staging_residue(dest) == []
  end

  test "residue a crash could NOT clean (a killed VM) is never re-entered by a later run",
       ctx do
    # `try/after` cannot run in a VM that was SIGKILLed, so the naming has to be
    # safe on its own. Plant what such a predecessor leaves — a half-written
    # tree holding `index.html` — under every name a fresh VM's
    # `unique_integer([:positive])` hands out early, then stage in a fresh VM.
    dest = Path.join(ctx.base, "site-after-kill")

    planted =
      for n <- 1..4096 do
        dir = "#{dest}.staging-#{n}"
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "index.html"), "<html>a dead run's page</html>")
        Path.basename(dir)
      end

    result = inject(ctx, :enomem, 0, dest)
    outcome = result.outcome

    assert match?({:returned, {:ok, %{entries: 41}}}, outcome),
           "a killed predecessor's residue changed this run's verdict: #{inspect(outcome)}"

    # The new run removed only what it created; the dead run's litter is left
    # for an operator, never adopted.
    assert staging_residue(dest) == Enum.sort(planted)
    assert File.read!(Path.join(dest, "index.html")) == "<html>root</html>"
  end

  test "the staging name is fresh per run AND still one the orphan sweep can recognise", ctx do
    # The one place the name is observable: E_STAGING_FAILED quotes it. A FILE
    # where the destination's parent should be makes the staging mkdir fail.
    blocker = Path.join(ctx.base, "not-a-dir")
    File.write!(blocker, "")
    dest = Path.join(blocker, "site")

    gz = :zlib.gzip(site_tar())
    sha = :crypto.hash(:sha256, gz) |> Base.encode16(case: :lower)

    names =
      for _ <- 1..2 do
        result = PrebuiltArtifact.stage(Base.encode64(gz), sha, dest)
        assert {:error, "E_STAGING_FAILED", message} = result
        [_, name] = Regex.run(~r/staging dir (\S+):/, message)
        Path.basename(name)
      end

    # DeployRunner's `@orphan_staging_rx`, copied: a name it cannot match is
    # residue that nothing ever removes after a killed VM.
    for name <- names, do: assert(name =~ ~r/\Asite\.staging-\d+\z/, name)

    [a, b] = names
    refute a == b, "two runs on one dest got the same staging name: #{a}"

    # And not a small per-VM counter: 128 random bits is ~39 decimal digits.
    for name <- names do
      [_, digits] = Regex.run(~r/staging-(\d+)\z/, name)
      assert String.to_integer(digits) > 1_000_000_000_000, name
    end
  end
end
