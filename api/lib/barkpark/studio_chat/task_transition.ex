defmodule Barkpark.StudioChat.TaskTransition do
  @moduledoc """
  The ONE rule that turns a task-document broadcast into a chat transcript
  transition line — shared by Studio's `chat_live` and the `Recorder`'s SSE
  re-broadcast so both surfaces scope, key, and label a transition identically
  (composition doctrine: one derivation, two renderers).

  There is NO second bus. Task lifecycle already fans out on the canonical
  document topics (`Barkpark.Content.Broadcast.broadcast_document_mutation/3`,
  the same `{:document_changed, msg}` the Tasks board LiveView and the Doing
  strip ride). This module is a pure projection of ONE such message.

  ## The scoping rule (tlv-bl-chat-live-transition-stream)

  A chat transcript is a conversation, not a firehose: the workspace's whole
  task stream must never land in it. A mutation renders iff its task is in the
  session's **touched set** — grown from exactly ONE authoritative, in-process
  signal, and STICKY:

    1. **the session's own worker id** (`claude-chat-<sid-prefix>`, from
       `Runtime.worker_id/2`) holds the claim on the mutating row, OR
    2. the task id is ALREADY in the touched set — put there by a previous
       worker-matched mutation, or seeded from the worker's held claims at
       session open (Studio hydrates those for the Doing strip already).

  Stickiness is load-bearing, not decoration: `Tasks.Release` CLEARS the claim
  lease, and the TTL sweeper's `task.lease_expired` reaps it — so a release, a
  reap, or a lead's kill of a task THIS session was working carries no
  `claim.worker` to match on. Without the sticky set the most important
  transitions (the ones that invalidate what the agent believes) are exactly
  the ones that would never render.

  MCP chips are deliberately NOT a scoping source. `task_ready` / `task_prime`
  chips list the whole ready queue — tasks the session merely READ. Keying on
  them would reintroduce, by proxy, the workspace firehose the rule exists to
  refuse.

  ## The kind whitelist

  Only LIFECYCLE mutations project. `task.pulse` is a lease heartbeat that
  fires on a timer (it would spam a transcript with no news), and
  `task.criterion` / `task.relabeled` / `task.referenced` /
  `task.compacted` / `task.compaction_restored` / `task.reparented` are
  bookkeeping, not a state change a collaborator can act on wrongly.

  ## Idempotency key

  `key/1` is the durable `mutation_events` row id the broadcast carries
  (`msg.event_id`) — the SAME id the `/v1/data/listen` SSE stream uses as its
  `Last-Event-ID` resume cursor, so a replayed frame keys identically to its
  live original. A message with no event id (a hand-built test frame, a writer
  that omitted the option) degrades to a `doc_id:mutation:rev` composite rather
  than rendering twice.
  """

  # The lifecycle kinds — the `mutation_events` kind strings the Tasks spine
  # emits (`Tasks.event_kinds/0`, `Tasks.Release`, `Tasks.Stage`,
  # `Tasks.TtlSweeper`). Kept as literal strings for the same reason the SSE
  # controller does: this is a WIRE vocabulary, and a module attribute pulled
  # from another app's private @attrs would not be checkable here.
  @lifecycle_kinds ~w(
    task.claimed
    task.closed
    task.released
    task.staged
    task.mutated
    task.lease_expired
    task.engagement_lapsed
  )

  # The lifecycle_status vocabulary that owns a `--life-*` design token. Mirrors
  # ChatToolRenderer's @life_states so a transition chip and an MCP task chip
  # tint the same state the same colour.
  @life_states ~w(open ready in_progress blocked done closed cancelled considering researching)

  @neutral_color "var(--fg-dim)"

  @typedoc """
  One projected transition. `key` is the idempotency key, `verb` the human
  past-tense of the mutation kind, `status` the row's lifecycle_status AFTER
  the write, `color` a `--life-*` design token (never a literal colour).
  """
  @type t :: %{
          key: String.t(),
          task_id: String.t(),
          title: String.t(),
          status: String.t(),
          mutation: String.t(),
          verb: String.t(),
          label: String.t(),
          color: String.t()
        }

  @doc "The lifecycle mutation kinds that project to a transition line."
  @spec lifecycle_kinds() :: [String.t()]
  def lifecycle_kinds, do: @lifecycle_kinds

  @doc """
  Project one `{:document_changed, msg}` payload into a transition for a
  session, threading the session's sticky touched set.

  Returns `{:ok, transition, touched}` when the message is in scope and
  projects, or `{:skip, touched}` otherwise — the touched set comes back either
  way so a caller can thread it unconditionally (a worker-matched mutation of a
  NON-lifecycle kind still enrols the task, which is why the set is returned on
  the skip arm too).

  `worker` is this session's worker id (nil when the session has no store row
  yet — nothing can be ours then, and the touched set carries the load).
  """
  @spec project(map(), String.t() | nil, MapSet.t()) ::
          {:ok, t(), MapSet.t()} | {:skip, MapSet.t()}
  def project(msg, worker, %MapSet{} = touched) when is_map(msg) do
    id = Map.get(msg, :doc_id)

    cond do
      not is_binary(id) ->
        {:skip, touched}

      # A draft twin is an echo of the published ledger row, never a transition
      # of its own (the Doing strip drops these for the same reason).
      String.starts_with?(id, "drafts.") ->
        {:skip, touched}

      true ->
        content = doc_content(msg)
        touched = enrol(touched, id, content, worker)

        if MapSet.member?(touched, id),
          do: build(msg, id, content, touched),
          else: {:skip, touched}
    end
  end

  @doc """
  The idempotency key for a broadcast: the durable `mutation_events` row id
  when the writer supplied one, else a `doc_id:mutation:rev` composite.
  """
  @spec key(map()) :: String.t()
  def key(msg) when is_map(msg) do
    case Map.get(msg, :event_id) do
      id when is_binary(id) and id != "" ->
        id

      id when is_integer(id) ->
        Integer.to_string(id)

      _ ->
        Enum.map_join(
          [Map.get(msg, :doc_id), Map.get(msg, :mutation), Map.get(msg, :rev)],
          ":",
          &to_string/1
        )
    end
  end

  @doc """
  The `--life-*` design token for a lifecycle status, or the neutral dim token
  for an unknown one. Emits a token reference only — never a literal colour —
  so `scripts/studio-literal-check.sh` stays green.
  """
  @spec color(term()) :: String.t()
  def color(status) when is_binary(status) do
    if status in @life_states, do: "var(--life-" <> status <> ")", else: @neutral_color
  end

  def color(_), do: @neutral_color

  @doc """
  The one-line label BOTH surfaces render: `<title> → <status> (<verb>)`, or
  the task id when the broadcast carried no title. The Go TUI prints this
  string verbatim; Studio wraps it in a tinted mono row.
  """
  @spec label(String.t(), String.t(), String.t()) :: String.t()
  def label(subject, status, verb) do
    subject <> " → " <> status <> " (" <> verb <> ")"
  end

  # ── internals ─────────────────────────────────────────────────────────────

  # A worker-matched mutation enrols the task PERMANENTLY (see the stickiness
  # rationale in @moduledoc). Any other shape leaves the set untouched — an
  # absent worker id can never match, so a session with no store row only ever
  # renders what its seeded set already holds.
  defp enrol(touched, id, content, worker) do
    claim = Map.get(content, "claim") || %{}

    if is_binary(worker) and worker != "" and Map.get(claim, "worker") == worker,
      do: MapSet.put(touched, id),
      else: touched
  end

  defp build(msg, id, content, touched) do
    mutation = Map.get(msg, :mutation)

    if is_binary(mutation) and mutation in @lifecycle_kinds do
      status = lifecycle_status(content)
      title = title_of(msg, id)
      verb = verb(mutation)

      {:ok,
       %{
         key: key(msg),
         task_id: id,
         title: title,
         status: status,
         mutation: mutation,
         verb: verb,
         label: label(title, status, verb),
         color: color(status)
       }, touched}
    else
      {:skip, touched}
    end
  end

  defp doc_content(msg) do
    case Map.get(msg, :doc) do
      %{content: content} when is_map(content) -> content
      _ -> %{}
    end
  end

  defp lifecycle_status(content) do
    case Map.get(content, "lifecycle_status") do
      s when is_binary(s) and s != "" -> s
      _ -> "unknown"
    end
  end

  defp title_of(msg, id) do
    case Map.get(msg, :doc) do
      %{title: t} when is_binary(t) and t != "" -> t
      _ -> id
    end
  end

  # The human past-tense of a mutation kind. `task.mutated` is the generic
  # CAS lifecycle move (Tasks.Fence) — a kill/cancel/reopen arrives as one, so
  # its verb is deliberately the neutral "moved": the STATUS beside it carries
  # which move it was.
  defp verb("task.claimed"), do: "claimed"
  defp verb("task.closed"), do: "closed"
  defp verb("task.released"), do: "released"
  defp verb("task.staged"), do: "staged"
  defp verb("task.mutated"), do: "moved"
  defp verb("task.lease_expired"), do: "lease expired"
  defp verb("task.engagement_lapsed"), do: "engagement lapsed"
  defp verb(kind) when is_binary(kind), do: kind
end
