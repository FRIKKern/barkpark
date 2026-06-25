defmodule Barkpark.Plugins.OnixEdit.SyncEntries do
  @moduledoc """
  External-sync state metadata for the Bokbasen submission channel.

  Each entry maps an `external_sync` channel name to its display label and
  the per-state colour/label badges Studio renders for a `book` document's
  Bokbasen submission lifecycle.

  Extracted verbatim from `Barkpark.Plugins.OnixEdit.external_sync_entries/0`
  behind the plugin facade — the callback delegates to `entries/0`. The
  returned map is byte-identical to before.
  """

  @doc """
  The external-sync entry map. Returned unchanged from the former
  `OnixEdit.external_sync_entries/0` body.
  """
  @spec entries() :: %{optional(String.t()) => map()}
  def entries do
    %{
      "bokbasen" => %{
        label: "Bokbasen",
        states: %{
          "pending" => %{color: "gray", label: "Pending"},
          "staging" => %{color: "gray", label: "Staging"},
          "staged" => %{color: "blue", label: "Staged"},
          "polling" => %{color: "blue", label: "Polling"},
          "accepted" => %{color: "green", label: "Accepted"},
          "rejected" => %{color: "red", label: "Rejected"},
          "failed" => %{color: "orange", label: "Failed"},
          "cancelled" => %{color: "orange", label: "Cancelled"},
          "cannot_cancel" => %{color: "orange", label: "Cannot cancel"},
          nil => %{color: "gray", label: "Not synced"}
        }
      }
    }
  end
end
