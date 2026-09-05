defmodule BarkparkWeb.PaperPresence do
  @moduledoc """
  Who else is on this paper — edit-on-the-link slice 4
  (task-e99a8e946f80f52c).

  Pure helpers over `BarkparkWeb.Presence`: the topic, the tracking key, the
  meta shape, and the materialisation the reader renders. Like
  `BarkparkWeb.Studio.PresenceState` it deliberately does NOT call
  `Phoenix.Presence.track/4` or `Phoenix.PubSub.subscribe/2` — both bind to the
  calling pid and must stay in the LiveView's own callbacks.

  ## The topic is its own, not the reader's doc topic

  The reader already subscribes to `Content.paper_topic(slug, ws, dataset)`
  (`doc:ws:<ws>:<ds>:paper:<slug>`), and tracking presence there would have
  needed no new subscription. It is not worth it: that topic carries
  `{:paper_block, …}` / `{:doc_updated, …}` frames to more than one consumer,
  and adding `%{event: "presence_diff"}` messages to it means every present and
  future subscriber grows a clause for a message it does not care about — or
  drops it into a catch-all and stops noticing.

  So presence rides `paper_presence:ws:<ws>:<ds>:<slug>`: the same tenant,
  dataset and paper key, its own channel. A workspace-less paper (legacy NULL
  row) falls back to a `ws:none` segment rather than an instance-global topic,
  mirroring the shape `PresenceState.topic/1` takes for the same case — except
  we do NOT collapse to a shared global, because two tenants' same-slug papers
  must never see each other's readers.

  ## Identified vs counted

  An identified viewer (user / api_token / share) is tracked under her own key
  `"<kind>:<id>"`, so two browser tabs of one person are ONE presence with two
  metas rather than two people.

  Every anonymous viewer is tracked under the SINGLE shared key `"anonymous"`.
  That is the whole privacy design: Phoenix keeps one entry with N metas, so
  `anonymous_count/1` is `length(metas)` and there is structurally nowhere to
  put an identity. Anonymous viewers are counted, never named — and they are
  never listed, so an identified viewer learns "3 others" and nothing more.
  """

  alias BarkparkWeb.Presence

  @topic_prefix "paper_presence"
  @anonymous_key "anonymous"

  @doc """
  The presence topic for one paper in one dataset in one workspace.

  A nil workspace resolves to a `ws:none` segment — distinct from every real
  workspace, so a legacy NULL-workspace paper gets its own room instead of a
  shared global one.
  """
  @spec topic(binary() | nil, String.t() | nil, String.t()) :: String.t()
  def topic(workspace_id, dataset, slug) when is_binary(slug) do
    ws = if is_binary(workspace_id) and workspace_id != "", do: workspace_id, else: "none"
    ds = if is_binary(dataset) and dataset != "", do: dataset, else: "default"

    "#{@topic_prefix}:ws:#{ws}:#{ds}:#{slug}"
  end

  @doc "The shared key every anonymous viewer is tracked under."
  @spec anonymous_key() :: String.t()
  def anonymous_key, do: @anonymous_key

  @doc """
  The Presence key for an actor (`BarkparkWeb.PaperActor.from_viewer/1` shape).

  Identified: `"<kind>:<id>"` — one key per person, however many tabs.
  Anonymous (or a share with no link id): the shared `"anonymous"` key.

  The `"anonymous"` KIND wins over any id it happens to be carrying. Without
  that clause an actor shaped `%{kind: "anonymous", id: <anything>}` would key
  itself into a slot of its own and stop being part of the count — the exact
  hole the whole counted-not-identified posture rests on not having.
  """
  @spec key(map()) :: String.t()
  def key(%{kind: "anonymous"}), do: @anonymous_key

  def key(%{kind: kind, id: id}) when is_binary(kind) and is_binary(id) and id != "",
    do: "#{kind}:#{id}"

  def key(_actor), do: @anonymous_key

  @doc """
  The meta to track for an actor. `editing?` starts false; the reader flips it
  through `Presence.update/4` when a viewer enters edit mode.

  An anonymous meta carries NO id and NO label — the key already forced that,
  and this makes it true of the payload as well.
  """
  @spec meta(map()) :: map()
  def meta(actor) when is_map(actor) do
    case key(actor) do
      @anonymous_key ->
        %{kind: "anonymous", id: nil, label: nil, editing?: false, joined_at: now()}

      _ ->
        %{
          kind: Map.get(actor, :kind),
          id: Map.get(actor, :id),
          label: Map.get(actor, :label),
          editing?: false,
          joined_at: now()
        }
    end
  end

  @doc """
  Materialise `topic` into what the reader renders:

      %{identified: [%{key, kind, id, label, editing?, joined_at}], anonymous_count: n}

  `identified` is oldest-join-first so the strip does not reshuffle when
  somebody opens a second tab. One entry per PERSON: the earliest meta wins for
  `joined_at`, and `editing?` is true if ANY of that person's tabs is editing.
  """
  @spec list(String.t()) :: %{identified: [map()], anonymous_count: non_neg_integer()}
  def list(topic) when is_binary(topic) do
    presences = Presence.list(topic)

    anonymous_count =
      case Map.get(presences, @anonymous_key) do
        %{metas: metas} -> length(metas)
        _ -> 0
      end

    identified =
      presences
      |> Enum.reject(fn {key, _entry} -> key == @anonymous_key end)
      |> Enum.map(&collapse/1)
      |> Enum.sort_by(& &1.joined_at)

    %{identified: identified, anonymous_count: anonymous_count}
  end

  @doc "The empty materialisation — what a dead render and a failed list yield."
  @spec empty() :: %{identified: [], anonymous_count: 0}
  def empty, do: %{identified: [], anonymous_count: 0}

  @doc """
  A display label for one identified presence: the label when there is one,
  else a short form of the id. Never blank, so the strip never renders an
  anonymous-looking gap for somebody who IS identified.
  """
  @spec display(map()) :: String.t()
  def display(%{label: label}) when is_binary(label) and label != "", do: label

  def display(%{id: id}) when is_binary(id) and id != "", do: String.slice(id, 0, 8)

  def display(_presence), do: "someone"

  # Fold one person's metas (one per open tab) into a single row.
  defp collapse({key, %{metas: metas}}) when is_list(metas) and metas != [] do
    first = Enum.min_by(metas, &Map.get(&1, :joined_at, 0))

    %{
      key: key,
      kind: Map.get(first, :kind),
      id: Map.get(first, :id),
      label: Map.get(first, :label),
      # Any tab editing means the person is editing.
      editing?: Enum.any?(metas, &(Map.get(&1, :editing?) == true)),
      joined_at: Map.get(first, :joined_at, 0)
    }
  end

  defp collapse({key, _entry}),
    do: %{key: key, kind: nil, id: nil, label: nil, editing?: false, joined_at: 0}

  # Monotonic-enough join ordering without dragging a DateTime through every
  # meta comparison.
  defp now, do: System.system_time(:millisecond)
end
