defmodule Barkpark.Media.StuckProcessingSweeper do
  @moduledoc """
  Recovers `mediaAsset` documents left stranded at `bp_processing_status ==
  "processing"` by a crashed post-upload pipeline.

  `Barkpark.Media.Processing.process/1` runs three NON-transactional
  `Content.upsert_document` writes around remote-fetch + probe + rendition IO:
  `set_status(_, "processing")` (write#1) → `maybe_probe_and_patch` →
  `Renditions.generate_all` → `set_status(_, "ready" | "failed")` (write#3).
  `set_status/3` swallows an upsert `{:error, _}` (logs, returns the OLD doc),
  and `process/1` itself runs INLINE inside `after_media_upload` under
  `ResolverChain.safe_call`, which swallows a RAISE (a vips/ImageBackend port
  crash, OOM, a `Cdn.publish` blow-up) and returns `:ok`. Either way the asset
  is left permanently `"processing"`: a client polling status polls forever, the
  Studio shows a perpetual spinner, and NOTHING ever revisits the row. The only
  out-of-band heal — `media_processing_controller.callback` → `Cdn.publish` — is
  INBOUND-ONLY (an external transcoder must POST it) and never fires for an
  internal image upload, so the stranded state is NOT self-correcting.

  This Oban cron worker is that recovery path, modeled on
  `Barkpark.Webhooks.StuckDeliverySweeper` (the codebase's own precedent for the
  stranded-terminal-state class). Once per minute it:

    1. SELECTs `mediaAsset` docs still `"processing"` whose `updated_at` is older
       than `media_stuck_processing_after_seconds` (default 900s), OLDEST first
       and bounded to `media_stuck_processing_batch_limit` (default 500) so one
       tick never drags an unbounded backlog into memory — the remainder is
       picked up next tick, oldest-first so nothing starves. The threshold sits
       far above the worst-case inline processing window (fetch + probe +
       rendition, seconds), so a genuinely in-flight upload is never a candidate.

       Each candidate is recovered under a per-row `try/rescue`: a re-drive that
       raises is counted `skipped`, logged, and the sweep CONTINUES — one poison
       row can never abort recovery for the rest of the batch.

    2. Re-drives the row with the IDEMPOTENT `Processing.process/1` (every write
       is a full-doc upsert keyed by `doc_id`, so a retry heals rather than
       duplicates). The `MediaFile` is loaded via `content->>"mediaFileId"` +
       `Media.get_file/1`; a `{:error, :not_found}` means the parent blob was
       deleted out from under the doc, so the row is a deleted-parent no-op and
       is skipped.

    3. TERMINATION. The genuine strand is a RAISE, which never reaches
       `process/1`'s graceful `{:error} -> "failed"` write — so a deterministic
       failure (a corrupt image that crashes the backend every time) would loop
       forever. This sweeper therefore owns its OWN attempt counter,
       `content["bp_processing_attempts"]` (none exists in the media domain), and
       bumps it on each re-drive. After `media_stuck_processing_max_attempts`
       (default 5) re-drives it stops re-driving and writes terminal
       `bp_processing_status = "failed"`. `"failed"` (and `"ready"`) are excluded
       from the candidate SELECT by construction, so GIVE-UP self-removes the row
       — no separate cleanup, no infinite loop.

  ## At-least-once `media.processed` on recovery

  A successful re-drive re-fires `media.processed` from inside
  `Processing.process/1`. Media deliveries carry no `event_id`, so — unlike
  document deliveries — this recovery event is NOT deduped by the webhook layer.
  This is an accepted AT-LEAST-ONCE guarantee, bounded to ONE legitimate
  recovery per stranded row: the candidate SELECT excludes `ready`/`failed`, so
  once a re-drive reaches a terminal state the row is never selected again.
  Consumers of `media.processed` must be idempotent. (The proper `event_id`
  dedup is filed separately as `asm-bl-media-delivery-event-id-dedup`; this
  worker deliberately does NOT thread a silent suppression flag through
  `Processing.process/1` — that is out of fence.)

  ## Serialization

  `use Oban.Worker` declares `unique` over the pending/executing states so two
  overlapping cron ticks coalesce into one running sweep — an in-flight sweep
  can never race a second sweep and clobber a just-written terminal `"ready"`
  back to `"processing"`. Within a single sweep, each candidate is re-read fresh
  immediately before the write and skipped if it is no longer `"processing"`
  (an external callback healed it in the meantime).

  Configuration (all `Application.get_env(:barkpark, …)`, tests override):
  `:media_stuck_processing_after_seconds` (300..∞, default 900),
  `:media_stuck_processing_batch_limit` (default 500),
  `:media_stuck_processing_max_attempts` (default 5),
  `:media_stuck_reprocess_fun` (default `&Processing.process/1`; a test seam so a
  deterministic RAISE can be injected to prove give-up).
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing]]

  import Ecto.Query
  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Media.Processing
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo

  @asset_type "mediaAsset"
  @status_key "bp_processing_status"
  @attempts_key "bp_processing_attempts"
  @media_file_key "mediaFileId"

  @default_after_seconds 900
  @default_batch_limit 500
  @default_max_attempts 5

  @impl Oban.Worker
  def perform(%Oban.Job{} = _job) do
    {:ok, sweep(after_seconds())}
  end

  @doc """
  Pure entry point — bypasses Oban.Job wrapping so tests can drive the sweep
  deterministically. Returns `%{swept: N, skipped: M}`. An empty candidate set
  returns `%{swept: 0, skipped: 0}` — it never raises on "nothing to do."
  """
  @spec sweep(non_neg_integer()) :: %{swept: non_neg_integer(), skipped: non_neg_integer()}
  def sweep(after_seconds) when is_integer(after_seconds) and after_seconds >= 0 do
    cutoff = DateTime.utc_now() |> DateTime.add(-after_seconds, :second)

    stuck_candidates(cutoff)
    |> Enum.reduce(%{swept: 0, skipped: 0}, fn %Document{} = doc, acc ->
      # Per-row isolation: a re-drive that raises (a poison image that crashes
      # the backend, an unexpected error) is counted `skipped`, logged, and the
      # sweep CONTINUES. The row keeps its bumped attempt counter, so a later
      # tick retries it and — past the attempt ceiling — gives up terminally.
      try do
        case recover_one(doc) do
          :swept -> %{acc | swept: acc.swept + 1}
          :skipped -> %{acc | skipped: acc.skipped + 1}
        end
      rescue
        e ->
          Logger.error(
            "StuckProcessingSweeper skipped mediaAsset #{inspect(doc.doc_id)} " <>
              "(dataset=#{inspect(doc.dataset)}) after #{inspect(e.__struct__)}: " <>
              Exception.message(e)
          )

          %{acc | skipped: acc.skipped + 1}
      end
    end)
  end

  # Candidate set: type mediaAsset, still `"processing"`, untouched since before
  # the cutoff. Oldest first (so nothing starves), bounded per pass. `ready` and
  # `failed` rows fail the status filter — terminal states are never revisited.
  defp stuck_candidates(%DateTime{} = cutoff) do
    from(d in Document,
      where:
        d.type == ^@asset_type and
          fragment("?->>? = ?", d.content, ^@status_key, "processing") and
          d.updated_at < ^cutoff,
      order_by: [asc: d.updated_at],
      limit: ^batch_limit()
    )
    |> Repo.all()
  end

  defp recover_one(%Document{} = doc) do
    media_file_id = Map.get(doc.content || %{}, @media_file_key)

    with true <- is_binary(media_file_id),
         {:ok, file} <- Media.get_file(media_file_id),
         %Document{} = fresh <- reload(file),
         "processing" <- Map.get(fresh.content || %{}, @status_key) do
      drive(fresh, file)
    else
      # No mediaFileId, deleted parent blob, doc vanished, or already healed to a
      # terminal state since the SELECT — nothing to recover, no-op skip.
      _ -> :skipped
    end
  end

  # Re-read the row fresh under its own tenant scope right before writing, so an
  # external callback that healed it between SELECT and now is respected (the
  # `"processing"` guard in `recover_one/1` short-circuits on the fresh read).
  defp reload(file) do
    Assets.find_by_media_file_id(file.id, file.dataset, Assets.file_scope_opts(file))
  end

  defp drive(%Document{} = doc, file) do
    attempts = current_attempts(doc)

    if attempts >= max_attempts() do
      # GIVE UP. The strand is a RAISE that bypasses process()'s graceful
      # {:error} -> "failed" write, so re-driving forever would never terminate.
      # Write the terminal state ourselves; "failed" is excluded from the SELECT
      # by construction, so the row self-removes from every future sweep.
      put_content(doc, file, %{@status_key => "failed"})

      Logger.warning(
        "StuckProcessingSweeper gave up on mediaAsset #{inspect(doc.doc_id)} " <>
          "after #{attempts} re-drives — marked failed"
      )

      :swept
    else
      # Bump our own attempt counter BEFORE re-driving (also bumps updated_at,
      # keeping overlapping passes off this row for the moment). Then re-drive
      # the idempotent pipeline: on success it writes terminal ready/failed and
      # the row leaves the SELECT; on a RAISE the rescue in sweep/1 leaves the
      # row "processing" with the bumped counter for the next tick.
      put_content(doc, file, %{@attempts_key => attempts + 1})
      reprocess_fun().(file)
      :swept
    end
  end

  defp current_attempts(%Document{content: content}) do
    case Map.get(content || %{}, @attempts_key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> 0
    end
  end

  # Merge `changes` into the doc's content and persist via the SAME worker-source
  # upsert path `Processing.set_status/3` uses (full-doc upsert keyed by doc_id,
  # tenant scope carried from the blob). No DB transaction is opened over any IO.
  defp put_content(%Document{} = doc, file, changes) do
    content = Map.merge(doc.content || %{}, changes)

    attrs = %{
      "doc_id" => doc.doc_id,
      "title" => doc.title,
      "status" => doc.status,
      "content" => content
    }

    case Content.upsert_document(
           @asset_type,
           attrs,
           file.dataset,
           [source: :worker] ++ Assets.file_scope_opts(file)
         ) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning("StuckProcessingSweeper content write failed: #{inspect(reason)}")
        doc
    end
  end

  defp after_seconds do
    Application.get_env(:barkpark, :media_stuck_processing_after_seconds, @default_after_seconds)
  end

  defp batch_limit do
    Application.get_env(:barkpark, :media_stuck_processing_batch_limit, @default_batch_limit)
  end

  defp max_attempts do
    Application.get_env(:barkpark, :media_stuck_processing_max_attempts, @default_max_attempts)
  end

  defp reprocess_fun do
    Application.get_env(:barkpark, :media_stuck_reprocess_fun, &Processing.process/1)
  end
end
