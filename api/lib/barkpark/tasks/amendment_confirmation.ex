defmodule Barkpark.Tasks.AmendmentConfirmation do
  @moduledoc """
  THE SECOND PAIR OF EYES ON AN AMENDED CRITERION (task-e9c6aa61af536112).

  `bp task stamp --amend` rewrites a criterion's wording. On 2026-10-31 three
  builders amended a criterion and stamped it met in the same breath —
  task-95ce9a7d10a721ad, task-bbcfe31c4c20b43c, task-99fa2bd0efd238d8 — so the
  one worker who moved the bar was also the only one who judged the work
  against it. Nothing in the ledger objected.

  THE RULE: after a criterion is amended, the worker who amended it cannot
  stamp it met (and cannot close `done` over it met) until a DIFFERENT worker
  confirms the new wording with `bp task stamp --confirm-amendment`.

  A confirmation is bound to ONE amendment by position, never by text: it
  records how many amendments the criterion carried when it was confirmed, and
  it only counts while that is still the count. A later amendment therefore
  needs its own confirmation, and amending A → B → A cannot resurrect the
  confirmation the first A received.

  Only the LAST amendment matters. If W amended and then V amended again, V is
  now the worker who moved the bar and W reading V's wording is the second pair
  of eyes for it.
  """

  @doc """
  The worker whose amendment of this criterion still waits for another
  worker's confirmation, or `nil` when there is none (no amendment, or the
  last one is confirmed).
  """
  @spec awaiting_amender(term()) :: String.t() | nil
  def awaiting_amender(%{} = entry) do
    amendments = list(entry, "amendments")

    case List.last(amendments) do
      %{"worker" => amender} ->
        if confirmed?(entry, length(amendments), amender), do: nil, else: amender

      _ ->
        nil
    end
  end

  def awaiting_amender(_entry), do: nil

  @doc "The worker who made the criterion's last amendment, or `nil`."
  @spec last_amender(term()) :: String.t() | nil
  def last_amender(%{} = entry) do
    case List.last(list(entry, "amendments")) do
      %{"worker" => amender} -> amender
      _ -> nil
    end
  end

  def last_amender(_entry), do: nil

  @doc "How many amendments the criterion carries — the position a confirmation binds to."
  @spec amendment_count(map()) :: non_neg_integer()
  def amendment_count(%{} = entry), do: length(list(entry, "amendments"))

  @doc """
  Indices of the criteria in `list` that are met and whose last amendment, made
  by `worker`, is still unconfirmed. The close gate reads this from the
  criteria as the close would leave them.
  """
  @spec self_amended_met(term(), String.t()) :: [non_neg_integer()]
  def self_amended_met(list, worker) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.filter(fn {entry, _index} ->
      is_map(entry) and Map.get(entry, "met") == true and awaiting_amender(entry) == worker
    end)
    |> Enum.map(fn {_entry, index} -> index end)
  end

  def self_amended_met(_list, _worker), do: []

  defp confirmed?(entry, count, amender) do
    entry
    |> list("confirmations")
    |> Enum.any?(fn
      %{"amendment" => ^count, "worker" => worker} -> worker != amender
      _ -> false
    end)
  end

  defp list(entry, key) do
    case Map.get(entry, key) do
      l when is_list(l) -> l
      _ -> []
    end
  end
end
