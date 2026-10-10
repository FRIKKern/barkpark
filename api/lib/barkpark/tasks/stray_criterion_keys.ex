defmodule Barkpark.Tasks.StrayCriterionKeys do
  @moduledoc """
  The reviewed data step for pds-bl-stray-keys-on-acceptance-criteria: strip
  the undeclared keys the corpus collected before `Tasks.Validation` refused
  them. Run it BEFORE (or right after) the allowlist deploys: until a row is
  clean, a doc patch of that row is refused, because the patch re-validates
  the whole criteria list. Stamp and close are unaffected either way.

      bin/barkpark eval 'Barkpark.Release.clean_stray_criterion_keys()'             # dry run
      bin/barkpark eval 'Barkpark.Release.clean_stray_criterion_keys(apply: true)'

  Per entry, exactly the lead ruling (2026-10-10), nothing else:

    * `index` equal to the entry's position → dropped; any other `index` is
      REPORTED and left (it would mean the position story is wrong);
    * `amendment` (singular, hand-written before `--amend`) → appended to
      `amendments` as `%{"note", "ts", "worker" => "legacy-amendment"}`;
    * `note` → appended to `attempts` as `%{"note", "ts", "worker" => "legacy-note"}`;
    * `" met"` (a padded `met`) → dropped; `met` is kept as stored;
    * any OTHER undeclared key → REPORTED and left, for a human.

  Writes go through `Tasks.Internal.fenced_content_write/4` (rev-fenced, re-
  syncs the brief), so a row that moved meanwhile is skipped as `:stale`, never
  clobbered. Returns a report map; the dry run writes nothing.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content.Document
  alias Barkpark.Repo
  alias Barkpark.Tasks.{Internal, Validation}

  @doc "The cleaned content and the actions taken, or `:clean` when there is nothing to do."
  @spec plan(map(), String.t()) ::
          {:clean, []} | {:changed, map(), [map()]} | {:report_only, [map()]}
  def plan(%{"acceptance_criteria" => list} = content, ts) when is_list(list) do
    {entries, actions} =
      list
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {entry, i}, acc ->
        {new, acts} = clean_entry(entry, i, ts)
        {new, acc ++ acts}
      end)

    cond do
      actions == [] -> {:clean, []}
      Enum.all?(actions, &(&1.action == :report)) -> {:report_only, actions}
      true -> {:changed, Map.put(content, "acceptance_criteria", entries), actions}
    end
  end

  def plan(_content, _ts), do: {:clean, []}

  defp clean_entry(%{} = entry, i, ts) do
    entry
    |> Map.keys()
    |> Enum.reject(&(to_string(&1) in Validation.criterion_keys()))
    |> Enum.sort_by(&to_string/1)
    |> Enum.reduce({entry, []}, fn key, {e, acts} ->
      {e2, act} = clean_key(e, to_string(key), key, i, ts)
      {e2, acts ++ [Map.merge(%{index: i, key: to_string(key)}, act)]}
    end)
  end

  defp clean_entry(entry, _i, _ts), do: {entry, []}

  defp clean_key(e, "index", key, i, _ts) do
    if Map.get(e, key) == i,
      do: {Map.delete(e, key), %{action: :drop}},
      else:
        {e, %{action: :report, why: "index #{inspect(Map.get(e, key))} is not the position #{i}"}}
  end

  defp clean_key(e, "amendment", key, _i, ts) do
    record = %{"note" => text(Map.get(e, key)), "ts" => ts, "worker" => "legacy-amendment"}

    {e |> Map.delete(key) |> Map.update("amendments", [record], &(List.wrap(&1) ++ [record])),
     %{action: :fold_into_amendments}}
  end

  defp clean_key(e, "note", key, _i, ts) do
    attempt = %{"note" => text(Map.get(e, key)), "ts" => ts, "worker" => "legacy-note"}

    {e |> Map.delete(key) |> Map.update("attempts", [attempt], &(List.wrap(&1) ++ [attempt])),
     %{action: :move_into_attempts}}
  end

  defp clean_key(e, " met", key, _i, _ts), do: {Map.delete(e, key), %{action: :drop}}

  defp clean_key(e, _other, _key, _i, _ts),
    do: {e, %{action: :report, why: "undeclared key with no ruling; left for a human"}}

  defp text(v) when is_binary(v), do: v
  defp text(v), do: inspect(v)

  @doc """
  Walk every `type: "task"` row (drafts too) and clean it. Options:
  `apply: true` to write (default: dry run). Returns
  `%{scanned:, changed:, stale:, actions: [%{doc_id:, index:, key:, action:, ...}]}`.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    apply? = Keyword.get(opts, :apply, false)
    docs = Repo.all(from(d in Document, where: d.type == "task"))

    Enum.reduce(docs, %{scanned: 0, changed: 0, stale: 0, actions: []}, fn doc, acc ->
      acc = %{acc | scanned: acc.scanned + 1}
      ts = DateTime.to_iso8601(doc.updated_at || DateTime.utc_now())

      case plan(doc.content || %{}, ts) do
        {:clean, _} ->
          acc

        {:report_only, acts} ->
          %{acc | actions: acc.actions ++ tag(acts, doc)}

        {:changed, content, acts} ->
          acc = %{acc | actions: acc.actions ++ tag(acts, doc)}

          cond do
            not apply? ->
              %{acc | changed: acc.changed + 1}

            match?(
              {:ok, _},
              Internal.fenced_content_write(doc, doc.rev, content, Internal.generate_rev())
            ) ->
              %{acc | changed: acc.changed + 1}

            true ->
              %{acc | stale: acc.stale + 1}
          end
      end
    end)
  end

  defp tag(acts, doc), do: Enum.map(acts, &Map.put(&1, :doc_id, doc.doc_id))
end
