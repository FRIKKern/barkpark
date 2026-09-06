defmodule Barkpark.PortableDoc.TextDiff do
  @moduledoc """
  Pure line-level diff — a faithful Elixir port of the classic JS
  line-diff algorithm (dynamic-programming LCS over the two line
  arrays). No `Repo`, no PubSub, no deps; backs the P6.U3 diff modal where
  shift-clicking two goal-path rail nodes opens a line-diff of their event
  `payload_html`.

  ## Why it lives in the kernel

  It used to be `Barkpark.Papers.TextDiff`, and `PortableDoc.Render.Components`
  aliased it to build `chat-tool-diff` rows — a KERNEL module reaching UP into
  the *papers* feature (boundary edge `portable_doc>papers`,
  task-9d06bca37668f76a). The dependency was real but the placement was wrong:
  this module has zero deps of its own (no `Repo`, no schema, nothing from
  Papers), and it is the ONE line diff every surface shares — the renderer, the
  Studio chat tool rows, the rail wrapper (`Barkpark.TextDiff`) and the bulldocs
  diff modal. So the function moved DOWN to the layer that needs it rather than
  the caller reaching up. `Barkpark.Papers.TextDiff` remains as a thin
  delegating façade so the feature-side callers keep their existing name.

  ## Semantics (matched to the classic JS line-diff algorithm)

    * `split_lines/1` splits on `"\\n"` and drops a single trailing empty
      line (so `"a\\nb\\n"` is two lines, not three). `nil`/`""` → `[]`.
    * `diff_lines/2` returns `[%{op: op, text: line}]` with
      `op ∈ {"=", "+", "-"}` — context / added / removed. The DP backtrack
      mirrors the JS: on a mismatch, prefer "removed" when
      `dp[i-1][j] >= dp[i][j-1]`, else "added".
    * `format_diff_html/1` emits a `<pre class="bp-diff">` of one
      `<span class="bp-diff-line bp-diff-{add|del|ctx}">` per line, prefixed
      `+ ` / `- ` / `  ` and **HTML-escaped** — never raw, no `<script>`.

  The grid is O(n·m); for a few hundred lines of `payload_html` either side
  that is trivial. To keep the public `/papers/:slug` open-diff from building a
  10^7–10^8-entry map on two multi-thousand-line payloads (unauthenticated,
  per-connection-repeatable OOM), inputs above `@max_diff_lines` per side or
  `@max_diff_cells` total fall back to a coarse whole-block diff (all old lines
  removed, then all new lines added) — the exact shape the backtrack already
  emits at its border, so output stays byte-identical below the cap.
  """

  # Size guard for `diff_chunks/2` — above either bound we skip the O(m·n) grid
  # and emit the degraded whole-block diff instead. See @moduledoc.
  @max_diff_lines 2000
  @max_diff_cells 4_000_000

  @doc """
  Line-level LCS diff of two strings. Returns a list of
  `%{op: "=" | "+" | "-", text: line}` chunks in document order.

  `nil` / empty inputs are handled safely (an empty side contributes no
  lines): identical text yields all `"="`, a pure addition all `"+"`, a pure
  removal all `"-"`.
  """
  @spec diff_lines(String.t() | nil, String.t() | nil) :: [%{op: String.t(), text: String.t()}]
  def diff_lines(old_text, new_text) do
    a = split_lines(old_text)
    b = split_lines(new_text)
    diff_chunks(a, b)
  end

  @doc """
  Render diff chunks (from `diff_lines/2`) to an HTML string:
  `<pre class="bp-diff">` wrapping one escaped `<span>` per line. Every line
  is HTML-escaped, so untrusted `payload_html` is shown as text, never run.
  """
  @spec format_diff_html([%{op: String.t(), text: String.t()}]) :: String.t()
  def format_diff_html(chunks) when is_list(chunks) do
    lines =
      chunks
      |> Enum.map(fn %{op: op, text: text} ->
        {cls, prefix} = class_and_prefix(op)
        ~s(<span class="bp-diff-line #{cls}">#{escape(prefix <> text)}</span>)
      end)
      |> Enum.join("")

    ~s(<pre class="bp-diff">#{lines}</pre>)
  end

  # ── internals ───────────────────────────────────────────────────────────

  # Mirror splitLines(): split on "\n", drop a single trailing empty line.
  # nil / "" → [].
  defp split_lines(nil), do: []
  defp split_lines(""), do: []

  defp split_lines(s) when is_binary(s) do
    arr = String.split(s, "\n")

    case List.last(arr) do
      "" -> arr |> Enum.reverse() |> tl() |> Enum.reverse()
      _ -> arr
    end
  end

  # Classic DP-LCS over the two line arrays, then backtrack to chunks. We index
  # the lines as 1-based maps so the DP grid lookups are O(1) (Elixir lists are
  # not random-access). The DP table is a map keyed by {i, j}; absent keys
  # (any i==0 or j==0 border) read as 0 — the JS Int32Array's zero border.
  defp diff_chunks([], []), do: []

  defp diff_chunks(a, b) do
    m = length(a)
    n = length(b)

    if m > @max_diff_lines or n > @max_diff_lines or m * n > @max_diff_cells do
      # Oversized input: skip the O(m·n) grid and emit the coarse whole-block
      # diff (every old line removed, then every new line added) — byte-identical
      # to what backtrack emits at its border, but O(m + n) memory.
      Enum.map(a, &%{op: "-", text: &1}) ++ Enum.map(b, &%{op: "+", text: &1})
    else
      ai = index_map(a)
      bi = index_map(b)
      dp = build_dp(ai, bi, m, n)
      backtrack(ai, bi, dp, m, n, [])
    end
  end

  # %{1 => line1, 2 => line2, …}
  defp index_map(list) do
    list
    |> Enum.with_index(1)
    |> Map.new(fn {line, idx} -> {idx, line} end)
  end

  defp dp_at(_dp, i, j) when i == 0 or j == 0, do: 0
  defp dp_at(dp, i, j), do: Map.get(dp, {i, j}, 0)

  # Fill dp[i][j] for 1..m × 1..n exactly as the JS double loop does.
  defp build_dp(ai, bi, m, n) do
    Enum.reduce(1..m//1, %{}, fn i, dp ->
      Enum.reduce(1..n//1, dp, fn j, dp ->
        value =
          if Map.fetch!(ai, i) == Map.fetch!(bi, j) do
            dp_at(dp, i - 1, j - 1) + 1
          else
            left = dp_at(dp, i - 1, j)
            up = dp_at(dp, i, j - 1)
            if left >= up, do: left, else: up
          end

        Map.put(dp, {i, j}, value)
      end)
    end)
  end

  # Backtrack from (m, n) to (0, 0), prepending chunks so the final list is in
  # forward document order (the JS builds reversed then reverses; prepending
  # gives the same order without a final reverse).
  defp backtrack(_ai, _bi, _dp, 0, 0, acc), do: acc

  defp backtrack(ai, bi, dp, i, j, acc) when i > 0 and j > 0 do
    a_line = Map.fetch!(ai, i)
    b_line = Map.fetch!(bi, j)

    cond do
      a_line == b_line ->
        backtrack(ai, bi, dp, i - 1, j - 1, [%{op: "=", text: a_line} | acc])

      dp_at(dp, i - 1, j) >= dp_at(dp, i, j - 1) ->
        backtrack(ai, bi, dp, i - 1, j, [%{op: "-", text: a_line} | acc])

      true ->
        backtrack(ai, bi, dp, i, j - 1, [%{op: "+", text: b_line} | acc])
    end
  end

  defp backtrack(ai, bi, dp, i, 0, acc) when i > 0 do
    backtrack(ai, bi, dp, i - 1, 0, [%{op: "-", text: Map.fetch!(ai, i)} | acc])
  end

  defp backtrack(ai, bi, dp, 0, j, acc) when j > 0 do
    backtrack(ai, bi, dp, 0, j - 1, [%{op: "+", text: Map.fetch!(bi, j)} | acc])
  end

  defp class_and_prefix("="), do: {"bp-diff-ctx", "  "}
  defp class_and_prefix("+"), do: {"bp-diff-add", "+ "}
  defp class_and_prefix("-"), do: {"bp-diff-del", "- "}

  # Escape the five HTML-significant chars in `& < > " '` order (ampersand
  # first so we never double-escape). Mirrors Barkpark.PortableDoc.Render's
  # escape_html/1 — kept local so TextDiff has zero deps.
  defp escape(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
