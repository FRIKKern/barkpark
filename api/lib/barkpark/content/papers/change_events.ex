defmodule Barkpark.Content.Papers.ChangeEvents do
  @moduledoc """
  Paper writes announce themselves on the event spine (owner ruling #40,
  task-bca599e1df6cca4b).

  `upsert_paper` (Bulldocs ingest, BPML sync) and the canvas block-op doors
  saved a revision and a paper-topic PubSub frame but no `mutation_events`
  row. So `/v1/data/listen` never streamed a paper edit, Sync pull and the
  push Outbox never saw one, webhooks never fired, and site caches stayed
  stale until their 5-minute refresh. A paper written through the generic
  mutate door already emitted, which is why the gap went unnoticed.

  The ruling chose "ingest + settled bursts":

    * `announce/3` — one event right away, for an ingest or sync write
      (`persist_blocks_doc_tail`).
    * `settle/2` — for canvas ops, which autosave every few hundred
      milliseconds. Each op (re)schedules ONE `SettleWorker` job for the paper
      `settle_seconds/0` from now (Oban `unique` + `replace: scheduled_at`), so
      an editing burst produces one combined event once the editor pauses,
      not one per keystroke batch. The job carries the rev before the burst
      as `previous_rev`; the event carries the rev after it.

  Each event is a `mutation_events` row (`Broadcast.save_event/6`), the
  document-list and per-doc PubSub frames, and the webhook fan-out
  (`Broadcast.broadcast_document_mutation/3` with `webhooks: true`). The six
  site-autodeploy webhooks therefore fire once per ingest and once per
  settled edit burst.

  A failure here is logged and never fails the paper write: the row is
  already committed and the paper topic already told open editors.
  """

  require Logger

  alias Barkpark.Content.{Broadcast, Document}
  alias Barkpark.Content.Papers.ChangeEvents.SettleWorker

  @default_settle_seconds 10

  @doc "Seconds an editing burst must be quiet before its event fires (config `:paper_event_settle_seconds`)."
  def settle_seconds do
    case Application.get_env(:barkpark, :paper_event_settle_seconds, @default_settle_seconds) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_settle_seconds
    end
  end

  @doc "Record and fan out one change event for `doc` now."
  @spec announce(Document.t(), String.t(), keyword()) :: :ok
  def announce(%Document{} = doc, mutation, opts \\ []) do
    previous_rev = Keyword.get(opts, :previous_rev)
    source = Keyword.get(opts, :source, :api)
    ev = Broadcast.save_event(doc, doc.type, doc.dataset, mutation, previous_rev, source)

    Broadcast.broadcast_document_mutation(doc, mutation,
      event_id: ev.id,
      previous_rev: previous_rev,
      webhooks: true
    )
  rescue
    e ->
      Logger.error(
        "paper change event FAILED for #{inspect(doc.doc_id)} (#{mutation}): " <>
          Exception.message(e) <> " — the paper write itself is committed"
      )

      :ok
  end

  @doc """
  Schedule (or push back) the settled-burst event for `doc`. `previous_rev`
  is the paper's rev before this op; only the FIRST op of a burst sets it,
  because a replaced job keeps its original args.
  """
  @spec settle(Document.t(), String.t() | nil) :: :ok
  def settle(%Document{} = doc, previous_rev) do
    %{
      "doc_id" => doc.doc_id,
      "dataset" => doc.dataset,
      "workspace_id" => doc.workspace_id,
      "project_id" => doc.project_id,
      "previous_rev" => previous_rev
    }
    |> SettleWorker.new(
      schedule_in: settle_seconds(),
      replace: [scheduled: [:scheduled_at]]
    )
    |> Oban.insert()

    :ok
  rescue
    e ->
      Logger.error(
        "paper settle event could not be scheduled for #{inspect(doc.doc_id)}: " <>
          Exception.message(e)
      )

      :ok
  end

  defmodule SettleWorker do
    @moduledoc """
    Fires the one combined change event for a paper's settled editing burst.
    See `Barkpark.Content.Papers.ChangeEvents`.
    """

    # One scheduled job per paper: a new op inside the window moves this job's
    # `scheduled_at` instead of adding a second one.
    use Oban.Worker,
      queue: :default,
      max_attempts: 3,
      unique: [
        keys: [:doc_id, :dataset, :workspace_id, :project_id],
        states: [:scheduled],
        period: :infinity
      ]

    alias Barkpark.Content
    alias Barkpark.Content.Papers.ChangeEvents

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"doc_id" => doc_id, "dataset" => dataset} = args}) do
      scope =
        [workspace_id: args["workspace_id"], project_id: args["project_id"]]
        |> Enum.reject(fn {_k, v} -> is_nil(v) end)

      case Content.get_document(doc_id, "paper", dataset, scope) do
        {:ok, %{rev: rev} = doc} ->
          if rev != args["previous_rev"],
            do: ChangeEvents.announce(doc, "update", previous_rev: args["previous_rev"])

          :ok

        _gone ->
          # Deleted inside the window: the delete path emitted its own event.
          :ok
      end
    end
  end
end
