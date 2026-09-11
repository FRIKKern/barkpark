defmodule Barkpark.Sites.BuildLogScrub do
  @moduledoc """
  The box's WRITE-boundary scrubber for a recorded build log.

  ## Why this exists at all

  `DeployRunner` records every build's output to `<run-state>/<slug>-<tag>.log`,
  written VERBATIM by the deploy shell's `tee` (`deploy/lib/site-deploy-common.sh`
  `log()`). The build env file it sources carries `BARKPARK_TOKEN=` in plaintext,
  and a build prints whatever it prints — so until this module existed, the one
  durable artifact on the box with the highest secret density had NO scrubber on
  its write path at all. The two scrubbers that did exist
  (`BarkparkCloud.FailureCopy.scrub/1` and `strip_ansi/1`) are DISPLAY-boundary
  by their own moduledoc: they protect one reader and leave the bytes on disk for
  ops queries, backups, support exports and the next feature to leak.

  This module closes that: at finalize the recorded log is rewritten IN PLACE,
  and `log_bytes` on the terminal record is computed from the SCRUBBED file.

  ## One pattern set, two apps

  The patterns are NOT declared here. They are read at compile time from
  `cloud/priv/secret-scrub.exs` — the same bytes `BarkparkCloud.FailureCopy`
  compiles — via `@external_resource`, so editing the fixture recompiles this
  module too. `build_log_scrub_lock_test.exs` re-reads that file at test time and
  fails if this module's compiled set has drifted from it; the identical test
  exists on the cloud side against the same file. A hand-copied second table in
  this app is exactly what dr-bl-recorder-http-read-path c2 forbids, and the
  reason is that a copied redaction table drifts in SILENCE: a redacted token and
  a leaked one look identical until someone reads the bytes.

  There is no fallback if the fixture is absent. A missing pattern set must be a
  BUILD failure, never a scrub that quietly redacts nothing — `api/Dockerfile`
  carries the matching `COPY` for the container build, and the box builds from
  the repo checkout where the file is simply present.

  ## The order is the whole point

  `raw/1` is `strip_ansi |> scrub`, never the reverse. A CSI sequence parks an
  alphanumeric immediately left of a key, which defeats `scrub/1`'s
  `(?<![A-Za-z0-9])` lookbehind — measured at 95.1% leakage for a colourised
  `bppat_` token under the reverse order (charter D29). A raw build log is PTY
  output: it is colourised by construction, so this is the common case here, not
  the corner.

  ## Line-oriented, on purpose

  `scrub_file/1` streams the log a line at a time into a sibling temp file and
  renames over the original, so a 256 MB log (the retention cap) never lands in
  memory whole. A secret shape that SPANS a newline is therefore out of scope —
  no credential the pattern set knows carries a `\\n`, and neither does an ANSI
  run.
  """

  require Logger

  # The single cross-app pattern set. See the fixture's own header for why it
  # lives under cloud/priv/ (the control-plane image COPYs cloud/ and nothing
  # above it, so a cloud/lib compile-time read cannot resolve any higher).
  @secret_scrub_fixture Path.expand("../../../../cloud/priv/secret-scrub.exs", __DIR__)
  @external_resource @secret_scrub_fixture
  @secret_scrub @secret_scrub_fixture |> Code.eval_file() |> elem(0)

  @secret_patterns @secret_scrub.patterns
  @ansi_run @secret_scrub.ansi_run
  @ansi_runs Regex.compile!("(?:" <> @ansi_run <> ")+")
  @escape_delimiter " "

  # The marker written onto a terminal record once its log has been folded. A
  # VERSION, not a boolean: widening the pattern set later has to be able to tell
  # a log scrubbed by the old set from one scrubbed by the new.
  @scrub_version 1

  @doc """
  The scrub version stamped onto a terminal record whose log this module folded.
  """
  @spec version() :: pos_integer()
  def version, do: @scrub_version

  @doc false
  @spec compiled_secret_patterns() :: [{Regex.t(), String.t()}]
  def compiled_secret_patterns, do: @secret_patterns

  @doc false
  @spec compiled_ansi_run() :: String.t()
  def compiled_ansi_run, do: @ansi_run

  @doc """
  Redact secret-shaped SUBSTRINGS. Non-binaries pass through unchanged.

  Byte-for-byte the cloud display boundary's reduction over the same table —
  `build_log_scrub_lock_test.exs` pins both the table and the resulting bytes
  against the shared fixture's vectors.
  """
  @spec scrub(term()) :: term()
  def scrub(text) when is_binary(text) do
    Enum.reduce(@secret_patterns, text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  def scrub(other), do: other

  @doc """
  Strip terminal control sequences. Non-binaries pass through unchanged.

  A run sitting BETWEEN two alphanumerics is replaced by a single space, never by
  nothing: an empty replacement welds two tokens into one word, which puts an
  alphanumeric flush against the next key and is precisely what `scrub/1`'s
  `(?<![A-Za-z0-9])` lookbehind reads as "not a key". Every other run — at the
  start of a line, beside a space, a bracket, a quote, the end of the line — is
  replaced by nothing, so an ordinary colourised line strips to exactly what it
  always stripped to.
  """
  @spec strip_ansi(term()) :: term()
  def strip_ansi(text) when is_binary(text) do
    case Regex.split(@ansi_runs, text) do
      [whole] -> whole
      [first | rest] -> Enum.reduce(rest, first, &rejoin_across_run/2)
    end
  end

  def strip_ansi(other), do: other

  defp rejoin_across_run(next, acc) do
    if welds?(String.last(acc), String.first(next)) do
      acc <> @escape_delimiter <> next
    else
      acc <> next
    end
  end

  defp welds?(left, right) when is_binary(left) and is_binary(right),
    do: alnum?(left) and alnum?(right)

  defp welds?(_left, _right), do: false

  defp alnum?(<<c>>) when c in ?0..?9 or c in ?A..?Z or c in ?a..?z, do: true
  defp alnum?(_other), do: false

  @doc """
  Fold one RAW captured line: strip the control sequences, THEN redact.

  Idempotent, and non-binaries pass through unchanged.
  """
  # @canonical capability:build-log-write-scrub aka:scrub-at-write,recorder-scrub,redacted
  @spec raw(term()) :: term()
  def raw(value), do: value |> strip_ansi() |> scrub()

  @doc """
  Rewrite a recorded build log IN PLACE with `raw/1`, a line at a time.

  Returns `:ok` when the file on disk is folded (including the no-such-file case
  — there is nothing unscrubbed there), `{:error, reason}` when it is not. NEVER
  raises: this runs inside `DeployRunner`'s finalize, and a scrub that cannot
  complete must not lose the terminal record. It does not delete the log on
  failure either — the caller decides what to say about bytes it could not fold,
  and the honest marker for that is the ABSENCE of a scrub stamp on the record.

  The fold goes to a sibling temp file and `File.rename/2`s over the original, so
  a crash mid-fold leaves either the original bytes or the folded ones, never a
  half-written log. The temp file is created in the same directory (rename across
  filesystems is not atomic) and is removed on any error path.
  """
  # sobelow_skip ["Traversal.FileModule"]
  @spec scrub_file(term()) :: :ok | {:error, term()}
  def scrub_file(path) when is_binary(path) do
    if File.regular?(path) do
      do_scrub_file(path)
    else
      :ok
    end
  rescue
    error -> {:error, error}
  end

  def scrub_file(_other), do: {:error, :no_log_path}

  # sobelow_skip ["Traversal.FileModule"]
  defp do_scrub_file(path) do
    tmp = path <> ".scrub-#{System.unique_integer([:positive])}"

    try do
      case File.open(tmp, [:write, :binary]) do
        {:ok, out} ->
          try do
            path
            |> File.stream!()
            |> Enum.each(fn line -> IO.binwrite(out, fold_line(line)) end)
          after
            File.close(out)
          end

          case File.rename(tmp, path) do
            :ok -> :ok
            {:error, reason} -> fail(tmp, reason)
          end

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error -> fail(tmp, error)
    end
  end

  defp fail(tmp, reason) do
    _ = File.rm(tmp)
    {:error, reason}
  end

  # A streamed line carries its own trailing newline; folding it with the line
  # would let `strip_ansi/1`'s weld rule and the patterns' `\\s` classes see a
  # boundary that the next line's first byte does not actually have. Split it
  # off, fold the content, put it back byte-identically.
  defp fold_line(line) do
    case split_suffix(line) do
      {content, suffix} -> raw(content) <> suffix
    end
  end

  defp split_suffix(line) do
    cond do
      String.ends_with?(line, "\r\n") -> {binary_part(line, 0, byte_size(line) - 2), "\r\n"}
      String.ends_with?(line, "\n") -> {binary_part(line, 0, byte_size(line) - 1), "\n"}
      true -> {line, ""}
    end
  end
end
