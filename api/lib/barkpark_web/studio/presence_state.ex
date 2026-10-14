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

  @doc """
  Whether `selection` is a shared text selection: `%{"anchor" => point, "head" => point}`,
  each point `%{"blockId" => id, "path" => path?, "offset" => n}`. The one shape
  the presence API (#22510) and the Studio paper canvas both carry.
  """
  @spec selection_shape?(term()) :: boolean()
  def selection_shape?(%{"anchor" => a, "head" => h} = sel) when map_size(sel) == 2,
    do: point?(a) and point?(h)

  def selection_shape?(_), do: false

  defp point?(%{"blockId" => id, "offset" => off} = p)
       when is_binary(id) and id != "" and is_integer(off) and off >= 0 do
    case Map.drop(p, ["blockId", "offset"]) do
      empty when empty == %{} -> true
      %{"path" => path} when is_binary(path) and path != "" -> true
      _ -> false
    end
  end

  defp point?(_), do: false

  @doc """
  The other people's carets on `doc_id`, for the paper canvas's
  `setRemoteSelections` (task-c522237b9f37de21): every presence on that
  document with a selection, except the session `own_session_id`, as
  `%{id, name, color, anchor, head}`, sorted by id so an unchanged list
  compares equal.
  """
  @spec remote_selections([map()], String.t(), String.t() | nil, String.t() | nil) :: [map()]
  def remote_selections(presences, doc_id, dataset, own_session_id) do
    presences
    |> on_doc(doc_id, dataset)
    |> Enum.flat_map(fn p ->
      id = Map.get(p, :session_id) || Map.get(p, :user_id)

      case Map.get(p, :selection) do
        %{"anchor" => anchor, "head" => head} = sel when id != own_session_id ->
          if selection_shape?(sel),
            do: [
              %{
                id: id,
                name: Map.get(p, :name),
                color: Map.get(p, :color),
                anchor: anchor,
                head: head
              }
            ],
            else: []

        _ ->
          []
      end
    end)
    |> Enum.sort_by(& &1.id)
  end
end
