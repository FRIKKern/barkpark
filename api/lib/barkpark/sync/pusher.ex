defmodule Barkpark.Sync.Pusher do
  @moduledoc """
  Per-event PUSH replay: drains LOCAL `mutation_events` (one event = one remote
  mutation, `id ASC`) to a REMOTE Barkpark, keeping the per-doc CAS chain
  intact. The transport is an INJECTED seam (`push_fun`/`claim_fun`/`close_fun`)
  — the defaults issue real `Req.post`; tests inject fakes (invariant #7).

  ## The pure drain seam

  `drain/3` is the deterministic, directly-tested function (the push mirror of
  `Sync.apply_frames/2`). It `reduce_while`s over events ASC and, per event:

    * route by `event.mutation`: `"task.*"` → the claim/epoch path
      (`claim_fun`/`close_fun`), everything else → the doc push (`push_fun`);
    * `{:ok, remote_rev}` → `PushDocRev.put` + `PushCursor.put(id)` → `:cont`;
    * `{:conflict, attrs}` → `PushConflict.record` + `PushCursor.put(id)` →
      `:cont` (write-then-advance: the remote rejected, the local loser is
      PRESERVED, we advance PAST it but NEVER overwrite the remote — invariant
      #5);
    * `{:error, :transient}` → `:halt`, cursor NOT advanced; the next tick
      replays `id > cursor` from this same event (invariant #3).

  ## Echo-suppression

  Sync-originated events never reach here — `Outbox.fetch/3` excludes
  `source = "sync"` rows (invariant #4). The bounded self-echo residual (we push
  a local write; the remote re-emits it on SSE; pull re-applies it as a fresh
  `"sync"` rev, correctly excluded from re-push) is one round-trip with no
  amplification — identical to the P1 self-echo, not a bug.

  ## Tasks (invariant #6)

  Task events reconcile through the claim/epoch contract, NEVER a content merge.
  `task.claimed`/`task.closed` route to the remote claim/close endpoints
  (`observed_epoch` read from `document.content.claim.epoch`); a
  `fenced_off`/`stale_claim`/`resource_conflict` rejection is recorded as a
  conflict (no merge) and the cursor advances. Other `task.*` lifecycle kinds
  (lease_expired, compaction, …) are deliberate, logged no-ops — pushing them
  would be a content merge.
  """

  require Logger

  alias Barkpark.Sync.{PushConflict, PushCursor, PushDocRev}

  @type ctx :: %{
          required(:source) => String.t(),
          required(:dataset) => String.t(),
          optional(:url) => String.t() | nil,
          optional(:token) => String.t() | nil
        }

  @type funs :: %{
          required(:push_fun) => function(),
          required(:claim_fun) => function(),
          required(:close_fun) => function()
        }

  @doc """
  Drain a list of events (assumed `id ASC`) to the remote. Returns
  `{results, new_cursor}` where `results` is a list of `{event_id, outcome}` in
  drain order and `new_cursor` is the push high-water mark AFTER the drain
  (advanced on every success/conflict, frozen at the last success on a transient
  halt).
  """
  @spec drain([map()], ctx(), funs()) :: {[{integer(), term()}], non_neg_integer()}
  def drain(events, ctx, funs) when is_list(events) do
    start_cursor = PushCursor.get(ctx.source, ctx.dataset)

    {results, cursor} =
      Enum.reduce_while(events, {[], start_cursor}, fn event, {acc, cursor} ->
        case push_one(event, ctx, funs) do
          {:ok, _} = ok ->
            advance(ctx, event)
            {:cont, {[{event.id, ok} | acc], event.id}}

          {:conflict, _} = conflict ->
            # write-then-advance: `push_one` already recorded the conflict row
            # DURABLY (the loser is preserved); only now do we advance the
            # cursor past it. The record-before-advance ordering is what makes
            # this an inspectable quarantine and never a silent skip (invariant
            # #5), while still unblocking the loop.
            advance(ctx, event)
            {:cont, {[{event.id, conflict} | acc], event.id}}

          {:error, :transient} = err ->
            # HALT — cursor is NOT advanced past this un-pushed event.
            {:halt, {[{event.id, err} | acc], cursor}}
        end
      end)

    {Enum.reverse(results), cursor}
  end

  # ── routing ────────────────────────────────────────────────────────────────

  defp push_one(%{mutation: "task." <> _} = event, ctx, funs),
    do: push_task(event, ctx, funs)

  defp push_one(event, ctx, funs), do: push_doc(event, ctx, funs)

  # ── doc push (createOrReplace[+publish] with previous_rev CAS) ───────────────

  defp push_doc(event, ctx, %{push_fun: push_fun}) do
    base_rev = PushDocRev.get(ctx.source, ctx.dataset, event.doc_id)

    case push_fun.(ctx, event, base_rev) do
      {:ok, remote_rev} ->
        PushDocRev.put(ctx.source, ctx.dataset, event.doc_id, remote_rev)
        {:ok, remote_rev}

      {:error, {:rev_mismatch, %{expected: expected, actual: actual}}} ->
        if phantom_double_push?(event, actual) do
          # The remote ALREADY holds our intended write (we pushed, the remote
          # acked, we crashed between ack and cursor-advance; on replay the
          # stale ledger triggers a spurious mismatch whose `actual` is exactly
          # the rev we intended). Reconcile the ledger, advance, NO conflict.
          PushDocRev.put(ctx.source, ctx.dataset, event.doc_id, actual)
          {:ok, :reconciled}
        else
          # A TRUE stale-base conflict: PRESERVE the local loser, never
          # overwrite the remote (invariant #5). write-then-advance.
          PushConflict.record(ctx.source, ctx.dataset, event.id, %{
            doc_id: event.doc_id,
            type: event.type,
            kind: "rev_mismatch",
            local_document: event.document,
            expected_remote_rev: expected,
            actual_remote_rev: actual,
            last_error: "remote rejected createOrReplace: stale CAS base"
          })

          {:conflict, :rev_mismatch}
        end

      {:error, :transient} = err ->
        err
    end
  end

  # The remote's reported current rev equals the rev we were trying to land →
  # the remote already has our write (a crash-window phantom), not a conflict.
  defp phantom_double_push?(event, actual) when is_binary(actual) do
    actual == intended_rev(event)
  end

  defp phantom_double_push?(_event, _actual), do: false

  defp intended_rev(event) do
    case event.document do
      %{"_rev" => rev} when is_binary(rev) -> rev
      _ -> event.rev
    end
  end

  # ── task push (claim/epoch contract — NEVER a content merge, invariant #6) ───

  defp push_task(%{mutation: "task.claimed"} = event, ctx, %{claim_fun: claim_fun}),
    do: reconcile_task(event, ctx, claim_fun, claim_body(event))

  defp push_task(%{mutation: "task.closed"} = event, ctx, %{close_fun: close_fun}),
    do: reconcile_task(event, ctx, close_fun, close_body(event))

  # Other task lifecycle kinds (lease_expired, compacted, relabeled, mutated, …)
  # do not map to the claim/close contract; pushing them would be a content
  # merge (forbidden). Deliberate, LOGGED no-op advance — not a silent skip.
  defp push_task(event, _ctx, _funs) do
    Logger.debug(
      "[Sync.Push] task event #{event.id} (#{event.mutation}) has no claim/close mapping — " <>
        "advancing without push (no content merge; invariant #6)"
    )

    {:ok, :task_noop}
  end

  defp reconcile_task(event, ctx, fun, body) do
    case fun.(ctx, event, body) do
      {:ok, remote_rev} ->
        {:ok, remote_rev}

      {:error, {kind, _meta}} when kind in [:fenced_off, :stale_claim, :resource_conflict] ->
        PushConflict.record(ctx.source, ctx.dataset, event.id, %{
          doc_id: event.doc_id,
          type: event.type,
          kind: to_string(kind),
          local_document: event.document,
          last_error: "remote rejected task #{event.mutation}: #{kind}"
        })

        {:conflict, kind}

      {:error, :transient} = err ->
        err
    end
  end

  defp claim_body(event) do
    claim = get_in(event.document, ["content", "claim"]) || %{}

    %{
      worker_id: claim["worker"],
      resources: get_in(event.document, ["content", "resources"]) || []
    }
  end

  defp close_body(event) do
    claim = get_in(event.document, ["content", "claim"]) || %{}

    %{
      worker_id: claim["worker"],
      observed_epoch: claim["epoch"],
      observed_rev: intended_rev(event),
      lifecycle_status: get_in(event.document, ["content", "lifecycle_status"])
    }
  end

  defp advance(ctx, event), do: PushCursor.put(ctx.source, ctx.dataset, event.id)

  # ── default transport (real Req.post; NEVER exercised in tests) ──────────────

  @doc """
  Default doc transport: one event → one remote mutate batch. The primary
  mutation is base-aware: `create` when the CAS base is UNKNOWN (never acked,
  never primed) — fail-CLOSED, so a doc that unexpectedly exists on the remote
  returns 409 → PushConflict instead of an unconditional overwrite (invariant
  #5); `createOrReplace`+`ifRevisionID` when the base is KNOWN. A conditional
  `publish` is appended in-batch when `_draft == false`. Maps a remote 409/412
  `rev_mismatch` to `{:error, {:rev_mismatch, %{expected, actual}}}`; any other
  non-2xx / exception to `{:error, :transient}`.
  """
  @spec push(ctx(), map(), String.t() | nil) ::
          {:ok, String.t()} | {:error, {:rev_mismatch, map()}} | {:error, :transient}
  def push(ctx, event, if_revision_id) do
    doc = event.document || %{}
    mutations = payload_mutations(doc, event.type, if_revision_id)

    request(ctx, mutate_url(ctx, event), %{"mutations" => mutations})
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, extract_remote_rev(body)}

      {:ok, %{status: status, body: body}} when status in [409, 412] ->
        map_rev_mismatch(body)

      _ ->
        {:error, :transient}
    end
  end

  @doc "Default task-claim transport: POST `/v1/tasks/:doc_id/claim`."
  @spec claim(ctx(), map(), map()) ::
          {:ok, String.t() | nil} | {:error, {atom(), map()}} | {:error, :transient}
  def claim(ctx, event, body),
    do: task_post(ctx, "#{base(ctx)}/v1/tasks/#{event.doc_id}/claim", body)

  @doc "Default task-close transport: POST `/v1/tasks/:doc_id/close`."
  @spec close(ctx(), map(), map()) ::
          {:ok, String.t() | nil} | {:error, {atom(), map()}} | {:error, :transient}
  def close(ctx, event, body),
    do: task_post(ctx, "#{base(ctx)}/v1/tasks/#{event.doc_id}/close", body)

  defp task_post(ctx, url, body) do
    case request(ctx, url, body) do
      {:ok, %{status: status, body: %{"ok" => true} = resp}} when status in 200..299 ->
        {:ok, get_in(resp, ["doc", "_rev"])}

      {:ok, %{body: %{"ok" => false, "reason" => reason} = resp}} ->
        {:error, {String.to_atom(reason), resp}}

      _ ->
        {:error, :transient}
    end
  end

  defp request(ctx, url, body) do
    Req.post(url,
      json: body,
      headers: [{"authorization", "Bearer #{ctx[:token]}"}],
      finch: Barkpark.Sync.Finch,
      retry: false
    )
  rescue
    _ -> {:error, :transient}
  catch
    _, _ -> {:error, :transient}
  end

  @doc """
  Pure mutation-payload builder (testability seam): the primary mutation plus a
  conditional `publish`. `base_rev == nil` → fail-CLOSED `create`;
  `base_rev` known → `createOrReplace`+`ifRevisionID`.
  """
  @spec payload_mutations(map(), String.t() | nil, String.t() | nil) :: [map()]
  def payload_mutations(doc, type, base_rev),
    do: [primary_mutation(doc, base_rev)] ++ maybe_publish(doc, type)

  # base_rev unknown (never acked, never primed) → fail-CLOSED create:
  # a genuinely-new doc lands, a doc that unexpectedly exists on the remote
  # returns 409 → PushConflict (invariant #5), NEVER an unconditional overwrite.
  defp primary_mutation(doc, nil), do: %{"create" => doc}

  defp primary_mutation(doc, rev) when is_binary(rev),
    do: %{"createOrReplace" => Map.put(doc, "ifRevisionID", rev)}

  defp maybe_publish(%{"_draft" => false} = doc, type) when is_binary(type) do
    case doc["_publishedId"] || doc["_id"] do
      id when is_binary(id) -> [%{"publish" => %{"id" => id, "type" => type}}]
      _ -> []
    end
  end

  defp maybe_publish(_doc, _type), do: []

  defp extract_remote_rev(%{"results" => [%{"document" => %{"_rev" => rev}} | _]})
       when is_binary(rev),
       do: rev

  defp extract_remote_rev(_), do: nil

  defp map_rev_mismatch(%{"error" => %{"details" => %{"expected" => e, "actual" => a}}}),
    do: {:error, {:rev_mismatch, %{expected: e, actual: a}}}

  defp map_rev_mismatch(%{"details" => %{"expected" => e, "actual" => a}}),
    do: {:error, {:rev_mismatch, %{expected: e, actual: a}}}

  defp map_rev_mismatch(_), do: {:error, {:rev_mismatch, %{expected: nil, actual: nil}}}

  @doc false
  def mutate_url(ctx, _event \\ nil), do: "#{base(ctx)}/v1/data/mutate/#{ctx.dataset}"

  # SCOPED base: the push target is a specific workspace/project, so every
  # remote write addresses `/w/<ws>/p/<proj>/...`. A flat base would push into
  # the DEFAULT workspace (wrong tenant). Falls back to the bare URL only when
  # workspace/project are absent (never the case when push is active).
  defp base(%{workspace: ws, project: proj} = ctx) when is_binary(ws) and is_binary(proj),
    do: "#{root(ctx)}/w/#{ws}/p/#{proj}"

  defp base(ctx), do: root(ctx)

  defp root(ctx), do: String.trim_trailing(ctx[:url] || "", "/")
end
