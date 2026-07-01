defmodule Barkpark.Tasks.Criteria do
  @moduledoc """
  Per-task acceptance-criteria progress — the `{met, total}` counter behind
  the task-chip `2/5` segment (wire spec
  `portabledoc-inline-liveref-taskchip-wire` §4) and the `criteria_progress`
  field on the `/v1/tasks` envelopes (lvw-t6).

  Semantics (wire §4, amended — read & surface only, never a gate):

    * an entry counts as MET only when its `met` key is EXACTLY `true` —
      a missing `met`, `"yes"`, `1`, or any other non-`true` value counts
      as UNMET, never crashes. `Barkpark.Tasks.Validation` enforces only
      "list of maps" (top-level shape), so entries may be arbitrary garbage;
      a non-map entry also counts as unmet.
    * criteria absent, `nil`, `[]`, or non-list garbage → `nil` — the
      consumer OMITS the progress segment entirely, never renders `0/0`.

  Pure functions, no DB. The single owner of this computation — the t7
  chip resolver (Elixir pre-resolve pass), the tasks API envelope, and the
  Studio checklist badge all call here.
  """

  alias Barkpark.Content.Document

  @doc """
  Computes `%{met: m, total: t}` from a task's content map (or `%Document{}`),
  reading `content.acceptance_criteria`. Returns `nil` when criteria are
  absent, empty, or not a list — callers omit the segment, not "0/0".
  """
  # @canonical capability:task-criteria-progress aka:met,total,acceptance_criteria,checklist,progress doc:docs/setup/TASK-SYSTEM.md
  @spec progress(Document.t() | map() | nil) ::
          %{met: non_neg_integer(), total: pos_integer()} | nil
  def progress(%Document{content: content}), do: progress(content)

  def progress(%{} = content) do
    content
    |> fetch(:acceptance_criteria)
    |> of_list()
  end

  def progress(_), do: nil

  @doc """
  Computes `%{met: m, total: t}` from a raw `acceptance_criteria` value
  (the `[%{"criterion" => …, "met" => …, "evidence" => …}]` list). Same
  tolerance contract as `progress/1`; `nil` for anything but a non-empty
  list.
  """
  @spec of_list(term()) :: %{met: non_neg_integer(), total: pos_integer()} | nil
  def of_list(list) when is_list(list) and list != [] do
    %{met: Enum.count(list, &met?/1), total: length(list)}
  end

  def of_list(_), do: nil

  # `met` must be EXACTLY boolean true (wire §4). Entries arrive string-keyed
  # from the JSONB store; tolerate atom keys for in-memory callers, mirroring
  # Validation's fetch. Non-map entries are unmet by definition.
  defp met?(%{} = entry), do: fetch(entry, :met) == true
  defp met?(_), do: false

  # String key first (the persisted shape), atom fallback — via Map.fetch so a
  # present-but-false value is not masked (the Validation.fetch precedent).
  defp fetch(map, key) when is_atom(key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, v} -> v
      :error -> Map.get(map, key)
    end
  end
end
