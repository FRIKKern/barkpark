defmodule Barkpark.Content.Broadcast do
  @moduledoc """
  Post-mutation fan-out: PubSub broadcast, webhook dispatch, revision/event
  persistence, and the single owner of the per-doc topic-string shapes.

  Extracted from `Barkpark.Content`, which keeps a thin delegating facade so
  every external caller (`Tasks`, `Tasks.TtlSweeper`, `Tasks.Compactor`,
  StudioLive, BulldocsLive, `Sheets.Session`) is unchanged.

  ## Deferred-broadcast process-dict protocol (cross-module contract)

  Inside an open `Repo` transaction, broadcasts and webhook dispatches are NOT
  fired immediately — they are queued in the process dictionary so subscribers
  never read state that may still roll back. The keys are part of the contract
  with the mutation spine (`Content.apply_mutations/2`, concern H), which calls
  `flush_deferred_broadcasts/0` on commit and `clear_deferred_broadcasts/0` on
  rollback. The keys MUST stay byte-identical across modules:

    * `:barkpark_deferred_broadcasts` — list of `{topic, msg}` (prepended; the
      flush reverses to restore original order).
    * `:barkpark_deferred_webhooks` — list of
      `{dataset, action, type, doc_id, document, event_id, opts}`.

  ## Topic shapes

  This module is the single owner of the topic-string shapes — callers never
  build topic strings themselves. `doc_topic/4` (ordinary documents) and
  `paper_topic/3` (papers, shared with concern P) both workspace-scope their
  topics via `normalize_topic_ws/1` so colliding per-workspace ids never
  collapse two tenants onto one topic.
  """

  require Logger

  alias Barkpark.Audit
  alias Barkpark.Repo

  alias Barkpark.Content.{Document, DraftId, Envelope, MutationEvent, Revision}

  @paper_type "paper"
  @paper_default_dataset "production"

  @doc """
  Broadcast a document mutation to the dataset, per-doc, and workspace-scoped
  PubSub topics — fired AFTER the writing transaction commits (immediate, no
  deferral). See the original `Content` @doc for the full options contract;
  `mutation` is the caller's mutation kind string and `opts` may carry
  `:event_id` (REQUIRED for the SSE path) and `:previous_rev`.
  """
  @spec broadcast_document_mutation(Document.t(), String.t(), keyword()) :: :ok
  def broadcast_document_mutation(doc, mutation, opts \\ [])

  def broadcast_document_mutation(%Document{} = doc, mutation, opts)
      when is_binary(mutation) do
    event_id = Keyword.get(opts, :event_id)
    previous_rev = Keyword.get(opts, :previous_rev)
    dataset = doc.dataset

    msg = %{
      event_id: event_id,
      type: doc.type,
      mutation: mutation,
      action: :mutate,
      doc_id: doc.doc_id,
      rev: doc.rev,
      previous_rev: previous_rev,
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      document: Envelope.render(doc, nil, :internal),
      doc: %{
        doc_id: doc.doc_id,
        title: doc.title,
        status: doc.status,
        content: doc.content,
        updated_at: doc.updated_at
      },
      sender: self()
    }

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      "documents:#{dataset}",
      {:document_changed, msg}
    )

    Phoenix.PubSub.broadcast(
      Barkpark.PubSub,
      doc_topic(DraftId.published_id(doc.doc_id), doc.type, doc.workspace_id, dataset),
      {:doc_updated, msg}
    )

    if doc.workspace_id do
      Phoenix.PubSub.broadcast(
        Barkpark.PubSub,
        "documents:ws:#{doc.workspace_id}:#{dataset}",
        {:document_changed, msg}
      )
    end

    :ok
  end

  @doc """
  Tap a `{:ok, doc}` write result to persist a revision + mutation event and
  fan out the broadcast/webhook. Passes errors through untouched. Called by the
  write/publish/delete paths (concerns E/F) in `Barkpark.Content`.

  `actor_user_id` (optional, 7th arg, default nil) — the actor threaded from the
  mutation's `opts[:user_id]` (`ctx.user_id`) — is stamped onto the saved
  revision so version history doubles as a who-edited-what content trail.
  Existing 5-/6-arity callers keep working unchanged (actor defaults to nil).
  """
  def tap_broadcast(result, dataset, type, action, prev_rev, source \\ :api, actor_user_id \\ nil) do
    case result do
      {:ok, doc} ->
        save_revision(doc, type, dataset, action, actor_user_id)
        ev = save_event(doc, type, dataset, action, prev_rev, source)
        emit_audit(doc, type, dataset, action, actor_user_id, source)

        msg = %{
          event_id: ev.id,
          type: type,
          mutation: action,
          action: :mutate,
          doc_id: doc.doc_id,
          rev: doc.rev,
          previous_rev: prev_rev,
          # Additive workspace/project context (LOCKED #10): existing
          # subscribers ignore unknown keys; the nextjs revalidate consumer
          # and workspace-scoped subscribers filter on these.
          workspace_id: doc.workspace_id,
          project_id: doc.project_id,
          document: Envelope.render(doc, nil, :internal),
          doc: %{
            doc_id: doc.doc_id,
            title: doc.title,
            status: doc.status,
            content: doc.content,
            updated_at: doc.updated_at
          },
          sender: self()
        }

        global_topic = "documents:#{dataset}"

        # Workspace-scope the per-doc topic (barkpark-rwva, P1 sibling of
        # barkpark-n56v). doc_ids/pubids are per-workspace, so the old
        # workspace-less `doc:<dataset>:<type>:<pubid>` topic collapsed two
        # tenants' colliding-id docs onto ONE topic — an editor in A could
        # receive B's `{:doc_updated,…}`. Stamping the doc's workspace_id keeps
        # them distinct; StudioLive subscribes with current_workspace.id and
        # both sides normalize nil identically (see doc_topic/3).
        doc_topic = doc_topic(DraftId.published_id(doc.doc_id), type, doc.workspace_id, dataset)

        maybe_broadcast(global_topic, {:document_changed, msg})
        maybe_broadcast(doc_topic, {:doc_updated, msg})

        # Additional workspace-scoped topic so consumers can subscribe by
        # workspace without filtering the global stream. ADDITIVE — the
        # global `documents:#{dataset}` topic above is untouched.
        if doc.workspace_id do
          maybe_broadcast(
            "documents:ws:#{doc.workspace_id}:#{dataset}",
            {:document_changed, msg}
          )
        end

        maybe_dispatch_webhook(dataset, action, type, doc.doc_id, msg.document, ev.id,
          workspace_id: doc.workspace_id,
          project_id: doc.project_id
        )

        {:ok, doc}

      error ->
        error
    end
  end

  @doc """
  Run a document write and its `tap_broadcast/7` tail inside ONE transaction, so
  a `save_event` fault takes the document write down with it.

  [acrc-publish-atomicity-txn-boundary] THE HOLE THIS CLOSES. `save_event/6` is
  `Repo.insert!` — it RAISES — precisely so that a document mutation which
  cannot be announced does not survive. That only ever worked inside
  `apply_mutations`' transaction (`mutations.ex`). On the writer single-write
  path (`Writer.upsert_after_gate/6`, `Writer.create_after_dedup/6`) and on the
  publish path (`Lifecycle.publish_document/4`) the document write AUTO-COMMITTED
  and `tap_broadcast` ran after it, so the raise arrived too late: a COMMITTED
  document with no `mutation_events` row, and every consumer that reconciles off
  the event stream — SSE, webhooks, nextjs revalidate, the push outbox — silently
  missing that write forever. Nothing errors afterwards, nothing retries; the
  symptom is the ABSENCE of a symptom, which is why it survived this long.

  ## Why a transaction and not a retry/outbox

  The event row lives in the SAME Postgres database as the document. Two rows in
  one database is the case a transaction was invented for — an outbox or a
  reconciler would add a second failure domain and a lag window to buy an
  atomicity Postgres already sells. The cost usually charged against
  "broadcast inside a transaction" is holding it open on network work; that cost
  is NOT paid here, because the actual PubSub fan-out and webhook dispatch are
  already DEFERRED out of the transaction by `maybe_broadcast/2` and
  `maybe_dispatch_webhook/7`. Only the two INSERTs move inside.

  ## The deferral is why this helper exists rather than a bare Repo.transaction

  `maybe_broadcast/2` queues instead of publishing whenever `in_transaction?`,
  and something must flush the queue. Wrapping a write in a plain
  `Repo.transaction` would therefore SILENCE every broadcast and webhook on that
  path — a worse version of the bug being fixed. This helper owns both halves:
  `flush_deferred_broadcasts/0` on commit, `clear_deferred_broadcasts/0` on
  rollback and on the way out of an exception, matching `apply_mutations`
  (concern H) exactly.

  ## Nesting

  When a transaction is already open the function is run AS IS. An enclosing
  owner (`apply_mutations`) already provides the atomicity and owns the deferred
  queue; opening a second boundary here would hand a nested `Repo.rollback` the
  power to doom it, and flushing here would fire broadcasts for state that can
  still roll back.

  `fun` must return `{:ok, %Document{}}` to commit. Any other term rolls the
  transaction back and is returned to the caller UNCHANGED, so an
  `{:error, changeset}` from the write, an `{:error, :rev_mismatch}` from a
  fence, or a `{:halt, _}` from a hook keeps the exact shape its caller matches
  on today.

  ## One deliberate consequence, stated because it is a behaviour change

  `tap_broadcast/7` also calls `emit_audit/6`, and a failed `Audit.emit/1` inside
  a transaction ABORTS it (see the emit/1 doc — no savepoint, by design). So on
  these paths an unwritable audit row now fails the document write instead of
  logging a warning. That is the semantics `apply_mutations` has always had and
  that `audit.ex` explicitly argues for ("an audit row that cannot be written
  should take the unaudited change down with it") — this makes the single-write
  paths agree with it rather than inventing a new rule.
  """
  @spec write_atomically((-> term())) :: term()
  def write_atomically(fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      fun.()
    else
      Process.put(:barkpark_deferred_broadcasts, [])
      Process.put(:barkpark_deferred_webhooks, [])

      try do
        Repo.transaction(fn ->
          case fun.() do
            {:ok, %Document{}} = ok -> ok
            other -> Repo.rollback({:barkpark_write_atomically, other})
          end
        end)
      rescue
        e ->
          clear_deferred_broadcasts()
          reraise e, __STACKTRACE__
      catch
        kind, reason ->
          clear_deferred_broadcasts()
          :erlang.raise(kind, reason, __STACKTRACE__)
      else
        {:ok, {:ok, %Document{}} = ok} ->
          flush_deferred_broadcasts()
          ok

        # The write itself declined. Unwrap and hand back the caller's own term.
        {:error, {:barkpark_write_atomically, other}} ->
          clear_deferred_broadcasts()
          other

        # A nested `Repo.rollback/1` (the publish path's fenced draft delete, a
        # joined `Audit.emit`) doomed the transaction from inside. Its reason is
        # already the shape the caller matches on.
        {:error, reason} ->
          clear_deferred_broadcasts()
          {:error, reason}
      end
    end
  end

  # Append a content-mutation row to the append-only audit log. Atomic with the
  # mutation when tap_broadcast runs inside the mutate transaction.
  #
  # WHAT THE rescue/Logger.warning BELOW ACTUALLY BUYS YOU, said plainly. This
  # comment used to claim "an audit failure is logged but never breaks a
  # document write (emit opens its own savepoint, so a failed insert rolls back
  # only itself)". Both halves were false. Ecto opens no savepoint for a nested
  # Repo.transaction — Audit.emit/1 joins the mutate transaction, and its
  # Repo.rollback/1 on an insert error dooms that transaction and the document
  # write with it (mode: :savepoint is never passed; see the emit/1 doc in
  # barkpark/audit.ex). Forcing an emit failure on the real mutate path does not
  # produce a logged warning and a completed write: it produces
  # "(DBConnection.ConnectionError) transaction rolling back" and kills the
  # write downstream.
  #
  # So the case/rescue here is DECORATIVE for the in-transaction path: it does
  # catch the {:error, changeset} and the crash, but the connection is already
  # gone and nothing it does can bring the write back. Keep it — it still holds
  # for any caller that emits outside a transaction — but do NOT add a new audit
  # call site believing the log line makes an emit failure survivable. It does
  # not, and unique_index(:audit_events, [:hash]) makes that reachable in prod.
  #
  # The behaviour is intended: an unauditable content mutation should fail loud.
  # api/test/barkpark/audit_savepoint_claim_test.exs pins it and reds if the old
  # savepoint sentence is ever made true.
  defp emit_audit(doc, type, dataset, action, actor_user_id, source) do
    {actor_type, actor_id} =
      if actor_user_id, do: {"user", actor_user_id}, else: {nil, nil}

    result =
      Audit.emit(%{
        category: "content_mutation",
        action: "document.#{action}",
        subject: doc.doc_id,
        actor_type: actor_type,
        actor_id: actor_id,
        workspace_id: doc.workspace_id,
        project_id: doc.project_id,
        metadata: %{
          "type" => type,
          "dataset" => dataset,
          "rev" => doc.rev,
          "source" => to_string(source)
        }
      })

    case result do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("audit emit failed for #{doc.doc_id}: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("audit emit crashed for #{doc.doc_id}: #{inspect(e)}")
  end

  # Defer if we're inside a transaction; broadcast immediately otherwise.
  defp maybe_broadcast(topic, msg) do
    if Repo.in_transaction?() do
      queue = Process.get(:barkpark_deferred_broadcasts, [])
      Process.put(:barkpark_deferred_broadcasts, [{topic, msg} | queue])
    else
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, msg)
    end
  end

  # Personal Dev Fleet listener presence NEVER fans out to remote webhooks
  # (PDF-D18, mirroring the `Sync.Outbox` `type != "listener"` exclusion shipped
  # in #5626): a listener registration is per-machine heartbeat truth, not a
  # content mutation to echo out to arbitrary third-party HTTP endpoints.
  # Head-guarding BEFORE the `in_transaction?` branch below muzzles BOTH the
  # immediate dispatch AND the deferred/flush path — a listener event is never
  # queued, so `flush_deferred_broadcasts/0` has nothing to dispatch.
  defp maybe_dispatch_webhook(
         _dataset,
         _action,
         "listener",
         _doc_id,
         _document,
         _event_id,
         _opts
       ),
       do: :ok

  # Defer webhook dispatch when inside a transaction, fire immediately otherwise.
  # `opts` carries `:workspace_id` / `:project_id` so the delivered payload
  # emits workspace/project-scoped sync-tags.
  defp maybe_dispatch_webhook(dataset, action, type, doc_id, document, event_id, opts) do
    if Repo.in_transaction?() do
      queue = Process.get(:barkpark_deferred_webhooks, [])

      Process.put(
        :barkpark_deferred_webhooks,
        [{dataset, action, type, doc_id, document, event_id, opts} | queue]
      )
    else
      Barkpark.Webhooks.Dispatcher.dispatch_async(
        dataset,
        action,
        type,
        doc_id,
        document,
        event_id,
        opts
      )
    end
  end

  @doc """
  Flush broadcasts queued during a successful transaction, preserving their
  original order (the queue is built by prepending). Called by `apply_mutations`
  (concern H) on commit.
  """
  def flush_deferred_broadcasts do
    queue = Process.delete(:barkpark_deferred_broadcasts) || []

    queue
    |> Enum.reverse()
    |> Enum.each(fn {topic, msg} ->
      Phoenix.PubSub.broadcast(Barkpark.PubSub, topic, msg)
    end)

    webhook_queue = Process.delete(:barkpark_deferred_webhooks) || []

    webhook_queue
    |> Enum.reverse()
    |> Enum.each(fn {dataset, action, type, doc_id, document, event_id, opts} ->
      Barkpark.Webhooks.Dispatcher.dispatch_async(
        dataset,
        action,
        type,
        doc_id,
        document,
        event_id,
        opts
      )
    end)
  end

  @doc """
  Drop any queued broadcasts/webhooks without firing them — called by
  `apply_mutations` (concern H) on rollback.
  """
  def clear_deferred_broadcasts do
    Process.delete(:barkpark_deferred_broadcasts)
    Process.delete(:barkpark_deferred_webhooks)
    :ok
  end

  @doc false
  def save_event(doc, type, dataset, action, prev_rev, source \\ :api) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: dataset,
      type: type,
      doc_id: doc.doc_id,
      mutation: action,
      rev: doc.rev,
      previous_rev: prev_rev,
      document: Envelope.render(doc, nil, :internal),
      # P2 push origin tag: PULL-applied writes (`source: :sync`) are excluded
      # from the push outbox so a pulled mutation never gets pushed back.
      source: to_string(source),
      # Stamp the tenancy scope from the source document so workspace-scoped
      # analytics (recent_activity) only surface a workspace's own events.
      # `dataset_id` is the authoritative dataset leaf (the `dataset` STRING is
      # the mirror): without it, recent_activity's dataset_id-scoped read would
      # miss this event and same-named datasets across projects would conflate.
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      dataset_id: doc.dataset_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  @doc false
  def save_revision(doc, type, dataset, action, actor_user_id \\ nil) do
    %Revision{}
    |> Revision.changeset(%{
      # Terminal lifecycle revisions are written after their source row has
      # been deleted, so they preserve the snapshot without claiming a live
      # document FK. Ordinary writes stay bound and advance the document's
      # current/released revision pointers in the database trigger.
      document_id: if(action in ["delete", "discardDraft"], do: nil, else: doc.id),
      doc_id: DraftId.published_id(doc.doc_id),
      type: type,
      dataset: dataset,
      dataset_id: doc.dataset_id,
      title: doc.title,
      status: doc.status,
      content: doc.content,
      action: action,
      # [rev-hash-has-no-read] Stamp the source document's opaque rev — the same
      # string the envelope publishes as `"_rev"`. This is what makes a `_rev`
      # cited by an acceptance criterion resolvable to the content it names
      # (`Revisions.get_revision_by_rev/3`); without it the hash pointed nowhere.
      rev: doc.rev,
      # WHO produced this revision — threaded from the mutation's user_id
      # (nil for system / unattributed writes).
      #
      # [acrc-publish-atomicity-txn-boundary] This used to read
      # "Atomic-with-mutation: this insert already runs inside apply_mutations'
      # Repo.transaction" as a blanket statement. It was true ONLY of the
      # `apply_mutations` batch path. `tap_broadcast/7` is also reached from the
      # writer single-write path and the publish path, which committed their
      # document write FIRST and called this afterwards — and it is still
      # reached from callers that open no transaction at all (`edges.ex`,
      # `sheets.ex`, `Papers.BlockOps`). Atomicity here is a property of the
      # CALLER, not of this function: it holds inside `apply_mutations`, and now
      # inside `write_atomically/1`, and nowhere else.
      actor_user_id: actor_user_id,
      # Stamp the tenancy scope from the source document so workspace-scoped
      # history reads only surface a workspace's own revisions. `dataset_id` is
      # the authoritative dataset leaf (the `dataset` STRING is the mirror) so a
      # dataset_id-scoped list_revisions read finds it and same-named datasets
      # across projects no longer conflate.
      workspace_id: doc.workspace_id,
      project_id: doc.project_id
    })
    # `mode: :savepoint` is what KEEPS the log-and-continue below honest now that
    # `write_atomically/1` puts this insert inside a transaction on the writer
    # and publish paths. The changeset declares four FK constraints
    # (`revision.ex`), and a violated one — a concurrently hard-deleted scope,
    # the TOCTOU that comment describes — returns `{:error, changeset}`. Without
    # a savepoint that rejection poisons the enclosing transaction, so "history
    # failed, keep the content write" would silently become "history failed,
    # LOSE the content write" — the exact inversion the error arm below refuses.
    # Outside a transaction the option is inert, so the pre-existing callers
    # (BlockOps batch revisions, ValueWriteback provenance) are unchanged.
    |> Repo.insert(mode: :savepoint)
    |> case do
      {:ok, revision} ->
        {:ok, revision}

      {:error, changeset} = err ->
        # [revision-loss-silent] Previously the insert result was DISCARDED, so a
        # failed revision insert silently dropped version history while the doc
        # write committed. We log instead of `insert!`-aborting: a revision is an
        # audit/history artifact, and failing an otherwise-valid content write
        # because history couldn't be persisted is worse than a logged, recoverable
        # gap. The sibling `save_event` stays `insert!` because the mutation-event
        # row drives SSE/webhooks/push-outbox — losing it desyncs live consumers,
        # so there aborting IS correct.
        #
        # [acrc-publish-atomicity-txn-boundary] The parenthetical here used to
        # assert that a returned `{:error, changeset}` was "savepoint-protected"
        # and so could not poison the surrounding transaction. Nothing in the
        # code made that true — no `mode: :savepoint` was passed. It is true NOW,
        # and only because the insert above passes it explicitly.
        Logger.error(
          "revision insert failed for #{doc.type}/#{doc.doc_id} (#{action}): " <>
            inspect(changeset.errors)
        )

        err
    end
  end

  @doc """
  Per-doc PubSub topic for a paper, SCOPED to the owning workspace:
  `doc:ws:<workspace_id>:<dataset>:paper:<slug>`.

  WORKSPACE SCOPE (barkpark-n56v, P0): paper slugs are PER-WORKSPACE (the
  Wave-2 uniqueness flip), so workspace A's `intro` and B's `intro` are
  DISTINCT papers. The old topic `doc:<dataset>:paper:<slug>` had NO workspace
  component, so both papers collapsed onto ONE topic — a write in B leaked its
  rendered body to A's public viewer. The `ws:<workspace_id>` segment keeps the
  topics distinct so a broadcast only reaches subscribers of the SAME workspace.

  Broadcaster and subscriber MUST agree on `workspace_id` for the legitimate
  same-tenant case, or live updates silently stop. Both sides resolve the id
  through `normalize_topic_ws/1`: a present id passes through; a `nil` (legacy
  NULL-workspace row) normalizes to the seeded Default workspace id — the same
  tenant `get_public_paper/2` resolves a public paper into — so the public
  viewer and the broadcaster land on the identical topic. With no seeded
  Default, both sides fall back to the literal `"global"` token, so they still
  agree.

  BulldocsLive subscribes to this; writes broadcast to it.
  """
  def paper_topic(slug, workspace_id, dataset \\ @paper_default_dataset)

  def paper_topic(slug, workspace_id, dataset) when is_binary(slug) do
    "doc:ws:#{normalize_topic_ws(workspace_id)}:#{dataset}:#{@paper_type}:#{slug}"
  end

  @doc "Workspace-scoped topic for changes to the materialised Paper relationship graph."
  def paper_relations_topic(workspace_id, dataset \\ @paper_default_dataset) do
    "paper-relations:ws:#{normalize_topic_ws(workspace_id)}:#{dataset}"
  end

  @doc """
  Per-doc PubSub topic for an ordinary document, SCOPED to the owning
  workspace: `doc:ws:<workspace_id>:<dataset>:<type>:<pubid>`.

  WORKSPACE SCOPE (barkpark-rwva, P1): the old workspace-less
  `doc:<dataset>:<type>:<pubid>` topic collapsed two tenants' colliding
  `(type, pubid)` docs onto one topic, leaking `{:doc_updated,…}` across
  workspaces. The `ws:<workspace_id>` segment keeps them distinct. `pubid` is
  the PUBLISHED id (the caller applies `published_id/1`). Broadcaster
  (`tap_broadcast`) and subscriber (StudioLive `subscribe_to_doc`) MUST agree
  on `workspace_id`; both resolve a nil id through `normalize_topic_ws/1`.
  """
  def doc_topic(pubid, type, workspace_id, dataset)
      when is_binary(pubid) and is_binary(type) do
    "doc:ws:#{normalize_topic_ws(workspace_id)}:#{dataset}:#{type}:#{pubid}"
  end

  # Normalize a (possibly nil) workspace_id into the deterministic token both
  # the broadcast side and the subscribe side use to build a PubSub topic. A
  # present id passes through verbatim. A `nil` id (a legacy NULL-workspace
  # row) maps to the seeded Default workspace id — the public read path
  # (`get_public_paper/2`) resolves into exactly that workspace, so the two
  # sides agree. When NO Default is seeded (fresh sandbox) we fall back to a
  # literal `"global"` token so both sides STILL agree on a non-empty value.
  defp normalize_topic_ws(ws) when is_binary(ws) and ws != "", do: ws

  defp normalize_topic_ws(_nil_or_blank) do
    case Barkpark.Tenancy.get_default_workspace() do
      %{id: ws_id} when is_binary(ws_id) -> ws_id
      _ -> "global"
    end
  end
end
