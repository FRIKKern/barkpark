defmodule BarkparkWeb.Studio.PresenceState do
  @moduledoc """
  Pure helpers for the Studio's collaborative presence layer.

  Owns the canonical PubSub topic, identity generation, color picking,
  and presence-list materialisation. **Does not** call
  `Phoenix.Presence.track/4` or `Phoenix.PubSub.subscribe/2` — those
  bind to the caller pid (the StudioLive process) and must remain in
  the LV's callback bodies. See IMPL-SPEC Risk #2.

  Extracted from `BarkparkWeb.Studio.StudioLive` in Task #11 WI3.
  """

  alias BarkparkWeb.Presence
  alias BarkparkWeb.Studio.TokensGen

  @topic "studio:presence"
  # Categorical presence palette — the 8 fixed hues, sourced from the emitted
  # Unified Aesthetic token module (design/tokens.json color.presence.palette).
  @colors TokensGen.presence_palette()

  @doc """
  Studio presence PubSub topic, workspace-keyed.

  Tenant-boundary fix (P0 of the Scoped-by-URL arc, tsk-url-p0): the topic
  used to be instance-global, so avatars from EVERY workspace mixed into
  every Studio session and two docs sharing a doc_id in different tenants
  read as co-presence. A resolved workspace keys its own topic; a nil
  workspace (tenancy backfill not run) keeps the legacy global topic —
  mirroring `StudioLive.list_topic/2`'s fallback shape.
  """
  @spec topic(String.t() | nil) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: "#{@topic}:ws:#{workspace_id}"
  def topic(_workspace_id), do: @topic

  @doc """
  Studio presence topic keyed by workspace + project + dataset — the room a
  Studio socket joins (owner ruling #30 Q7, 2026-10-03).

  The workspace-only topic above let a share or grant viewer of ONE project
  receive the doc ids, types and display names being edited in every other
  project of the workspace. A nil project or dataset gets a `none` segment: its
  own room, never the workspace-wide one and never a real project's. A nil
  workspace keeps the legacy global topic, as `topic/1` does.
  """
  @spec topic(String.t() | nil, String.t() | nil, String.t() | nil) :: String.t()
  def topic(workspace_id, project_id, dataset) when is_binary(workspace_id),
    do: "#{topic(workspace_id)}:p:#{segment(project_id)}:d:#{segment(dataset)}"

  def topic(_workspace_id, _project_id, _dataset), do: @topic

  defp segment(value) when is_binary(value) and value != "", do: value
  defp segment(_), do: "none"

  @doc "Generate a random 12-char hex user id (used when client localStorage has none)."
  @spec generate_user_id() :: String.t()
  def generate_user_id do
    :crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower)
  end

  @doc "Deterministically pick a presence color from `user_id` via phash2."
  @spec pick_color(String.t()) :: String.t()
  def pick_color(user_id) do
    index = :erlang.phash2(user_id, length(@colors))
    Enum.at(@colors, index)
  end

  @doc "Materialise the presence list on `topic` as flat `%{user_id, ...meta}` maps."
  @spec list(String.t()) :: [map()]
  def list(topic) when is_binary(topic) do
    Presence.list(topic)
    |> Enum.flat_map(fn {uid, %{metas: metas}} ->
      Enum.map(metas, &Map.put(&1, :user_id, uid))
    end)
  end

  @doc """
  Filter a presence list to those editing `doc_id` in `dataset`.

  The dataset arm closes the second half of the co-presence bug: within one
  workspace, the same doc_id can exist in several datasets — presence metas
  carry `:dataset` (stamped by `track_presence`), so a viewer of
  production's `p1` never shows as present on test's `p1`. Metas from
  before the meta carried `:dataset` fail the match (nil ≠ dataset) —
  fail-quiet, self-healing on the next track/update.
  """
  @spec on_doc([map()], String.t(), String.t() | nil) :: [map()]
  def on_doc(presences, doc_id, dataset) do
    Enum.filter(presences, &(&1.doc_id == doc_id and Map.get(&1, :dataset) == dataset))
  end
end
