defmodule Barkpark.Tasks.Internal do
  @moduledoc false
  # Shared low-level primitives for the task CAS write paths. Extracted from
  # `Barkpark.Tasks` so the facade and the per-operation modules
  # (`Tasks.Mutations`, …) reuse one definition instead of each carrying its own
  # rev/event/broadcast helpers. Pure substrate — no public task API lives here.

  alias Barkpark.Content
  alias Barkpark.Content.{Document, MutationEvent}
  alias Barkpark.Repo

  # New rev token, same shape as `Content.generate_rev/0`. Kept here so the task
  # modules do not depend on a private function in another module.
  def generate_rev do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  def current_epoch(%Document{content: %{"claim" => %{"epoch" => e}}}) when is_integer(e), do: e
  def current_epoch(_), do: 0

  # Mutation-events insert. The existing `mutation_events` schema (used by the
  # document spine) is reused verbatim — the `mutation` text column carries our
  # `task.claimed` / `task.closed` / `task.mutated` kinds, the `document` map
  # carries an Envelope-shaped view of the post-update row. Tenancy stamps mirror
  # `Content.save_event/6` so workspace-scoped `recent_activity` reads surface
  # task ops.
  #
  # `source` (P2 push origin tag) defaults to "api" so task events are LOCAL by
  # default → pushable, routed to the claim/epoch path by `type`. Stamping
  # "sync" for a remote-claim-mirror-back requires a seam through tasks.ex and
  # is DEFERRED to P3 — all current callers (in tasks.ex, untouched) use the
  # default.
  def insert_mutation_event!(%Document{} = doc, kind, previous_rev, source \\ "api") do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: doc.dataset,
      type: doc.type,
      doc_id: doc.doc_id,
      mutation: kind,
      rev: doc.rev,
      previous_rev: previous_rev,
      source: to_string(source),
      document: %{
        "doc_id" => doc.doc_id,
        "type" => doc.type,
        "title" => doc.title,
        "status" => doc.status,
        "content" => doc.content,
        "rev" => doc.rev
      },
      workspace_id: doc.workspace_id,
      project_id: doc.project_id,
      dataset_id: doc.dataset_id,
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  # Every CAS write path bypasses Content's canonical write path
  # (`tap_broadcast/5`), so these mirror its PubSub so the SSE listen endpoint
  # and workspace activity reads see task ops. Content stays the single owner of
  # the topic shapes — task_broadcast/4 only assembles the payload; emit fires it.
  def task_broadcast(%Document{} = doc, kind, %MutationEvent{} = ev, previous_rev) do
    %{doc: doc, kind: kind, event_id: ev.id, previous_rev: previous_rev}
  end

  def emit_broadcasts(broadcasts) when is_list(broadcasts) do
    Enum.each(broadcasts, fn %{doc: doc, kind: kind, event_id: eid, previous_rev: prev} ->
      Content.broadcast_document_mutation(doc, kind, event_id: eid, previous_rev: prev)
    end)

    :ok
  end
end
