defmodule BarkparkWeb.Contract.ErrorEnvelopeForkGuardTest do
  @moduledoc """
  THE DRIFT GUARD: no module under `api/lib` may build a §9 error envelope by
  hand. `BarkparkWeb.ErrorResponse` is the one emitter, and it is the one place
  `Barkpark.Content.Errors.stamp/2` runs — so it is the only path on which
  `request_id` (the handle an operator greps journalctl with) and the code-keyed
  `hint` are put on. A controller that writes `json(%{error: %{code: …}})`
  itself silently ships a refusal with neither.

  task-8737e2d7ff1884e0 swept 137 such sites out of 26 files. This file is why
  the fork cannot reopen: it fails the build on the 138th.

  ## Why the detector is a SHAPE, not a file list

  The row that filed the sweep counted with

      grep -rn 'error: %{code:' api/lib

  and got 83 hits in 22 files. That is a SINGLE-LINE spelling, and it was
  undercounting by 54: the very same envelope, written

      json(%{
        error: %{
          code: "…",

  does not match it. Eight files were invisible to the row's census for no
  reason but where `mix format` put a newline. So this guard normalises
  whitespace before it looks, and matches `error:` followed by a map whose
  first key is `code:` however it is laid out — you cannot get past it by
  pressing return.

  ## Why there is no allowlist

  An allowlist that grows stops discriminating; the exemptions here are RULES:

    * `error_response.ex` is the owner — it is where the envelope is supposed
      to be built.
    * Prose is not code. Heredocs (`\"\"\"…\"\"\"`) are stripped before the scan,
      which is what lets `controllers/error_json.ex` keep DOCUMENTING the
      envelope shape in its `@moduledoc` — the one hit in the original 83 that
      was never a construction site at all.

  Line numbers survive the stripping (heredoc bodies are replaced by blank
  lines), so a failure names file:line and the offending text.
  """
  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib", __DIR__)

  # The envelope's shape, after whitespace normalisation: the `error:` key of a
  # response body, whose value is a literal map opening on `code:`.
  @envelope ~r/error:\s*%\{\s*code:/

  # The owner. Not an exemption so much as the destination.
  @owner "barkpark_web/error_response.ex"

  test "no module under api/lib hand-builds a §9 error envelope" do
    offenders =
      @lib_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&String.ends_with?(&1, @owner))
      |> Enum.flat_map(&scan/1)

    assert offenders == [],
           """
           #{length(offenders)} hand-built error envelope(s) outside #{@owner}.

           Each of these builds `%{error: %{code: …}}` itself, so the response
           ships WITHOUT `request_id` and without the code-keyed `hint` —
           `Barkpark.Content.Errors.stamp/2` never runs on it. Route it through
           the one emitter instead:

             ErrorResponse.emit(conn, {:error, :not_found})            # a reason tuple
             ErrorResponse.emit_custom(conn, 422, code, message)       # a bespoke pair
             ErrorResponse.emit_fields(conn, 422, %{code: …, op: …})   # + top-level siblings

           #{Enum.map_join(offenders, "\n", fn {file, line, text} -> "  #{file}:#{line}  #{text}" end)}
           """
  end

  # A file's offending sites, as {relative path, line, the matched text}.
  #
  # The envelope is matched over a TWO-LINE window (the line the `error:` key
  # is on, plus the one under it) so the formatter's line break is not a hiding
  # place. The site is attributed to the `error:` line, and only that line can
  # open a site, so a two-line envelope is reported once, not twice.
  defp scan(path) do
    lines = path |> File.read!() |> strip_heredocs() |> String.split("\n")
    rel = Path.relative_to(path, @lib_root)

    lines
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {line, n} ->
      window = line <> " " <> Enum.at(lines, n, "")

      if opens_envelope?(line) and Regex.match?(@envelope, window) do
        [{rel, n, String.trim(line)}]
      else
        []
      end
    end)
  end

  # Only a line carrying the `error:` key itself can START a site — either with
  # the map inline, or with the map opening at end of line.
  defp opens_envelope?(line),
    do: Regex.match?(@envelope, line) or Regex.match?(~r/error:\s*%\{\s*$/, line)

  # Prose is not code: replace every heredoc body with blank lines so
  # @moduledoc/@doc text that DESCRIBES the envelope is not read as one, while
  # every later line keeps its real number.
  defp strip_heredocs(source) do
    Regex.replace(~r/"""(?s).*?"""/, source, fn match ->
      String.duplicate("\n", length(String.split(match, "\n")) - 1)
    end)
  end
end
