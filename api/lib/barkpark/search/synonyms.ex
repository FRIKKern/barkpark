defmodule Barkpark.Search.Synonyms do
  @moduledoc """
  Surface-scoped synonym map for query expansion (Phase 4).

  `one_way` — searching `from` also matches `to`.
  `alt_correction` — `from` and `to` are interchangeable.
  """

  import Ecto.Query
  alias Barkpark.Content.Scope
  alias Barkpark.Search.{Crystal, Crystallizer, MergePattern, Sanitizer, Synonym}
  alias Barkpark.Repo

  @kinds ~w(one_way alt_correction)
  @sources ~w(manual auto)

  @spec list(String.t(), String.t(), binary() | nil) :: [map()]
  def list(surface, scope, workspace_id \\ nil) when is_binary(surface) and is_binary(scope) do
    from(s in Synonym,
      where: s.surface == ^surface and s.scope == ^scope,
      order_by: [asc: s.from_query, asc: s.to_query]
    )
    |> scope_to_workspace(workspace_id)
    |> Repo.all()
    |> Enum.map(&synonym_payload/1)
  end

  @spec create(String.t(), String.t(), map(), binary() | nil) ::
          {:ok, map()} | {:error, Ecto.Changeset.t()}
  def create(surface, scope, attrs, workspace_id \\ nil)
      when is_binary(surface) and is_binary(scope) do
    from_q = normalize_field(attrs, :from_query, "from")
    to_q = normalize_field(attrs, :to_query, "to")

    kind = normalize_kind(Map.get(attrs, "kind") || Map.get(attrs, :kind))
    source = normalize_source(Map.get(attrs, "source") || Map.get(attrs, :source))

    if from_q in [nil, ""] or to_q in [nil, ""] do
      {:error, invalid_changeset("from and to are required")}
    else
      %Synonym{}
      |> Synonym.changeset(
        %{
          surface: surface,
          scope: scope,
          from_query: from_q,
          to_query: to_q,
          kind: kind,
          source: source,
          enabled: Map.get(attrs, "enabled", true)
        }
        |> put_dataset_id(scope)
        |> put_workspace_id(workspace_id)
      )
      |> Repo.insert()
      |> case do
        {:ok, row} -> {:ok, synonym_payload(row)}
        error -> error
      end
    end
  end

  @spec delete(String.t(), String.t(), String.t(), binary() | nil) :: :ok | {:error, :not_found}
  def delete(id, surface, scope, workspace_id \\ nil)
      when is_binary(surface) and is_binary(scope) do
    # Guard the raw :id path param: a non-UUID would raise Ecto.CastError (→ 500)
    # inside Repo.get on the :binary_id primary key. Treat it as not_found.
    case Repo.uuid_or_nil(id) do
      nil ->
        {:error, :not_found}

      uuid ->
        case Repo.get(Synonym, uuid) do
          %Synonym{surface: ^surface, scope: ^scope} = row ->
            # Tenant guard: a workspace-scoped caller may delete ONLY its own row
            # or a legacy/global (NULL-workspace) row — never a sibling
            # workspace's row sharing the dataset slug. A nil workspace_id
            # (anonymous / unscoped / pre-tenancy) keeps the legacy behaviour
            # (surface+scope match is sufficient).
            if workspace_deletable?(row, workspace_id) do
              # A concurrent double-DELETE would raise Ecto.StaleEntryError (→ 500);
              # stale_error_field turns the race into a changeset error → :not_found.
              case Repo.delete(row, stale_error_field: :id) do
                {:ok, _} -> :ok
                {:error, _cs} -> {:error, :not_found}
              end
            else
              {:error, :not_found}
            end

          nil ->
            {:error, :not_found}

          _ ->
            {:error, :not_found}
        end
    end
  end

  @doc """
  Expand a raw query into distinct search terms (original + synonym targets).
  """
  @spec search_terms(String.t(), String.t(), String.t(), binary() | nil) :: [String.t()]
  def search_terms(surface, scope, query, workspace_id \\ nil)
      when is_binary(surface) and is_binary(scope) do
    raw = String.trim(query || "")

    if raw == "" do
      []
    else
      normalized = Sanitizer.normalize(raw)

      rows =
        from(s in Synonym,
          where:
            s.surface == ^surface and s.scope == ^scope and s.enabled == true and
              (s.from_query == ^normalized or
                 (s.kind == "alt_correction" and s.to_query == ^normalized))
        )
        |> scope_to_workspace(workspace_id)
        |> Repo.all()

      expanded =
        Enum.reduce(rows, [raw, normalized], fn row, acc ->
          case row.kind do
            "alt_correction" ->
              [row.from_query, row.to_query | acc]

            _ ->
              [row.to_query | acc]
          end
        end)

      expanded
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end
  end

  @doc """
  The canonical corrected spelling for a raw query, or `nil` when no enabled
  synonym fires for it.

  Semantics — given the normalized query `q`:

    * a `one_way` row with `from_query == q` → its `to_query` (the target term);
    * an `alt_correction` row with `from_query == q` → its `to_query`
      (the counterpart "correct" side);
    * an `alt_correction` row with `to_query == q` → its `from_query`
      (the other side).

  Only enabled rows count. When several rows match, the first by stable
  `(from_query, to_query)` order wins. Used by the query pipeline to surface
  `corrected_to` so the UI can show "Showing results for <term>".
  """
  @spec correction_for(String.t(), String.t(), String.t(), binary() | nil) :: String.t() | nil
  def correction_for(surface, scope, query, workspace_id \\ nil)

  def correction_for(surface, scope, query, workspace_id)
      when is_binary(surface) and is_binary(scope) and is_binary(query) do
    normalized = Sanitizer.normalize(query)

    if normalized == "" do
      nil
    else
      from(s in Synonym,
        where:
          s.surface == ^surface and s.scope == ^scope and s.enabled == true and
            (s.from_query == ^normalized or
               (s.kind == "alt_correction" and s.to_query == ^normalized)),
        order_by: [asc: s.from_query, asc: s.to_query],
        limit: 1
      )
      |> scope_to_workspace(workspace_id)
      |> Repo.one()
      |> case do
        nil ->
          nil

        %Synonym{kind: "alt_correction", to_query: ^normalized, from_query: from_q} ->
          if from_q in [nil, "", normalized], do: nil, else: from_q

        %Synonym{to_query: to_q} ->
          if to_q in [nil, "", normalized], do: nil, else: to_q
      end
    end
  end

  def correction_for(_surface, _scope, _query, _workspace_id), do: nil

  @spec candidates(String.t(), String.t(), keyword()) :: [map()]
  def candidates(surface, scope, opts \\ [])
      when is_binary(surface) and is_binary(scope) do
    workspace_id = Keyword.get(opts, :workspace_id)
    period = opts |> Keyword.get(:period, "week") |> to_string()

    # The default MUST be the key the crystallizer WROTE, not "seven days ago".
    # `Date.add(today, -7)` coincides with the Monday-anchored week key only on
    # Mondays, so this query matched nothing six days in seven and `candidates/3`
    # answered an empty list with no error — see Crystallizer.period_start_for/2.
    period_start =
      case Keyword.get(opts, :period_start) do
        %Date{} = date -> date
        _ -> Crystallizer.period_start_for(period)
      end

    merge_candidates =
      from(m in MergePattern,
        where:
          m.surface == ^surface and m.scope == ^scope and m.period == ^period and
            m.period_start == ^period_start and m.pattern_type == "zero_to_hit" and
            m.transition_count >= 3,
        order_by: [desc: m.transition_count],
        limit: 20
      )
      |> scope_rollup_to_workspace(workspace_id)
      |> Repo.all()
      |> Enum.map(fn row ->
        from_q = fingerprint_query(row.from_fingerprint)
        to_q = fingerprint_query(row.to_fingerprint)

        %{
          from: from_q,
          to: to_q,
          kind: "one_way",
          source: "auto",
          transitions: row.transition_count,
          reason: "zero_to_hit",
          evidence:
            candidate_evidence(
              surface,
              scope,
              from_q,
              to_q,
              row.transition_count,
              {period, period_start},
              workspace_id
            )
        }
      end)
      |> Enum.reject(fn c -> c.from in [nil, ""] or c.to in [nil, ""] end)

    existing =
      from(s in Synonym,
        where: s.surface == ^surface and s.scope == ^scope and s.enabled == true,
        select: {s.from_query, s.to_query}
      )
      |> scope_to_workspace(workspace_id)
      |> Repo.all()
      |> MapSet.new()

    merge_candidates
    |> Enum.reject(fn c -> MapSet.member?(existing, {c.from, c.to}) end)
    |> Enum.uniq_by(fn c -> {c.from, c.to} end)
  end

  @spec promote(String.t(), String.t(), map(), binary() | nil) ::
          {:ok, map()} | {:error, :invalid | :missing_fields | Ecto.Changeset.t()}
  def promote(surface, scope, attrs, workspace_id \\ nil)
      when is_binary(surface) and is_binary(scope) do
    from_q = normalize_field(attrs, :from_query, "from")
    to_q = normalize_field(attrs, :to_query, "to")

    if from_q in [nil, ""] or to_q in [nil, ""] do
      {:error, :missing_fields}
    else
      create(
        surface,
        scope,
        %{
          "from" => from_q,
          "to" => to_q,
          "kind" => Map.get(attrs, "kind") || Map.get(attrs, :kind) || "one_way",
          "source" => "auto"
        },
        workspace_id
      )
    end
  end

  @spec preview(String.t(), String.t(), String.t() | nil, map(), binary() | nil) :: map()
  def preview(surface, scope, query, attrs \\ %{}, workspace_id \\ nil)
      when is_binary(surface) and is_binary(scope) do
    from_q = normalize_field(attrs, :from_query, "from") || query
    to_q = normalize_field(attrs, :to_query, "to")

    before =
      if is_binary(from_q) and from_q != "" do
        preview_count(surface, scope, from_q, workspace_id)
      else
        0
      end

    after_count =
      if is_binary(to_q) and to_q != "" do
        preview_count(surface, scope, to_q, workspace_id)
      else
        before
      end

    %{
      from: from_q,
      to: to_q,
      beforeCount: before,
      afterCount: after_count
    }
  end

  defp preview_count("documents", scope, query, workspace_id) do
    {_, count, _} =
      Barkpark.Content.search_documents(query, scope, maybe_workspace([limit: 1], workspace_id))

    count
  end

  defp preview_count("media", scope, query, workspace_id) do
    {_, count, _, _} =
      Barkpark.Media.search_files(scope, maybe_workspace([q: query, limit: 1], workspace_id))

    count
  end

  defp preview_count(_, _, _, _), do: 0

  # The evidence describes the SAME window as the merge pattern it annotates, so
  # it takes that window rather than re-deriving one. The old body hardcoded
  # `period: "week", period_start: Date.add(today, -7)` — the wrong key six days
  # in seven, AND the wrong window whenever a caller passed an explicit one, so
  # fromZeroHitRate/toCtr silently read 0.0 and every confidence score collapsed
  # to the transition term alone.
  defp candidate_evidence(surface, scope, from_q, to_q, transitions, window, workspace_id) do
    from_stats = crystal_stats(surface, scope, from_q, window, workspace_id)
    to_stats = crystal_stats(surface, scope, to_q, window, workspace_id)

    from_zero =
      if from_stats.search_count > 0 do
        from_stats.zero_hit_count / from_stats.search_count
      else
        0.0
      end

    confidence =
      transitions
      |> Kernel./(10)
      |> min(1.0)
      |> Kernel.*(0.5)
      |> Kernel.+(to_stats.ctr * 0.5)
      |> Float.round(2)

    %{
      fromZeroHitRate: Float.round(from_zero, 2),
      toCtr: Float.round(to_stats.ctr, 2),
      confidence: confidence
    }
  end

  # Query (not get_by), and workspace-keyed. The bare
  # `Repo.get_by(Crystal, surface:, scope:, period:, period_start:,
  # query_normalized:, filter_fingerprint:)` this replaces carried NO workspace
  # key, which the per-tenant partial unique index
  # (`search_intel_crystals_ws_unique_idx`, migration 20260715121000) turned
  # into a CRASH: that index exists precisely so two workspaces sharing a scope
  # STRING each keep their OWN roll-up row for the same query, so as soon as a
  # second tenant crystallized a query the get_by matched two rows and raised
  # `Ecto.MultipleResultsError` — an uncaught 500 on GET
  # /v1/search/:dataset/insights for EVERY tenant asking about that query.
  # A keyword get_by also cannot express the nil arm at all (Ecto forbids
  # `= nil`; the legacy bucket needs `IS NULL`), which is the same reason
  # `Intelligence.quality_stats/5` and `Crystallizer.upsert_crystal/1` are
  # already written this way. This site was the one that was missed.
  defp crystal_stats(surface, scope, query, {period, period_start}, workspace_id)
       when is_binary(query) do
    normalized = Sanitizer.normalize(query)

    from(c in Crystal,
      where:
        c.surface == ^surface and c.scope == ^scope and c.period == ^period and
          c.period_start == ^period_start and c.query_normalized == ^normalized and
          c.filter_fingerprint == ""
    )
    |> scope_rollup_to_workspace(workspace_id)
    |> Repo.one()
    |> case do
      nil ->
        %{search_count: 0, zero_hit_count: 0, ctr: 0.0}

      row ->
        %{search_count: row.search_count, zero_hit_count: row.zero_hit_count, ctr: row.ctr || 0.0}
    end
  end

  defp crystal_stats(_, _, _, _, _), do: %{search_count: 0, zero_hit_count: 0, ctr: 0.0}

  @doc false
  def fingerprint_query(fingerprint) when is_binary(fingerprint) do
    fingerprint
    |> String.split("|", parts: 2)
    |> List.first()
    |> case do
      "q:" <> query -> String.trim(query)
      _ -> nil
    end
  end

  def fingerprint_query(_), do: nil

  defp synonym_payload(%Synonym{} = s) do
    %{
      id: s.id,
      surface: s.surface,
      scope: s.scope,
      from: s.from_query,
      to: s.to_query,
      kind: s.kind,
      source: s.source,
      enabled: s.enabled,
      insertedAt: s.inserted_at,
      updatedAt: s.updated_at
    }
  end

  defp normalize_field(attrs, atom_key, string_key) do
    value = Map.get(attrs, atom_key) || Map.get(attrs, string_key)

    case value do
      v when is_binary(v) ->
        v |> String.trim() |> Sanitizer.normalize()

      _ ->
        nil
    end
  end

  defp normalize_kind(kind) when kind in @kinds, do: kind
  defp normalize_kind("alt"), do: "alt_correction"
  defp normalize_kind(_), do: "one_way"

  defp normalize_source(source) when source in @sources, do: source
  defp normalize_source(_), do: "manual"

  defp invalid_changeset(message) do
    %Synonym{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:from_query, message)
  end

  # W2 dual-write: resolve the synonym's `scope` STRING → its `dataset_id`
  # (within the seeded Default project — the search surface is single-project
  # today) and stamp it alongside `scope`. Keeps the new `(surface, dataset_id,
  # ...)` unique index meaningful; the `scope` string stays as the mirror.
  # No-ops (leaves attrs unchanged) when the dataset can't be resolved.
  defp put_dataset_id(attrs, scope) when is_binary(scope) do
    case Barkpark.Tenancy.default_project_dataset_id(scope) do
      id when is_binary(id) -> Map.put(attrs, :dataset_id, id)
      _ -> attrs
    end
  end

  # W7 tenancy: stamp the caller's `workspace_id` on the write so the per-tenant
  # partial unique index (`workspace_id IS NOT NULL`) keys the row to its owning
  # workspace — two workspaces sharing the `production` slug can each hold the
  # same synonym without the cross-tenant `dataset_id` collision (the live 500).
  # No-op for a nil workspace_id (legacy/global write path preserved).
  defp put_workspace_id(attrs, workspace_id) when is_binary(workspace_id),
    do: Map.put(attrs, :workspace_id, workspace_id)

  defp put_workspace_id(attrs, _), do: attrs

  # Tenant read boundary for SYNONYM rows. A workspace-scoped caller sees its
  # own rows PLUS the legacy/global (NULL-workspace) shared layer — never a
  # sibling workspace's rows under a shared dataset slug. That shared layer is
  # deliberate, which is why this routes through
  # `Scope.scope_to_workspace_including_global/3` and NOT through the
  # workspace-only `Scope.scope_to_workspace/3`; the two are not
  # interchangeable, and swapping in the latter would silently blind every
  # tenant to the shared synonyms.
  #
  # The `nil` mapping is the fix. The old catch-all was
  # `defp scope_to_workspace(query, _), do: query` — a nil workspace_id (what
  # the controllers' `workspace_id(conn)` yields when `:current_workspace` is
  # absent, i.e. an anonymous / unresolved-tenant caller) left the query
  # COMPLETELY UNFILTERED and read EVERY tenant's synonym rows. `:shared_only`
  # makes nil mean the shared/global bucket (`workspace_id IS NULL`), matching
  # the documented nil semantics of the sibling `Intelligence.scope_ws/2` and
  # `Crystallizer.scope_workspace/2` — a single-tenant/pre-tenancy instance,
  # whose rows all carry a NULL workspace_id, still reads exactly what it wrote.
  defp scope_to_workspace(query, workspace_id) do
    # global-read: the synonym table has a DELIBERATELY SHARED NULL-workspace layer (the legacy/global synonyms every tenant is meant to inherit), so the _including_global family IS the intended read here — the fail-closed scope_to_workspace/3 would silently blind every tenant to the shared rows. This call is NOT fail-open: nil is mapped to the :shared_only sentinel, so an unresolved tenant reads the shared layer ALONE instead of every workspace's rows, which is exactly the leak this line replaces.
    Scope.scope_to_workspace_including_global(query, workspace_id || :shared_only, nil)
  end

  # Tenant leaf for the intel ROLL-UP tables (Crystal, MergePattern) — a
  # DIFFERENT boundary from `scope_to_workspace/2` above, deliberately. Roll-ups
  # are per-tenant aggregates with NO shared layer: a workspace's insights must
  # never blend a sibling's counts, and a NULL-workspace legacy row belongs to
  # the legacy bucket alone. `nil` therefore means `workspace_id IS NULL`, never
  # "every tenant". Byte-identical to `Intelligence.scope_ws/2` and
  # `Crystallizer.scope_workspace/2`, which read these same two tables.
  defp scope_rollup_to_workspace(query, workspace_id),
    do: Scope.scope_to_workspace(query, workspace_id || :shared_only)

  # Delete tenant guard — a workspace-scoped caller may remove its own row or a
  # legacy/global (NULL-workspace) row, but not a sibling workspace's. Mirrors
  # the read visibility in scope_to_workspace/2. A nil workspace_id keeps the
  # pre-tenancy behaviour (surface+scope match is authorization enough).
  defp workspace_deletable?(_row, nil), do: true
  defp workspace_deletable?(%Synonym{workspace_id: nil}, ws) when is_binary(ws), do: true
  defp workspace_deletable?(%Synonym{workspace_id: wid}, ws), do: wid == ws

  defp maybe_workspace(opts, workspace_id) when is_binary(workspace_id),
    do: Keyword.put(opts, :workspace_id, workspace_id)

  defp maybe_workspace(opts, _), do: opts
end
