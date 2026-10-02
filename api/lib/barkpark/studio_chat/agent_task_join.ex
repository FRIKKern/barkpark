defmodule Barkpark.StudioChat.AgentTaskJoin do
  @moduledoc """
  The AGENT↔TASK join for Studio's Doing strip (task wsc-bl-agent-task-join,
  api half task-ba42f986bb0d4594). A PORT of the shipped Go rule in
  `internal/taskboard/agentjoin.go` (`AgentLabelTaskKey`, `agentEmitterSlug`,
  `AgentTaskIndex.Join`, `AgentTaskSummary`) — not a re-derivation. The TUI's
  agent-detail pane and this strip must never disagree on which task a builder
  is advancing, so every rule below names its Go counterpart.

  ## The grammar — the LAST colon-segment

  Two emitters produce builder labels:

      bp-epic-cycle.workflow.js    build:${slug(item.title)}          one segment
      wild-bulk-cycle.workflow.js  build:${d.slug}:${slug(t.title)}   two segments

  so the task token is the LAST colon-segment. This is deliberately NOT
  `Barkpark.StudioChat.workflow_label_parts/1` — that is the D59 DISPLAY
  grammar and splits at the FIRST colon (`"build:console:foo"` →
  `"console:foo"`); the join needs `"foo"`. Two grammars, two helpers.

  ## The slug — kebab, trim, THEN a 40-character slice, no re-trim

  Both emitters share

      slug = (t) => t.toLowerCase().replace(/[^a-z0-9]+/g,'-').replace(/^-|-$/g,'').slice(0,40)

  The slice runs AFTER the trim, so a title whose slice lands on a hyphen keeps
  a TRAILING hyphen (`"a-zombied-run-is-detected-but-never-re-d"` is a live
  label; `"…-re-"` shapes exist too) — a form a normal slugify never produces.
  On the live corpus 97.9% of titles slug past 40 characters, so a join written
  as `slugify(title) == segment` matches essentially nothing while looking
  correct in any short-title fixture. `emitter_slug/1` reproduces the emitter
  byte for byte; the index ALSO carries the uncapped slug so a short title
  (where the two agree) and a future uncapped emitter both land.

  ## Ambiguity degrades to NOTHING

  The 40-character slice manufactures collisions the full titles do not have
  (the Go liveprobe counted 91 ambiguous keys over 194 rows). A key carried by
  more than one DISTINCT row resolves to `:none`, exactly like a key carried by
  none: a wrong task line pins a builder's live evidence to somebody else's row,
  so there is no best-guess tier.
  """

  alias Barkpark.Content.DraftId

  @slug_budget 40

  @typedoc """
  A candidate row. `:doc_id` and `:title` are what the join reads; every other
  field rides through to the summary untouched.
  """
  @type row :: %{
          required(:doc_id) => String.t(),
          required(:title) => String.t() | nil,
          optional(:criteria) => %{met: non_neg_integer(), total: pos_integer()} | nil,
          optional(:pulse) => %{text: String.t(), at: DateTime.t() | nil} | nil,
          optional(atom()) => any()
        }

  @type index :: %{optional(String.t()) => [row()]}

  @doc """
  The uncapped kebab: lowercase, every run of non-`[a-z0-9]` → one `-`, one
  leading and one trailing `-` trimmed (the emitter's `replace(/^-|-$/g,'')`;
  runs are already collapsed, so one is all there can be). Mirrors Go
  `slugify/1` in internal/taskboard/repoctx.go.
  """
  @spec full_slug(String.t() | nil) :: String.t()
  def full_slug(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.replace(~r/\A-|-\z/, "")
  end

  def full_slug(_), do: ""

  @doc """
  The emitter's slug EXACTLY: `full_slug/1`, then a 40-character slice with NO
  re-trim. `full_slug/1`'s output is ASCII-only, so the byte slice is a
  character slice. Mirrors Go `agentEmitterSlug`.
  """
  @spec emitter_slug(String.t() | nil) :: String.t()
  def emitter_slug(title) do
    s = full_slug(title)
    if byte_size(s) > @slug_budget, do: binary_part(s, 0, @slug_budget), else: s
  end

  @doc """
  The task-slug token of a workflow agent label: the LAST colon-segment,
  lowercased and trimmed. `:error` when it is empty or not slug-shaped
  (`[a-z0-9-]+`) — a free-prose label ("Digest the survey") names no task, and
  treating it as a key would invite a fuzzy match this join does not have.
  Mirrors Go `AgentLabelTaskKey`.
  """
  @spec label_key(any()) :: {:ok, String.t()} | :error
  def label_key(label) when is_binary(label) do
    key =
      label
      |> String.trim()
      |> String.downcase()
      |> String.split(":")
      |> List.last()
      |> String.trim()

    if key =~ ~r/\A[a-z0-9-]+\z/, do: {:ok, key}, else: :error
  end

  def label_key(_), do: :error

  @doc """
  Build the join index: emitter slug (and, where it differs, the uncapped slug)
  → the rows carrying it. Draft twins collapse first — published wins, exactly
  as the Go `collapseDraftTwins` — so a `drafts.X`/`X` pair is one candidate,
  not a manufactured ambiguity. Rows with no title are not indexable.
  Mirrors Go `NewAgentTaskIndex`.
  """
  @spec index([row()]) :: index()
  def index(rows) when is_list(rows) do
    rows
    |> collapse_draft_twins()
    |> Enum.reduce(%{}, fn row, acc ->
      case row[:title] do
        title when is_binary(title) and title != "" ->
          full = full_slug(title)
          emitted = emitter_slug(title)
          acc = Map.update(acc, emitted, [row], &[row | &1])
          if full != emitted, do: Map.update(acc, full, [row], &[row | &1]), else: acc

        _ ->
          acc
      end
    end)
    |> Map.new(fn {k, rs} -> {k, Enum.reverse(rs)} end)
  end

  @doc """
  Resolve one agent label against an index. Exactly one DISTINCT row (by bare
  id) must carry the label's key; zero and two-or-more both return `:none` and
  the caller renders NOTHING. Mirrors Go `AgentTaskIndex.Join`.
  """
  @spec join(index(), any()) ::
          {:ok, %{key: String.t(), row: row(), deep_link: String.t()}} | :none
  def join(index, label) when is_map(index) do
    with {:ok, key} <- label_key(label),
         [row] <- index |> Map.get(key, []) |> Enum.uniq_by(&bare_id(&1.doc_id)) do
      {:ok, %{key: key, row: row, deep_link: deep_link(row.doc_id)}}
    else
      _ -> :none
    end
  end

  @doc """
  Every DISTINCT-row collision in an index: `[{key, [bare_id, …]}]` for each key
  carried by two or more different rows — the degrade-on-ambiguity path's
  population (the live-corpus arm reports it; Go reports the same figure as
  ambiguous-keys / ambiguous-rows).
  """
  @spec ambiguous(index()) :: [{String.t(), [String.t()]}]
  def ambiguous(index) when is_map(index) do
    for {key, rows} <- index,
        ids = rows |> Enum.map(&bare_id(&1.doc_id)) |> Enum.uniq(),
        length(ids) > 1,
        do: {key, ids}
  end

  @doc """
  The Studio route that opens a task row — ALWAYS the bare id. The consumers of
  `/admin/projects?task=` are chat_tool_renderer.ex and board_live.ex. Mirrors
  Go `AgentTaskDeepLink`.
  """
  @spec deep_link(String.t()) :: String.t()
  def deep_link(doc_id) when is_binary(doc_id), do: "/admin/projects?task=" <> bare_id(doc_id)

  @doc """
  Decode a claim's now-line (`content.claim.now`, the `{"text","ts",
  "criterion"?}` map `Barkpark.Tasks.Pulse` writes) into `%{text:, at:}`.
  Absent / non-map / empty text → `nil` (an empty now-line says nothing, so it
  renders nothing); a malformed `ts` → `at: nil` (no age is painted, never a
  fresh one). Mirrors Go `decodePulse`.
  """
  @spec decode_pulse(any()) :: %{text: String.t(), at: DateTime.t() | nil} | nil
  def decode_pulse(%{"text" => text} = now) when is_binary(text) do
    case String.trim(text) do
      "" -> nil
      t -> %{text: t, at: parse_ts(now["ts"])}
    end
  end

  def decode_pulse(_), do: nil

  @doc """
  The one-line plain-text projection, segment for segment the Go
  `AgentTaskSummary`:

      <doc_id> · <met>/<total> criteria · ▸ <pulse text> (<age>) · <deep link>

  Every segment is omitted when its figure is absent — an un-pulsed claim shows
  no now-line, a criteria-less row shows no meter — never padded with zeros.
  `summary_parts/2` is the same list un-joined, for markup that styles each
  segment.
  """
  @spec summary(%{row: row(), deep_link: String.t()}, DateTime.t()) :: String.t()
  def summary(join, now), do: join |> summary_parts(now) |> Enum.join(" · ")

  @spec summary_parts(%{row: row(), deep_link: String.t()}, DateTime.t()) :: [String.t()]
  def summary_parts(%{row: row, deep_link: link}, %DateTime{} = now) do
    meter =
      case row[:criteria] do
        %{met: m, total: t} -> ["#{m}/#{t} criteria"]
        _ -> []
      end

    pulse =
      case row[:pulse] do
        %{text: text, at: %DateTime{} = at} ->
          ["▸ #{text} (#{compact_age(DateTime.diff(now, at))})"]

        %{text: text} ->
          ["▸ #{text}"]

        _ ->
          []
      end

    [bare_id(row.doc_id)] ++ meter ++ pulse ++ [link]
  end

  @doc """
  The coarse age a now-line carries: `now` under a minute (and for a negative
  clock), then `Nm`, `Nh`, `Nd`. Mirrors Go `compactAge`.
  """
  @spec compact_age(integer()) :: String.t()
  def compact_age(seconds) when seconds < 60, do: "now"
  def compact_age(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  def compact_age(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h"
  def compact_age(seconds), do: "#{div(seconds, 86_400)}d"

  @doc """
  Every `workflow_agent` node label across a chat rail's workflow-bearing
  entries, de-duplicated in rail order. The rail is the `%{id => entry}` map the
  ChatLive `rail` assign holds; each entry's `"workflow"` list carries the
  nodes.
  """
  @spec rail_agent_labels(any()) :: [String.t()]
  def rail_agent_labels(rail) when is_map(rail) do
    rail
    |> Map.values()
    |> Enum.sort_by(fn e -> if is_map(e) and is_integer(e["seq"]), do: e["seq"], else: 0 end)
    |> Enum.flat_map(fn
      %{"workflow" => nodes} when is_list(nodes) ->
        for %{"type" => "workflow_agent", "label" => label} <- nodes, is_binary(label), do: label

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  def rail_agent_labels(_), do: []

  # Published wins: a drafts.X row is dropped when X itself is present.
  defp collapse_draft_twins(rows) do
    bare = for r <- rows, not DraftId.draft?(r.doc_id), into: MapSet.new(), do: r.doc_id
    Enum.reject(rows, &(DraftId.draft?(&1.doc_id) and MapSet.member?(bare, bare_id(&1.doc_id))))
  end

  defp bare_id(doc_id), do: DraftId.published_id(doc_id)

  defp parse_ts(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil
end
