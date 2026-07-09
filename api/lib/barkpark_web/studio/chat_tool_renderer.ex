defmodule BarkparkWeb.Studio.ChatToolRenderer do
  @moduledoc """
  Terminal-faithful rendering of a Claude Code tool call inside the Studio chat
  (wave 7 — "the transcript IS the terminal"). Dispatch is on the persisted
  `metadata.input` SHAPE, never a tool name (names are host-binary-dependent).

  This slice owns the **TodoWrite living checklist** (charter D39): a TodoWrite
  tool call renders as ONE ☐/◐/☒ card that updates in place across a turn. The
  Recorder collapses every TodoWrite of a turn into one persisted row and the
  ChatLive reducer supersedes the in-memory card, so both live and replay reach
  this component with the turn's LATEST todo list.

  Shape-tolerant: accepts both the modern `{content, status, activeForm}` and the
  legacy `{content, status, priority, id}` item shapes; `pending → ☐`,
  `in_progress → ◐` (+ its `activeForm` as a live sub-line), `completed → ☒`.
  """

  use Phoenix.Component

  @doc """
  Normalize a TodoWrite-shaped `input` into a display list of
  `%{content, status, active_form}` — `status` is one of
  `:pending | :in_progress | :completed`. Anything non-list yields `[]` so a
  malformed frame degrades to an empty (but honest) card rather than raising.
  """
  @spec parse_todos(any()) :: [%{content: String.t(), status: atom(), active_form: String.t() | nil}]
  def parse_todos(%{"todos" => todos}) when is_list(todos) do
    todos
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn t ->
      %{
        content: to_string(t["content"] || ""),
        status: normalize_status(t["status"]),
        active_form: active_form(t)
      }
    end)
  end

  def parse_todos(_), do: []

  defp normalize_status("in_progress"), do: :in_progress
  defp normalize_status("completed"), do: :completed
  defp normalize_status(_), do: :pending

  # The modern shape carries a present-tense `activeForm` ("Running the tests")
  # shown as the live line under an in-progress item; the legacy shape has none.
  defp active_form(%{"activeForm" => af}) when is_binary(af) and af != "", do: af
  defp active_form(_), do: nil

  @doc """
  The living checklist card (charter D39). `@todos` is a `parse_todos/1` list;
  an empty list still renders the header + an honest "no items" line, never a
  blank box. Evergreen tokens only (`var(--…)`), so `studio-literal-check` passes.
  """
  attr :todos, :list, required: true

  def todo_card(assigns) do
    ~H"""
    <div style="font-family: var(--font-mono);">
      <div class="text-xs" style="overflow-wrap: anywhere;">
        <span style="color: var(--primary);">●</span>
        <span>Update todos</span>
        <span :if={@todos != []} style="opacity: 0.6;"> · <%= todo_progress(@todos) %></span>
      </div>
      <ul
        :if={@todos != []}
        style="list-style: none; margin: 4px 0 0; padding: 0 0 0 16px; display: flex; flex-direction: column; gap: 2px;"
      >
        <li :for={todo <- @todos} class="text-xs">
          <div style="display: flex; gap: 6px; align-items: baseline;">
            <span aria-hidden="true" style={todo_glyph_style(todo.status)}>
              <%= todo_glyph(todo.status) %>
            </span>
            <span style={todo_text_style(todo.status)}><%= todo.content %></span>
          </div>
          <div
            :if={todo.status == :in_progress and todo.active_form}
            class="text-dim"
            style="padding-left: 20px; opacity: 0.75;"
          >
            → <%= todo.active_form %>
          </div>
        </li>
      </ul>
      <div :if={@todos == []} class="text-xs text-dim" style="padding-left: 16px;">
        ⎿ no items
      </div>
    </div>
    """
  end

  # ── glyphs + styling (the terminal's checklist marks) ──────────────────────

  @doc "The checklist glyph for a todo status: ☐ todo · ◐ doing · ☒ done."
  @spec todo_glyph(atom()) :: String.t()
  def todo_glyph(:completed), do: "☒"
  def todo_glyph(:in_progress), do: "◐"
  def todo_glyph(_), do: "☐"

  defp todo_glyph_style(:completed), do: "flex: none; color: var(--ok);"
  defp todo_glyph_style(:in_progress), do: "flex: none; color: var(--primary);"
  defp todo_glyph_style(_), do: "flex: none; opacity: 0.6;"

  defp todo_text_style(:completed),
    do: "overflow-wrap: anywhere; opacity: 0.6; text-decoration: line-through;"

  defp todo_text_style(:in_progress),
    do: "overflow-wrap: anywhere; color: var(--primary); font-weight: 600;"

  defp todo_text_style(_), do: "overflow-wrap: anywhere;"

  # "1/3 done" — a compact honest progress summary; in-progress is not "done".
  defp todo_progress(todos) do
    done = Enum.count(todos, &(&1.status == :completed))
    "#{done}/#{length(todos)} done"
  end
end
