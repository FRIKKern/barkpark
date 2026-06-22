defmodule Barkpark.Search.Synonyms do
  @moduledoc """
  Surface-scoped synonym map for query expansion (Phase 4).

  `one_way` — searching `from` also matches `to`.
  `alt_correction` — `from` and `to` are interchangeable.
  """

  import Ecto.Query
  alias Barkpark.Search.{Crystal, MergePattern, Sanitizer, Synonym}
  alias Barkpark.Repo

  @kinds ~w(one_way alt_correction)
  @sources ~w(manual auto)

  @spec list(String.t(), String.t()) :: [map()]
  def list(surface, scope) when is_binary(surface) and is_binary(scope) do
    from(s in Synonym,
      where: s.surface == ^surface and s.scope == ^scope,
      order_by: [asc: s.from_query, asc: s.to_query]
    )
    |> Repo.all()
    |> Enum.map(&synonym_payload/1)
  end

  @spec create(String.t(), String.t(), map()) :: {:ok, map()} | {:error, Ecto.Changeset.t()}
  def create(surface, scope, attrs) when is_binary(surface) and is_binary(scope) do
    from_q = normalize_field(attrs, :from_query, "from")
    to_q = normalize_field(attrs, :to_query, "to")

    kind = normalize_kind(Map.get(attrs, "kind") || Map.get(attrs, :kind))
    source = normalize_source(Map.get(attrs, "source") || Map.get(attrs, :source))

    if from_q in [nil, ""] or to_q in [nil, ""] do
      {:error, invalid_changeset("from and to are required")}
    else
      %Synonym{}
      |> Ecto.Changeset.change(
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
      )
      |> Repo.insert()
      |> case do
        {:ok, row} -> {:ok, synonym_payload(row)}
        error -> error
      end
    end
  end

  @spec delete(Ecto.UUID.t(), String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete(id, surface, scope) when is_binary(surface) and is_binary(scope) do
    case Repo.get(Synonym, id) do
      %Synonym{surface: ^surface, scope: ^scope} = row ->
        Repo.delete!(row)
        :ok

      nil ->
        {:error, :not_found}

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  Expand a raw query into distinct search terms (original + synonym targets).
  """
  @spec search_terms(String.t(), String.t(), String.t()) :: [String.t()]
  def search_terms(surface, scope, query) when is_binary(surface) and is_binary(scope) do
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
  @spec correction_for(String.t(), String.t(), String.t()) :: String.t() | nil
  def correction_for(surface, scope, query)
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

  def correction_for(_surface, _scope, _query), do: nil

  @spec candidates(String.t(), String.t(), keyword()) :: [map()]
  def candidates(surface, scope, opts \\ [])
      when is_binary(surface) and is_binary(scope) do
    period = opts |> Keyword.get(:period, "week") |> to_string()

    period_start =
      case Keyword.get(opts, :period_start) do
        %Date{} = date -> date
        _ -> Date.add(Date.utc_today(), -7)
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
          evidence: candidate_evidence(surface, scope, from_q, to_q, row.transition_count)
        }
      end)
      |> Enum.reject(fn c -> c.from in [nil, ""] or c.to in [nil, ""] end)

    existing =
      from(s in Synonym,
        where: s.surface == ^surface and s.scope == ^scope and s.enabled == true,
        select: {s.from_query, s.to_query}
      )
      |> Repo.all()
      |> MapSet.new()

    merge_candidates
    |> Enum.reject(fn c -> MapSet.member?(existing, {c.from, c.to}) end)
    |> Enum.uniq_by(fn c -> {c.from, c.to} end)
  end

  @spec promote(String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, :invalid | :missing_fields | Ecto.Changeset.t()}
  def promote(surface, scope, attrs) when is_binary(surface) and is_binary(scope) do
    from_q = normalize_field(attrs, :from_query, "from")
    to_q = normalize_field(attrs, :to_query, "to")

    if from_q in [nil, ""] or to_q in [nil, ""] do
      {:error, :missing_fields}
    else
      create(surface, scope, %{
        "from" => from_q,
        "to" => to_q,
        "kind" => Map.get(attrs, "kind") || Map.get(attrs, :kind) || "one_way",
        "source" => "auto"
      })
    end
  end

  @spec preview(String.t(), String.t(), String.t() | nil, map()) :: map()
  def preview(surface, scope, query, attrs \\ %{})
      when is_binary(surface) and is_binary(scope) do
    from_q = normalize_field(attrs, :from_query, "from") || query
    to_q = normalize_field(attrs, :to_query, "to")

    before =
      if is_binary(from_q) and from_q != "" do
        preview_count(surface, scope, from_q)
      else
        0
      end

    after_count =
      if is_binary(to_q) and to_q != "" do
        preview_count(surface, scope, to_q)
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

  defp preview_count("documents", scope, query) do
    {_, count, _} = Barkpark.Content.search_documents(query, scope, limit: 1)
    count
  end

  defp preview_count("media", scope, query) do
    {_, count, _, _} = Barkpark.Media.search_files(scope, q: query, limit: 1)
    count
  end

  defp preview_count(_, _, _), do: 0

  defp candidate_evidence(surface, scope, from_q, to_q, transitions) do
    from_stats = crystal_stats(surface, scope, from_q)
    to_stats = crystal_stats(surface, scope, to_q)

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

  defp crystal_stats(surface, scope, query) when is_binary(query) do
    case Repo.get_by(Crystal,
           surface: surface,
           scope: scope,
           period: "week",
           period_start: Date.add(Date.utc_today(), -7),
           query_normalized: Sanitizer.normalize(query),
           filter_fingerprint: ""
         ) do
      nil ->
        %{search_count: 0, zero_hit_count: 0, ctr: 0.0}

      row ->
        %{search_count: row.search_count, zero_hit_count: row.zero_hit_count, ctr: row.ctr || 0.0}
    end
  end

  defp crystal_stats(_, _, _), do: %{search_count: 0, zero_hit_count: 0, ctr: 0.0}

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
end
