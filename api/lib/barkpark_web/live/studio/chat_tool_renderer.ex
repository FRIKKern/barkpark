defmodule BarkparkWeb.Studio.ChatToolRenderer do
  @moduledoc """
  Renders a Studio-chat tool-call row the way the Claude Code terminal does:
  file-mutating tool calls become real colored line diffs (`+` added, `-`
  removed, unchanged context dim) beneath the `●` tool header.

  ## Dispatch on SHAPE, never on tool NAME

  The tool name is host-binary-dependent — the cmux fork emits `Agent` where
  vanilla Claude Code emits `Task`, and lacks `TodoWrite`/`MultiEdit` entirely.
  So `classify/1` keys on the INPUT MAP's shape (wire-proven on v2.1.205):

    * `%{"file_path", "old_string", "new_string"}`  → `:edit`  (line diff)
    * `%{"file_path", "content"}`                    → `:write` (all-added)
    * `%{"file_path", "edits" => [_ | _]}`           → `:multi_edit` (stacked
      hunks, defensive — unverified on this host)
    * anything else                                   → `:generic` (no diff;
      the caller keeps the existing `●`/`⎿` row)

  A tool renamed by the host binary but carrying an Edit-shaped input STILL
  renders a diff — the whole point of shape dispatch.

  ## One diff engine

  Diffs come from `Barkpark.Papers.TextDiff.diff_lines/2` (DP-LCS, `op ∈ =/+/-`
  per line). We never add a second Myers/diff engine (capability-dup). Chrome is
  emitted design tokens only (`--ok`/`--ok-soft` add, `--danger`/`--danger-soft`
  removed) so `scripts/studio-literal-check.sh` stays green.

  ## Honest truncation is a RENDER concern only

  A diff over `@collapsed_budget` lines collapses behind a `<details>` (exactly
  like the existing `⎿` output block): the first ~20 lines stay in the summary
  with an accurate `+N more lines`, the remainder reveals on expand. Persistence
  (recorder.ex) keeps the FULL input verbatim, so a reopened session replays the
  identical diff — truncation never touches the store.
  """
  use Phoenix.Component

  alias Barkpark.Papers.TextDiff

  # Lines shown before a diff collapses behind a details/summary. The terminal
  # shows a compact hunk; anything larger folds with an honest overflow count.
  @collapsed_budget 20

  @doc """
  Classify a tool-call input map by SHAPE. Returns
  `:edit | :write | :multi_edit | :generic`. Order matters: the `edits` list is
  checked before the scalar shapes so a MultiEdit is never mistaken for a Write.
  """
  @spec classify(map() | any()) :: :edit | :write | :multi_edit | :generic
  def classify(input) when is_map(input) do
    cond do
      is_binary(input["file_path"]) and is_list(input["edits"]) and input["edits"] != [] ->
        :multi_edit

      is_binary(input["file_path"]) and is_binary(input["old_string"]) and
          is_binary(input["new_string"]) ->
        :edit

      is_binary(input["file_path"]) and is_binary(input["content"]) ->
        :write

      true ->
        :generic
    end
  end

  def classify(_), do: :generic

  @doc "True when the input is a file-mutation shape we render as a diff."
  @spec diff?(map() | any()) :: boolean()
  def diff?(input), do: classify(input) != :generic

  @doc """
  Render the diff for a diff-shaped tool input. A non-diff shape (or an input
  that produces no diff lines) renders nothing — the caller's generic `●`/`⎿`
  row already stands on its own.
  """
  attr :input, :map, required: true

  def tool_diff(assigns) do
    lines = build_lines(assigns.input)
    total = length(lines)
    {head, rest} = Enum.split(lines, @collapsed_budget)

    assigns =
      assign(assigns,
        head: head,
        rest: rest,
        added: Enum.count(lines, &(&1.op == "+")),
        removed: Enum.count(lines, &(&1.op == "-")),
        overflow: max(total - @collapsed_budget, 0),
        over?: total > @collapsed_budget,
        empty?: total == 0
      )

    ~H"""
    <div
      :if={not @empty?}
      class="text-xs"
      style="font-family: var(--font-mono); margin: 4px 0 0 16px; background: var(--muted-surface); border-radius: 6px; padding: 6px 8px; overflow-x: auto; line-height: 1.5;"
    >
      <div class="text-dim" style="font-size: 11px; margin-bottom: 4px;">
        <span style="color: var(--ok);">+<%= @added %></span>
        <span style="color: var(--danger);">−<%= @removed %></span>
      </div>
      <%= if @over? do %>
        <details>
          <summary style="cursor: pointer; list-style: none;">
            <.diff_rows lines={@head} />
            <div class="text-dim" style="font-size: 11px; padding: 1px 0;">
              … +<%= @overflow %> more lines
            </div>
          </summary>
          <.diff_rows lines={@rest} />
        </details>
      <% else %>
        <.diff_rows lines={@head} />
      <% end %>
    </div>
    """
  end

  # One rendered `<div>` per diff line, tokenized by op. Context lines are dim;
  # added/removed carry the soft-background + role-color pair.
  attr :lines, :list, required: true

  defp diff_rows(assigns) do
    ~H"""
    <div
      :for={line <- @lines}
      style={row_style(line.op)}
    ><%= prefix(line.op) %><%= line.text %></div>
    """
  end

  # ── internals ──────────────────────────────────────────────────────────────

  # Build the flat diff-line list from the input shape, reusing TextDiff — the
  # ONE line-diff engine. `diff_lines/2` tolerates nil, so a defensively-missing
  # MultiEdit field yields no lines rather than crashing.
  defp build_lines(input) do
    case classify(input) do
      :edit ->
        TextDiff.diff_lines(input["old_string"], input["new_string"])

      :write ->
        # A fresh Write is a pure addition: every content line is `+`.
        TextDiff.diff_lines("", input["content"])

      :multi_edit ->
        multi_edit_lines(input["edits"])

      :generic ->
        []
    end
  end

  # Stack each edit's hunk, separated by a faint gap row. Defensive: MultiEdit is
  # unverified on this host, so a malformed edit entry contributes an empty hunk
  # instead of raising.
  defp multi_edit_lines(edits) when is_list(edits) do
    edits
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn e -> TextDiff.diff_lines(e["old_string"], e["new_string"]) end)
    |> Enum.reject(&(&1 == []))
    |> Enum.intersperse([%{op: "gap", text: ""}])
    |> List.flatten()
  end

  defp multi_edit_lines(_), do: []

  defp row_style("+"),
    do:
      "color: var(--ok); background: var(--ok-soft); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;"

  defp row_style("-"),
    do:
      "color: var(--danger); background: var(--danger-soft); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;"

  defp row_style("gap"),
    do: "border-top: 1px solid var(--border-muted); margin: 4px 0; height: 0;"

  defp row_style(_),
    do:
      "color: var(--fg-dim); white-space: pre-wrap; overflow-wrap: anywhere; padding: 0 2px;"

  defp prefix("+"), do: "+ "
  defp prefix("-"), do: "- "
  defp prefix("gap"), do: ""
  defp prefix(_), do: "  "
end
