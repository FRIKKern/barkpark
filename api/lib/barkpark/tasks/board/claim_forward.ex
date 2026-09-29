defmodule Barkpark.Tasks.Board.ClaimForward do
  @moduledoc """
  The claim-forward contract for the GUI board, as ONE pure predicate.

  The Studio board (`Barkpark.Plugins.Tasks.Web.BoardLive`, over
  `Barkpark.Tasks.Board`) and the TUI task-list are twin readers of the SAME
  question — *is there a next claim, and is the one you are shown real?* The TUI
  half turned that question into `ClaimForwardViolations(Snapshot, Board)` in
  `internal/taskboard/claimforward.go`. This module is its GUI twin.

  ## Why a predicate and not a fixture assertion

  There is no stored `ready` lifecycle status — the stored enum is
  `open|in_progress|blocked|done|cancelled` and readiness is DERIVED. It is
  derived TWICE, by two different routes:

    * the SERVER route — `Barkpark.Tasks.Queue.ready/1`, one SQL query, which is
      what `/v1/tasks/prime`'s ready head and every `bp task ready` caller read;
    * the BOARD route — `Barkpark.Tasks.Board.build/2`'s in-memory `ready?/1`
      overlay, which is what the GUI column renders.

  A board that agrees with every hand-written fixture can still disagree with
  the live queue, because a fixture exercises only the board route. So the
  predicate takes the board projection AND an overlay supplied by the OTHER
  route, and reports where they part company.

  ## The three clauses (the TUI's C0/C1/C2, verbatim in meaning)

    * **C0** — ready work exists in the overlay ⇒ the ready column surfaces a
      move. An emptied column over claimable work is the defect that hides the
      whole backlog.
    * **C1** — every surfaced row is REAL: it is marked ready by the overlay and
      it is not already somebody's in-flight claim.
    * **C2** — nothing ready in the overlay ⇒ nothing surfaced AS ready (an
      honest empty state, and therefore no claim control on a ready card).

  ## Shape

      violations(board, overlay) :: [%{clause: atom(), doc_id: String.t() | nil,
                                       detail: String.t()}]

  `[]` is the honest board. `board` is a `Board.build/2` / `Board.snapshot/1`
  projection. `overlay` is `%{ready_ids: enumerable, in_progress_ids: enumerable}`
  — ids from the server route; `in_progress_ids` may be omitted.

  Both arms are exercised in `test/barkpark/tasks/board/claim_forward_test.exs`:
  one that reds on an injected breach, one that stays quiet on an honest board
  (including the genuinely-nothing-ready case), plus a two-route cross-check
  that builds the overlay from `Tasks.Queue.ready/1` over the same corpus the
  board reads.
  """

  @type violation :: %{clause: atom(), doc_id: String.t() | nil, detail: String.t()}

  @doc """
  Every way the board's ready column parts company with the derived-ready
  overlay. `[]` means the claim-forward contract holds.
  """
  @spec violations(map(), map()) :: [violation()]
  def violations(board, overlay) when is_map(board) and is_map(overlay) do
    surfaced = surfaced_ready_ids(board)
    ready = id_set(overlay, :ready_ids)
    in_flight = id_set(overlay, :in_progress_ids)

    c0(surfaced, ready) ++ c1(surfaced, ready, in_flight) ++ c2(surfaced, ready)
  end

  @doc """
  The doc_ids the board actually renders in its ready column, in render order.
  """
  @spec surfaced_ready_ids(map()) :: [String.t()]
  def surfaced_ready_ids(board) do
    board
    |> Map.get(:columns, %{})
    |> Map.get(:ready, [])
    |> Enum.map(&card_id/1)
    |> Enum.reject(&is_nil/1)
  end

  # C0 — claimable work in the overlay, nothing surfaced.
  defp c0([], ready) do
    if MapSet.size(ready) > 0 do
      [
        %{
          clause: :c0_no_move_surfaced_over_ready_overlay,
          doc_id: nil,
          detail:
            "the derived-ready overlay holds #{MapSet.size(ready)} claimable row(s) " <>
              "but the board's ready column is empty"
        }
      ]
    else
      []
    end
  end

  defp c0(_surfaced, _ready), do: []

  # C1 — every surfaced row is real.
  defp c1(surfaced, ready, in_flight) do
    Enum.flat_map(surfaced, fn id ->
      cond do
        MapSet.member?(in_flight, id) ->
          [
            %{
              clause: :c1_surfaced_row_is_already_an_in_flight_claim,
              doc_id: id,
              detail:
                "#{id} is surfaced as ready while the overlay holds it as an in-flight claim"
            }
          ]

        not MapSet.member?(ready, id) ->
          [
            %{
              clause: :c1_surfaced_row_absent_from_overlay,
              doc_id: id,
              detail:
                "#{id} is surfaced in the ready column but the overlay does not mark it ready"
            }
          ]

        true ->
          []
      end
    end)
  end

  # C2 — nothing ready ⇒ nothing surfaced AS ready. Reported once, naming the
  # surfaced rows, because the whole column is the dishonest state.
  defp c2(surfaced, ready) do
    if surfaced != [] and MapSet.size(ready) == 0 do
      [
        %{
          clause: :c2_ready_surfaced_over_empty_overlay,
          doc_id: List.first(surfaced),
          detail:
            "the overlay holds no claimable work but the board surfaces " <>
              "#{length(surfaced)} row(s) as ready: #{Enum.join(surfaced, ", ")}"
        }
      ]
    else
      []
    end
  end

  defp id_set(overlay, key) do
    overlay
    |> Map.get(key, [])
    |> case do
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list, &to_id/1)
      nil -> MapSet.new()
      other -> MapSet.new(other, &to_id/1)
    end
  end

  defp to_id(id) when is_binary(id), do: id
  defp to_id(%{doc_id: id}), do: id
  defp to_id(%{"doc_id" => id}), do: id
  defp to_id(%{"_id" => id}), do: id
  defp to_id(other), do: to_string(other)

  defp card_id(%{doc_id: id}), do: id
  defp card_id(%{"doc_id" => id}), do: id
  defp card_id(_), do: nil
end
