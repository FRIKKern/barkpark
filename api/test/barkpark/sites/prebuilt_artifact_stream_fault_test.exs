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

  defp inject(ctx, error, fire_at) do
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
        dest: Path.join(ctx.base, "site-#{System.unique_integer([:positive])}"),
        opts: []
      })
    )

    args = Enum.flat_map(ctx.paths, &["-pa", &1]) ++ [@probe, request, reply]
    {out, code} = System.cmd(ctx.elixir, args, stderr_to_stdout: true)

    assert code == 0, "the probe VM itself failed (exit #{code}):\n#{out}"
    assert File.exists?(reply), "the probe VM wrote no reply:\n#{out}"

    result = reply |> File.read!() |> :erlang.binary_to_term()
    Map.put(result, :tar_bytes, byte_size(tar))
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

      assert {:raised, :error, unquote(error), stacktrace} = result.outcome,
             "#{unquote(error)} is a bug in this module or its caller, never a verdict about " <>
               "the archive. Typing it would file a bug under the caller's bytes. Got: " <>
               inspect(result.outcome)

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
end
