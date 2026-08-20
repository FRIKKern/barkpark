defmodule Barkpark.Chat.ToolRows do
  @moduledoc """
  Pure, surface-neutral derivations for the chat tool/todo rows — the shared
  core both the Studio/reader render (`Barkpark.PortableDoc.Render.Components`)
  AND the web renderer (`BarkparkWeb.Studio.ChatToolRenderer`) call.

  These functions were forked into `ChatToolRenderer` (a `BarkparkWeb`
  Phoenix.Component) originally, and `Components` (core render) reached UP into
  web to reuse them — a core→web dependency inversion. They live here now so
  core no longer depends on web; `ChatToolRenderer` keeps its public
  `classify/1`/`diff?/1`/`parse_todos/1`/`todo_glyph/1` as thin delegations, so
  every existing caller (chat_live.ex, its own HEEx) is unchanged.

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

  No behaviour change is implied by this extraction: the derivations are the
  byte-identical originals, so the cross-surface golden fixture
  (`mix barkpark.chat.gen_golden_toolrows`) regenerates unchanged.
  """

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
  Normalize a TodoWrite-shaped `input` into a display list of
  `%{content, status, active_form}` — `status` is one of
  `:pending | :in_progress | :completed`. Anything non-list yields `[]` so a
  malformed frame degrades to an empty (but honest) card rather than raising.
  """
  @spec parse_todos(any()) :: [
          %{content: String.t(), status: atom(), active_form: String.t() | nil}
        ]
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

  @doc "The checklist glyph for a todo status: ☐ todo · ◐ doing · ☒ done."
  @spec todo_glyph(atom()) :: String.t()
  def todo_glyph(:completed), do: "☒"
  def todo_glyph(:in_progress), do: "◐"
  def todo_glyph(_), do: "☐"
end
