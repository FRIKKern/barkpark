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

  @doc """
  Reports whether ONE acceptance-criteria entry is a MERGE GATE — a row the
  LEAD closes when the PR merges, never the builder. `Tasks.Stamp` refuses a
  builder's `met` flip on such a row without the explicit `--merge-gated`
  override (a builder flipping it fabricates a done before the PR exists).

  STRUCTURAL FIRST, PROSE ONLY AS A FALLBACK — and the fallback is deliberately
  WIDE. Read this before "improving" it; the narrowing has been proposed and
  measured-refuted twice.

    * `merge_gate: true`  → GATE. The authoritative signal, the same one
      `Tasks.Close.autostamp_merge_gate/6` keys on. Decides ALONE: a flagged
      row is a gate even when its prose never says so (measured 2026-08-22:
      **14 flagged criteria carry no marker wording at all** — every one of
      them a silent false PERMIT under a text-only guard).
    * `merge_gate: false` → NOT A GATE. An EXPLICIT author declaration that
      this row merely TALKS ABOUT merge-gating. This is the exemption door for
      the prose fallback's false positives: it is opt-in, per-row, and can
      never widen the hole, because only an author writing `false` can open it.
    * key absent → the prose convention decides, via `@merge_gate_worded`.

  WHY THE PROSE ARM IS WIDE AND MUST STAY WIDE. The two error directions are
  NOT symmetric: a false positive is a LOUD refusal the caller can override in
  one flag, while a false negative is a SILENT permit that lets a builder
  fabricate a lead's merge close and nothing ever objects. Measured over the
  live corpus (31090 criteria, 2026-08-22):

    * the wide match hits 1853 criteria, of which **65 merely MENTION**
      merge-gating — a 3.51% false-POSITIVE rate, all loud, all overridable,
      and all permanently fixable by the author with `merge_gate: false`.
    * position does NOT separate the two: of those 65 mentions one LEADS with
      the marker, while 43 genuine gates carry it mid-sentence
      ("LEAD-OWNED (merge-gated): PR merged to main"). An anchored/leading-only
      predicate would therefore MISS 43 real gates to save 64 loud refusals —
      trading a loud error for a silent one, the wrong way round.

  The `MERGE GATE` (no "D") spelling is included for the same reason: it was
  absent from the original predicate, and adding it converts **120 genuine
  gates that this guard silently permitted** into refusals, at a cost of 18
  further loud false positives. `Plugins.Tasks`'s authoring nag keeps its OWN,
  deliberately NARROW leading-position regex — do not unify them: there a
  false positive nags an innocent author, so the asymmetry is reversed.
  """
  # @canonical capability:merge-gate-criterion-predicate aka:merge_gated,merge-gated,isMergeGatedText,merge gate,lead closes,stampMergeGateBlocked doc:docs/setup/TASK-SYSTEM.md
  @spec merge_gated?(term()) :: boolean()
  def merge_gated?(%{} = entry) do
    case fetch(entry, :merge_gate) do
      true -> true
      false -> false
      _ -> worded_merge_gate?(fetch(entry, :criterion))
    end
  end

  def merge_gated?(_), do: false

  # An explicit SUPERSET of the predicate this replaced (`isMergeGatedText`:
  # contains "MERGE-GATED" or "MERGE GATED", case-insensitively). The first
  # alternative reproduces it verbatim; the second adds the "MERGE GATE" /
  # "MERGE-GATE" spelling it missed. Written as a union, not a rewrite, so the
  # "never narrower" property is readable off the pattern itself.
  @merge_gate_worded ~r/MERGE[-\s]GATED|MERGE[-\s]GATE\b/i

  defp worded_merge_gate?(text) when is_binary(text),
    do: Regex.match?(@merge_gate_worded, text)

  defp worded_merge_gate?(_), do: false

  @doc """
  Fetches the entry at `index` from a raw `acceptance_criteria` list, or `nil`
  when the list or the index is unusable. Lets a guard ask "is the row I am
  about to flip a merge gate?" without duplicating list-shape tolerance.
  """
  @spec at(term(), term()) :: map() | nil
  def at(list, index)
      when is_list(list) and is_integer(index) and index >= 0 do
    case Enum.at(list, index) do
      %{} = entry -> entry
      _ -> nil
    end
  end

  def at(_, _), do: nil

  # String key first (the persisted shape), atom fallback — via Map.fetch so a
  # present-but-false value is not masked (the Validation.fetch precedent).
  defp fetch(map, key) when is_atom(key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, v} -> v
      :error -> Map.get(map, key)
    end
  end
end
