defmodule Barkpark.Plugins.OnixEdit.Export.StatusPill do
  @moduledoc """
  Shared color/label mapping for Bokbasen export status — 5 buckets over 9 states.

  Phase 8 WI5 consolidation. Two earlier call sites carried their own
  copies of the same mapping — Phase 7 WI5's plugin `BookEditor` LV
  (removed in Goal `barkpark-zdy`) and Phase 7 WI6's `BokbasenLive`.
  All remaining call sites now route through `color_class/1` and
  `label/1` so the pill palette is defined in exactly one place.

  ## Buckets

      :pending   :staging                 → bp-pill-gray   ("Pending"  / "Staging")
      :staged    :polling                 → bp-pill-blue   ("Staged"   / "Polling")
      :accepted                           → bp-pill-green  ("Accepted")
      :rejected                           → bp-pill-red    ("Rejected")
      :failed    :cancelled :cannot_cancel → bp-pill-orange ("Failed"  / "Cancelled" / "Cannot cancel")
      nil / unknown                       → bp-pill-gray   ("")

  Inputs accepted: atom, binary, or nil. Atom and binary forms map to the
  same bucket — callers reading composite status via `Bokbasen.Status.read/1`
  receive string keys (per WI1 contract), so binary is the common path.
  """

  @gray_states ~w(pending staging)
  @blue_states ~w(staged polling)
  @green_states ~w(accepted)
  @red_states ~w(rejected)
  @orange_states ~w(failed cancelled cannot_cancel)

  @doc """
  Returns the Tailwind/CSS class for the pill bucket of `state`.

  Unknown / nil states fall back to the gray bucket so the pill stays
  visually consistent with `:pending` (the closest default).
  """
  @spec color_class(atom() | binary() | nil) :: String.t()
  def color_class(state), do: state |> to_string_state() |> color_class_for()

  @doc """
  Returns the human-readable label for `state`.

  Underscore-separated states are spaced and capitalised (e.g.
  `:cannot_cancel` → `"Cannot cancel"`). Unknown / nil states return `""`
  so the caller can choose to skip rendering entirely.
  """
  @spec label(atom() | binary() | nil) :: String.t()
  def label(state), do: state |> to_string_state() |> label_for()

  # ── private ──────────────────────────────────────────────────────────────

  defp to_string_state(nil), do: nil
  defp to_string_state(state) when is_binary(state) and state != "", do: state
  defp to_string_state(state) when is_atom(state), do: Atom.to_string(state)
  defp to_string_state(_), do: nil

  defp color_class_for(state) when state in @gray_states, do: "bp-pill-gray"
  defp color_class_for(state) when state in @blue_states, do: "bp-pill-blue"
  defp color_class_for(state) when state in @green_states, do: "bp-pill-green"
  defp color_class_for(state) when state in @red_states, do: "bp-pill-red"
  defp color_class_for(state) when state in @orange_states, do: "bp-pill-orange"
  defp color_class_for(_), do: "bp-pill-gray"

  defp label_for(state) when is_binary(state) do
    state |> String.replace("_", " ") |> String.capitalize()
  end

  defp label_for(_), do: ""
end
