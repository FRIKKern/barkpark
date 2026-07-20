defmodule Barkpark.AsyncEnvSeamScan do
  @moduledoc """
  The shape ban behind the async-env-seam ratchet, shared by BOTH umbrella test
  trees (`cloud/test` and `api/test`).

  ## What it bans, and why it bans a SHAPE and not a key set

  `Application.put_env/3` writes ONE value for the whole node. Inside an
  `async: true` module that is not a per-test stub — it is a global swap held
  for as long as the test (or its `describe` setup) runs, and EVERY other async
  test running at that instant reads it. Two such swaps have been proven live
  races in this repo (`:site_box_relay`, and Cloudflare's `:client`).

  The previous guard tried to name the hazardous KEYS. That is not answerable
  from source text, and the attempt failed in both directions:

    * FALSE NEGATIVE — it matched the literal `Application.put_env(:barkpark_cloud, OAuth`,
      so the equivalent fully-qualified `..., BarkparkCloud.OAuth, ...` walked
      straight past it. Worse, reads are TRANSITIVE: two of the four modules
      that read `:site_box_relay` contain zero textual mention of BoxRelay —
      they reach it through lib call chains. `mix xref` cannot close the gap
      either: `cloud/mix.exs` `elixirc_paths(:test)` is `["lib", "test/support"]`,
      so `*_test.exs` is never compiled and the call edge does not exist.
    * FALSE POSITIVE — matching on a key PREFIX named `OAuthStub`, the repo's
      explicitly async-SAFE process-dictionary stub, as an `OAuth` offender.

  So this scanner asks the one question the source text CAN answer: does a
  `*_test.exs` declare `async: true` AND call `Application.put_env/delete_env`?
  No key list, no false-negative class, one reason to red.

  ## The escape hatch

  A legitimate `async: true` swap of a genuinely private key stays expressible.
  Annotate the file with a reasoned marker and the scanner honours it:

      # async-env-seam-allow: <why this key can never be read by a concurrent module>

  The reason is REQUIRED — a bare marker is itself an offence, reported as
  `:allowlisted_without_reason`, so the hatch cannot decay into a mute switch.

  ## Reading the source honestly

  Four of this repo's test files discuss `Application.put_env` in their
  `@moduledoc` precisely to explain why they are `async: false` — naming those
  would be the same lying-gate failure in a new coat. So the scanner strips
  heredocs and comments before matching, and matches the module's actual
  `use ..., async: true` declaration line rather than any prose mention of the
  phrase (`media_test.exs` says "async: true" in prose while being `async: false`).
  """

  @call_re ~r/Application\.(?:put_env|put_all_env|delete_env)\s*\(/
  @async_true_re ~r/^\s*use\s+[A-Z][\w.]*.*?\basync:\s*true\b/
  @allow_re ~r/^\s*#\s*async-env-seam-allow:(?<reason>.*)$/

  @doc """
  Repo root, derived from this script's own location (`<root>/scripts`).
  """
  def repo_root, do: Path.expand("..", __DIR__)

  @doc """
  The two test roots this ratchet covers, as absolute paths.
  """
  def default_roots do
    [Path.join(repo_root(), "cloud/test"), Path.join(repo_root(), "api/test")]
  end

  @doc """
  Scan `roots` (absolute directories). Returns
  `%{scanned: %{root => count}, offenders: [%{path:, line:, kind:, snippet:}]}`.

  A root that does not exist scans as `:missing` — callers assert on that
  rather than passing vacuously, because a path typo must never read as green.
  """
  def scan(roots \\ default_roots()) do
    Enum.reduce(roots, %{scanned: %{}, offenders: []}, fn root, acc ->
      if File.dir?(root) do
        files = Path.wildcard(Path.join(root, "**/*_test.exs"))

        offenders =
          files
          |> Enum.flat_map(fn path ->
            case inspect_source(path, File.read!(path)) do
              nil -> []
              offence -> [Map.put(offence, :path, Path.relative_to(path, repo_root()))]
            end
          end)

        %{
          acc
          | scanned: Map.put(acc.scanned, root, length(files)),
            offenders: acc.offenders ++ offenders
        }
      else
        %{acc | scanned: Map.put(acc.scanned, root, :missing)}
      end
    end)
  end

  @doc """
  The predicate itself, over one file's source text. `nil` when clean, otherwise
  a map describing the offence. Exposed so the guard tests can prove it able to
  fail on synthetic sources without touching the filesystem.
  """
  def inspect_source(path, source) do
    code = strip_prose(source)

    cond do
      not async_true?(code) ->
        nil

      is_nil(call_line(code)) ->
        nil

      true ->
        case allow_marker(source) do
          :none ->
            {line, snippet} = call_line(code)
            %{path: path, line: line, kind: :async_true_global_env_swap, snippet: snippet}

          :blank_reason ->
            %{
              path: path,
              line: allow_marker_line(source),
              kind: :allowlisted_without_reason,
              snippet: "# async-env-seam-allow:"
            }

          {:ok, _reason} ->
            nil
        end
    end
  end

  # --- internals ---------------------------------------------------------

  # Blank out heredocs and whole-line comments, PRESERVING line numbering, so a
  # `@moduledoc` that discusses the hazard is never mistaken for committing it.
  defp strip_prose(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, in_heredoc? ->
      toggles? = rem(count_heredoc_marks(line), 2) == 1

      case {in_heredoc?, toggles?} do
        # closing delimiter — the line itself is still prose
        {true, true} -> {"", false}
        {true, false} -> {"", true}
        # opening delimiter — everything after it on this line is prose
        {false, true} -> {"", true}
        {false, false} -> {strip_comment(line), false}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp count_heredoc_marks(line) do
    line |> String.split(~s(""")) |> length() |> Kernel.-(1)
  end

  # Drop a trailing comment only when no quote precedes the `#`, so a `#` living
  # inside a string literal can never silently erase a real call after it.
  defp strip_comment(line) do
    case :binary.match(line, "#") do
      :nomatch ->
        line

      {idx, _} ->
        before = binary_part(line, 0, idx)

        if String.contains?(before, ~s(")) or String.ends_with?(before, "?"),
          do: line,
          else: before
    end
  end

  defp async_true?(code) do
    code
    |> String.split("\n")
    |> join_use_continuations()
    |> Enum.any?(&Regex.match?(@async_true_re, &1))
  end

  # `use ExUnit.Case, async: true` is normally one line, but the formatter wraps
  # it when the line is long:
  #
  #     use SomeVeryLong.NamespacedCase,
  #       async: true
  #
  # A per-line match sees neither half as a declaration and the module walks
  # through the ratchet. So a line whose trimmed form ends in `,` is joined to
  # the next before matching. Only the JOINED text is used for the async
  # decision — `call_line/1` still reads the original lines, so reported line
  # numbers stay true to the file.
  defp join_use_continuations(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      case acc do
        [prev | rest] ->
          if String.ends_with?(String.trim_trailing(prev), ",") do
            [prev <> " " <> String.trim_leading(line) | rest]
          else
            [line | acc]
          end

        [] ->
          [line]
      end
    end)
    |> Enum.reverse()
  end

  defp call_line(code) do
    code
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(fn {line, n} ->
      if Regex.match?(@call_re, line), do: {n, String.trim(line)}
    end)
  end

  defp allow_marker(source) do
    source
    |> String.split("\n")
    |> Enum.find_value(:none, fn line ->
      case Regex.named_captures(@allow_re, line) do
        nil -> nil
        %{"reason" => reason} -> if String.trim(reason) == "", do: :blank_reason, else: {:ok, String.trim(reason)}
      end
    end)
  end

  defp allow_marker_line(source) do
    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.find_value(0, fn {line, n} -> if Regex.match?(@allow_re, line), do: n end)
  end

  @doc """
  Human-readable failure body for an offender list.
  """
  def explain(offenders) do
    """
    An `async: true` test module swaps node-global Application env:

    #{Enum.map_join(offenders, "\n", &"  #{&1.path}:#{&1.line} — #{&1.kind}\n      #{&1.snippet}")}

    `Application.put_env/3` writes ONE value for the WHOLE NODE, so the swap is
    also in force for every other async test running at that instant — the
    order-dependent red that teaches readers to dismiss a required gate.

    Fix it by isolation, not by widening this guard:

      * scope the swap to the CALLING process (see the FailingRegistry pattern
        in cloud/test/barkpark_cloud/billing_reconcile_isolation_test.exs, or
        OAuthStub — both delegate to the real impl unless the caller's process
        dictionary opts in), or
      * call the implementation module directly instead of swapping the
        dispatcher's config, or
      * set the module `async: false`.

    If the key is genuinely private and can never be read by a concurrent
    module, annotate the file and say why:

      # async-env-seam-allow: <reason>
    """
  end
end
