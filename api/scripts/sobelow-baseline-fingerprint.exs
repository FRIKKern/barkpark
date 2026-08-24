# The recompute half of sobelow-baseline-fingerprint-check.sh. See that file's
# header for the contract, the orthogonality argument and the exit codes.
#
# usage: elixir sobelow-baseline-fingerprint.exs <baseline-file> <api-dir>

[baseline_path, api_dir] = System.argv()

csrf_type = "Config.CSRF: Missing CSRF Protections"
https_type = "Config.HTTPS: HTTPS Not Enabled"
https_reason = "HTTPS configuration details could not be found in `prod.exs`."

# THE `config/prod.exs:0` ROW IS CORRECT AT 0. DO NOT "FIX" IT TO 1.
#
# Two lanes independently read a live Config.HTTPS finding at line 1 while the
# baseline row declares 0, and both flagged it as a real discrepancy worth
# settling. It is not one. They read the line from SARIF, and
# `lib/sobelow/finding_log.ex:154` is:
#
#     defp sarif_num(0), do: 1
#
# — because the SARIF schema requires startLine >= 1. The finding's actual
# `vuln_line_no` is the literal 0 hardcoded at `lib/sobelow/config/https.ex:48`
# (the finding is the ABSENCE of config, so there is no node to point at), and
# `finding.ex:60` hashes THAT, not the SARIF-rendered value. So 0 is exact:
# neither a file-level sentinel nor stale documentation.
#
# The consequence is why this comment exists. Recomputed here:
#     declared line 0 -> 2B5C077   (matches the stored hash)
#     SARIF's line 1  -> 4E639D3   (matches nothing)
# Editing that row to 1 to agree with SARIF would KILL a working waiver and red
# this very check. If this checker ever reds on that row, suspect the edit, not
# the row.

# Detector families whose vuln_source is a quoted AST node carrying line AND
# column metadata. That term is not in the baseline row and cannot be recovered
# from it, so these rows are SKIPPED here — never passed.
ast_prefixes = ["DOS.", "Traversal.", "XSS.", "RCE.", "SQL.", "CI.", "Misc."]

fingerprint = fn type, src, file, line ->
  [type, src, file, line] |> :erlang.phash2() |> Integer.to_string(16)
end

rows =
  baseline_path
  |> File.read!()
  |> String.split("\n")
  |> Enum.with_index(1)
  |> Enum.flat_map(fn {raw, lineno} ->
    trimmed = String.trim(raw)

    if trimmed == "" do
      []
    else
      case String.split(trimmed, ",") do
        [type, floc, hash] when hash != "" ->
          case String.split(floc, ":") do
            [f, l] ->
              case Integer.parse(l) do
                {n, ""} -> [%{type: type, file: f, line: n, hash: hash, at: lineno}]
                _ -> [%{malformed: trimmed, at: lineno}]
              end

            _ ->
              [%{malformed: trimmed, at: lineno}]
          end

        _ ->
          [%{malformed: trimmed, at: lineno}]
      end
    end
  end)

malformed = Enum.filter(rows, &Map.has_key?(&1, :malformed))
parsed = Enum.reject(rows, &Map.has_key?(&1, :malformed))

if malformed != [] do
  IO.puts(:stderr, "error: baseline rows sobelow's own parser would silently DROP")
  IO.puts(:stderr, "(lib/sobelow.ex:531-546 needs exactly 3 comma-separated fields):")
  Enum.each(malformed, fn m -> IO.puts(:stderr, "  line #{m.at}: #{m.malformed}") end)
  System.halt(2)
end

if parsed == [] do
  IO.puts(:stderr, "error: parsed ZERO baseline entries from #{baseline_path} — refusing to report a pass")
  System.halt(2)
end

# Reconstruct the pipeline-name atom Config.CSRF hashed, by reading the declared
# line of the declared file. A line holding no pipeline declaration cannot yield
# a vuln_source — which IS the drift signal.
pipeline_at = fn file, line ->
  path = Path.join(api_dir, file)

  if not File.regular?(path) do
    {:error, "no such file: #{path}"}
  else
    lines = String.split(File.read!(path), "\n")

    if line < 1 or line > length(lines) do
      {:error, "line #{line} is past the end of #{file} (#{length(lines)} lines)"}
    else
      text = Enum.at(lines, line - 1)

      case Regex.run(~r/^\s*pipeline[\s(]+:([a-zA-Z0-9_?!]+)/, text) do
        [_, name] ->
          {:ok, String.to_atom(name)}

        _ ->
          {:error,
           "line #{line} of #{file} holds no pipeline declaration" <>
             " (it holds: #{text |> String.trim() |> String.slice(0, 60)})"}
      end
    end
  end
end

classified =
  Enum.map(parsed, fn r ->
    cond do
      r.type == csrf_type ->
        case pipeline_at.(r.file, r.line) do
          {:ok, atom} -> Map.merge(r, %{class: :checked, src: atom, why: ":#{atom}"})
          {:error, msg} -> Map.merge(r, %{class: :unreconstructible, why: msg})
        end

      r.type == https_type ->
        path = Path.join(api_dir, r.file)

        if File.regular?(path) do
          Map.merge(r, %{class: :checked, src: https_reason, why: "constant reason string"})
        else
          Map.merge(r, %{class: :unreconstructible, why: "no such file: #{path}"})
        end

      Enum.any?(ast_prefixes, &String.starts_with?(r.type, &1)) ->
        Map.put(r, :class, :skipped)

      true ->
        Map.put(r, :class, :unclassified)
    end
  end)

unclassified = Enum.filter(classified, &(&1.class == :unclassified))

if unclassified != [] do
  IO.puts(:stderr, "error: baseline rows carry a detector type this checker cannot classify.")
  IO.puts(:stderr, "A new type must be classified by a human as row-reconstructible or AST-derived;")
  IO.puts(:stderr, "it is never silently skipped:")
  Enum.each(unclassified, fn r -> IO.puts(:stderr, "  #{r.type}  (#{r.file}:#{r.line})") end)
  System.halt(2)
end

checked = Enum.filter(classified, &(&1.class == :checked))
unrec = Enum.filter(classified, &(&1.class == :unreconstructible))
skipped = Enum.filter(classified, &(&1.class == :skipped))

Enum.each(skipped, fn r ->
  IO.puts("  SKIP  #{r.type} (#{r.file}:#{r.line}) — vuln_source is a quoted AST node, absent from the row")
end)

if checked == [] and unrec == [] do
  IO.puts(:stderr, "")
  IO.puts(:stderr, "error: ZERO reconstructible baseline entries — refusing to report a pass.")
  IO.puts(:stderr, "Every row was AST-derived, so this checker compared nothing. A checker with an")
  IO.puts(:stderr, "empty population has not passed; it has failed to run.")
  System.halt(2)
end

failures =
  Enum.flat_map(checked, fn r ->
    got = fingerprint.(r.type, r.src, r.file, r.line)

    if got == r.hash do
      IO.puts("  ok    #{r.file}:#{r.line} #{r.hash}  #{r.type} (#{r.why})")
      []
    else
      [{r, got}]
    end
  end) ++ Enum.map(unrec, fn r -> {r, nil} end)

if failures == [] do
  IO.puts("")

  IO.puts(
    "PASS: #{length(checked)} reconstructible baseline entries still hash to their stored fingerprint (#{length(skipped)} AST-derived rows skipped)"
  )

  System.halt(0)
end

IO.puts("")
IO.puts(:stderr, "FAIL: #{length(failures)} baseline row(s) no longer hash to the fingerprint they carry.")
IO.puts(:stderr, "Such a row waives NOTHING — sobelow --skip matches on the hash alone, so the finding")
IO.puts(:stderr, "it was reviewed and accepted for is being reported again as if it were new.")
IO.puts(:stderr, "")

Enum.each(failures, fn {r, got} ->
  IO.puts(:stderr, "  DEAD WAIVER  #{r.type}")
  IO.puts(:stderr, "               row says   #{r.file}:#{r.line},#{r.hash}")

  case got do
    nil -> IO.puts(:stderr, "               cannot recompute: #{r.why}")
    g -> IO.puts(:stderr, "               recomputes to #{g} from #{r.why} at line #{r.line}")
  end

  IO.puts(:stderr, "")
end)

IO.puts(:stderr, "Repair: re-anchor the row to the construct's CURRENT line and recompute its hash.")
IO.puts(:stderr, "Never re-add continue-on-error, and never regenerate the whole baseline to make this")
IO.puts(:stderr, "green — a regenerate silently absorbs findings nobody reviewed.")
System.halt(1)
