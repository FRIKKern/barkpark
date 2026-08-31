defmodule Barkpark.TextDiff do
  @moduledoc """
  Line-level LCS diff at the rail surface — W7c step 3 / w7-11 /
  paper-158. The /v1/rail/diff endpoint serves the goal-path rail's
  diff modal by computing hunks between two events' html_payloads.

  This module is the **rail-shaped wrapper** around the already-vendored
  `Barkpark.Papers.TextDiff` (which is itself a faithful port of the
  classic JS line-diff algorithm). The wrapper exists because:

    * `Papers.TextDiff` lives under the *papers* namespace — the rail is a
      separate consumer at the task substrate level and shouldn't
      reach across into another bounded context for a name.
    * The rail's wire shape uses the `{op, text}` form (`+` / `-` / ` `
      for "context") — the brief's hunk schema. The papers port emits
      `{op, text}` with op∈`=|+|-`; we translate `=` → `" "` so the wire
      reads as it does in the JS daemon's old `/diff` response.

  Algorithm and edge-cases (nil-safety, trailing newline drop, "removed
  preferred on tie" backtrack) come from the underlying port verbatim.
  Do not re-port — keep one DP-LCS implementation.

  Public surface:

      * `hunks(old, new)`         → [{op, text}] with op ∈ `"+"` | `"-"` | `" "`
      * `format_diff_html(hunks)` → "<pre class=\"diff\">…</pre>"  (rail style)
  """

  alias Barkpark.Papers.TextDiff, as: Port

  @type hunk :: %{op: String.t(), text: String.t()}

  @doc """
  Line-LCS diff returning rail-shaped hunks. `op` is one of:
  `"+"` (added), `"-"` (removed), `" "` (context — note the SPACE, matching
  the JS rail's pipe shape).
  """
  @spec hunks(String.t() | nil, String.t() | nil) :: [hunk()]
  def hunks(old_text, new_text) do
    Port.diff_lines(old_text, new_text)
    |> Enum.map(fn
      %{op: "=", text: t} -> %{op: " ", text: t}
      %{op: op, text: t} -> %{op: op, text: t}
    end)
  end

  @doc """
  Render rail hunks as the `<pre class="diff">` block the daemon used to
  emit. Each line carries the `diff-context|diff-added|diff-removed` class
  and a 2-char prefix, escape-encoded.
  """
  @spec format_diff_html([hunk()]) :: String.t()
  def format_diff_html(hunks) when is_list(hunks) do
    body =
      hunks
      |> Enum.map(fn %{op: op, text: text} ->
        {cls, prefix} =
          case op do
            " " -> {"diff-context", "  "}
            "+" -> {"diff-added", "+ "}
            "-" -> {"diff-removed", "- "}
          end

        ~s(<div class="diff-line ) <> cls <> ~s(">) <> esc(prefix <> text) <> "</div>"
      end)
      |> Enum.join("")

    ~s(<pre class="diff">) <> body <> "</pre>"
  end

  defp esc(s) when is_binary(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
