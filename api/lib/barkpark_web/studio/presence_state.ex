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

  @topic "studio:presence"
  @colors ~w(#3b82f6 #ef4444 #10b981 #f59e0b #8b5cf6 #ec4899 #06b6d4 #f97316)

  @doc "Canonical Studio presence PubSub topic."
  @spec topic() :: String.t()
  def topic, do: @topic

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

  @doc "Materialise the current presence list as a flat list of `%{user_id, ...meta}` maps."
  @spec list() :: [map()]
  def list do
    Presence.list(@topic)
    |> Enum.flat_map(fn {uid, %{metas: metas}} ->
      Enum.map(metas, &Map.put(&1, :user_id, uid))
    end)
  end

  @doc "Filter a presence list to only those editing `doc_id`."
  @spec on_doc([map()], String.t()) :: [map()]
  def on_doc(presences, doc_id) do
    Enum.filter(presences, &(&1.doc_id == doc_id))
  end
end
