defmodule Barkpark.Content.Sessions do
  @moduledoc """
  Append-only event trail on `type:session` documents (session-handoff Task 4).

  A session's `content["events"]` list is a server-stamped, append-only log —
  no update/delete op ever touches it. `append_event/5` rides the SAME
  advisory-lock + CAS-on-rev core as `Barkpark.Tasks.Mutations.update_paper_refs_by_id/4`
  (`Repo.get`-then-`Repo.update_all` guarded on the observed `rev`, under
  `pg_advisory_xact_lock`), mirrored exactly: no draft/published dual-row
  handling, because — like a task — the row this writes IS the row
  `Content.get_blocks_doc/4` resolves. That is the load-bearing detail: the
  generic block-op path (`Content.apply_document_block_op/5`) writes its
  patched content to the `drafts.<slug>` twin, never the row `GET
  /sessions/:slug` reads. An events append must NOT have that bug — it
  fetches via `get_blocks_doc/4` (the same call the GET action uses) and
  updates that exact `doc.id`, so an event logged is an event visible.

  Under the per-slug advisory lock, a losing writer serializes behind the
  winner rather than racing it — the same "extremely rare" CAS-loss posture
  `Barkpark.Tasks` docs for its own mutations — so there is no retry loop
  here, matching `update_paper_refs_by_id/4`'s own (retry-free) shape.

  No test here exercises the advisory lock's actual cross-process
  serialization (two concurrent `append_event/5` calls racing on the same
  slug): `Barkpark.DataCase`'s Ecto SQL sandbox gives each test ONE
  checked-out connection (or an `Ecto.Adapters.SQL.Sandbox.allow/3`-shared
  one), so a real concurrency test would need two independent DB
  connections/processes outside the sandbox's ownership model — impractical
  in this suite. Correctness here rests on `pg_advisory_xact_lock/1` being a
  real Postgres primitive (proven by its existing use in
  `Barkpark.Tasks.Mutations`), not on a test racing it.
  """

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Writer}
  alias Barkpark.Repo

  # Global whitelist (session-handoff charter) — the only event kinds a
  # session's trail may ever carry.
  @event_kinds ["paper-published", "task-closed", "epic-wave-complete", "push", "note"]

  @doc "The closed whitelist of session event kinds."
  def event_kinds, do: @event_kinds

  @doc """
  Append one server-stamped event to `slug`'s `content["events"]` list.
  `attrs` may carry `"ref"` and/or `"note"` (both optional); `kind` must be a
  member of `event_kinds/0`. `ts` is always server-minted (never client-
  supplied) so the trail's ordering/timestamps can't be forged by a caller.

  Returns `{:ok, %{count: n}}` (the trail length after the append),
  `{:error, :not_found}` (no session at `slug`/`dataset`/`opts` scope),
  `{:error, :invalid_kind}`, or `{:error, :stale}` (CAS lost — see the
  moduledoc on why that's not retried here).
  """
  @spec append_event(binary(), binary() | nil, map(), binary(), keyword()) ::
          {:ok, %{count: non_neg_integer()}}
          | {:error, :not_found | :invalid_kind | :stale}
  def append_event(slug, kind, attrs \\ %{}, dataset \\ "production", opts \\ [])

  def append_event(_slug, kind, _attrs, _dataset, _opts) when kind not in @event_kinds,
    do: {:error, :invalid_kind}

  def append_event(slug, kind, attrs, dataset, opts) do
    Repo.transaction(fn ->
      _ = Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["session:#{slug}"])

      case Content.get_blocks_doc(slug, "session", dataset, opts) do
        nil ->
          Repo.rollback(:not_found)

        %Document{} = doc ->
          event =
            %{"ts" => DateTime.utc_now() |> DateTime.to_iso8601(), "kind" => kind}
            |> maybe_put("ref", attrs["ref"])
            |> maybe_put("note", attrs["note"])

          events = (doc.content["events"] || []) ++ [event]
          new_content = Map.put(doc.content, "events", events)

          {rows, _} =
            from(d in Document, where: d.id == ^doc.id and d.rev == ^doc.rev)
            |> Repo.update_all(
              set: [
                content: new_content,
                rev: Writer.generate_rev(),
                updated_at: DateTime.utc_now()
              ]
            )

          if rows == 1, do: %{count: length(events)}, else: Repo.rollback(:stale)
      end
    end)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
