defmodule Barkpark.Plugins.Github.Conflicts do
  @moduledoc """
  Recorder for the GitHub sync quarantine (`github_sync_conflicts`, epic D7).

  "Ledger wins on disagreement, but disagreement is VISIBLE." When the mirror
  detects out-of-band drift, a detached/deleted issue, or a dedup-refused
  intake, it RECORDS the fact here before (or instead of) converging. The
  wave-6 ops console and a maintainer read these open rows to reconcile by hand.

  DB-only by design: this module NEVER touches `Content.*` or emits a
  `mutation_events` row. A conflict record is out-of-band bookkeeping, not a
  task mutation, so it can never re-trigger sync — there is no loop surface.

  ## Dedup

  `record/1` collapses repeats: an already-OPEN conflict for the same
  `{repo, issue, kind}` is UPDATED in place (its `detail` MERGED — never
  overwritten — and its `updated_at` bumped) rather than piling a second row. A
  human editing an issue five times is ONE open `out_of_band_edit`, never five;
  and two independent sources touching that one row (a drift fingerprint plus a
  later GraphQL projection note) both survive on its `detail`. A row only
  re-opens as a fresh record once the prior one is `resolve/1`-d.
  """

  import Ecto.Query

  alias Barkpark.Plugins.Github.Conflict
  alias Barkpark.Repo

  @doc """
  Record a conflict, deduping an already-open one for the same
  `{repo, issue, kind}`.

  If an unresolved row for that key exists, its `detail` (and `updated_at`) are
  updated in place; otherwise a new row is inserted. Runs in a transaction with
  a row lock so two concurrent records for the same key collapse to one open
  row. Returns `{:ok, %Conflict{}}` or `{:error, changeset}`.
  """
  @spec record(map()) :: {:ok, Conflict.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    attrs = normalize(attrs)

    result = Repo.transaction(fn -> upsert(attrs) end)

    case result do
      {:ok, {:ok, conflict}} -> {:ok, conflict}
      {:ok, {:error, cs}} -> {:error, cs}
      {:error, cs} -> {:error, cs}
    end
  end

  # Insert-or-update under a row lock. Fast path: an open row for the key is
  # locked (FOR UPDATE) and refreshed in place. First-record path: insert. If a
  # concurrent record won the insert race between our open_row read and our own
  # insert, the partial unique index rejects ours as a matched constraint error
  # (savepoint-scoped inside the transaction); we then re-read the winner — now
  # lock-visible — and converge onto it, so the pile the FOR UPDATE alone could
  # not prevent is impossible.
  defp upsert(attrs) do
    case open_row(attrs) do
      nil ->
        case insert_new(attrs) do
          {:error, cs} = err ->
            if open_key_conflict?(cs) do
              case open_row(attrs) do
                nil -> err
                existing -> refresh(existing, attrs)
              end
            else
              err
            end

          ok ->
            ok
        end

      existing ->
        refresh(existing, attrs)
    end
  end

  defp open_key_conflict?(%Ecto.Changeset{errors: errors}) do
    name = to_string(Conflict.open_key_constraint())

    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique and
        Keyword.get(opts, :constraint_name) == name
    end)
  end

  # Find + lock an open row for this dedup key (nil when there is none).
  defp open_row(%{repo: repo, issue: issue, kind: kind})
       when is_binary(repo) and is_integer(issue) and is_binary(kind) do
    from(c in Conflict,
      where:
        c.repo == ^repo and c.issue == ^issue and c.kind == ^kind and
          is_nil(c.resolved_at),
      order_by: [desc: c.id],
      limit: 1,
      lock: "FOR UPDATE"
    )
    |> Repo.one()
  end

  # A key with a non-binary repo/kind or non-integer issue can't dedup — let the
  # changeset produce the validation error on insert.
  defp open_row(_attrs), do: nil

  defp insert_new(attrs) do
    %Conflict{}
    |> Conflict.changeset(attrs)
    |> Repo.insert()
  end

  # Merge the incoming detail INTO the recorded one rather than overwriting it.
  # The same open `{repo, issue, kind}` row can be refreshed from independent
  # sources — e.g. an `out_of_band_edit` first recorded with the observed
  # title/state fingerprint, then re-touched by a Projects-v2 GraphQL projection
  # error carrying a `source: "graphql"` note. Overwriting would clobber the
  # human-drift detail with the last writer's payload, hiding half the story
  # from the operator reading the quarantine. Map.merge keeps both; a colliding
  # key takes the newest value (last write wins per-key, not per-map). A nil
  # incoming detail is treated as an empty map so it never nulls the accumulated
  # detail.
  defp refresh(existing, attrs) do
    merged = Map.merge(existing.detail || %{}, Map.get(attrs, :detail) || %{})

    existing
    |> Conflict.changeset(%{detail: merged})
    |> Repo.update()
  end

  @doc """
  Open conflicts (`resolved_at IS NULL`), newest-first.

  Options:

    * `:repo`  — only conflicts for this repo
    * `:kind`  — only this drift kind
    * `:limit` — cap the result (default 100)
  """
  @spec list(keyword()) :: [Conflict.t()]
  def list(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    Conflict
    |> where([c], is_nil(c.resolved_at))
    |> maybe_filter(:repo, Keyword.get(opts, :repo))
    |> maybe_filter(:kind, Keyword.get(opts, :kind))
    |> order_by([c], desc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, :repo, repo), do: where(query, [c], c.repo == ^repo)
  defp maybe_filter(query, :kind, kind), do: where(query, [c], c.kind == ^kind)

  @doc """
  Mark a conflict resolved (drops it out of `list/1`). Idempotent — resolving
  an already-resolved or missing row returns `{:error, :not_found}` only when
  the row does not exist; a re-resolve keeps the original `resolved_at`.
  """
  @spec resolve(integer()) :: {:ok, Conflict.t()} | {:error, :not_found}
  def resolve(id) do
    case Repo.get(Conflict, id) do
      nil ->
        {:error, :not_found}

      %Conflict{resolved_at: %DateTime{}} = already ->
        {:ok, already}

      %Conflict{} = conflict ->
        conflict
        |> Ecto.Changeset.change(resolved_at: DateTime.utc_now())
        |> Repo.update()
    end
  end

  # Accept string OR atom keys (a controller/JSON caller vs an internal caller),
  # normalizing to the atom-keyed shape the changeset + dedup query expect.
  defp normalize(attrs) do
    %{
      repo: fetch(attrs, :repo),
      issue: coerce_issue(fetch(attrs, :issue)),
      doc_id: fetch(attrs, :doc_id),
      dataset: fetch(attrs, :dataset),
      kind: fetch(attrs, :kind),
      detail: fetch(attrs, :detail) || %{}
    }
  end

  # A JSON/form caller may hand `issue` as a numeric string. Coerce it to an
  # integer so the dedup key (open_row's `is_integer` guard) matches instead of
  # silently falling through to a non-deduped insert. A non-numeric string is
  # left as-is for the changeset to reject.
  defp coerce_issue(issue) when is_binary(issue) do
    case Integer.parse(issue) do
      {n, ""} -> n
      _ -> issue
    end
  end

  defp coerce_issue(issue), do: issue

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, v} -> v
      :error -> Map.get(attrs, to_string(key))
    end
  end
end
