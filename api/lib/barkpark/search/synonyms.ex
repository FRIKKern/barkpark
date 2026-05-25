defmodule Barkpark.Search.Synonyms do
  @moduledoc """
  Surface-scoped synonym map for query expansion (Phase 4).

  `one_way` — searching `from` also matches `to`.
  `alt_correction` — `from` and `to` are interchangeable.
  """

  import Ecto.Query
  alias Barkpark.Search.{MergePattern, Sanitizer, Synonym}
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
      |> Ecto.Changeset.change(%{
        surface: surface,
        scope: scope,
        from_query: from_q,
        to_query: to_q,
        kind: kind,
        source: source,
        enabled: Map.get(attrs, "enabled", true)
      })
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
        %{
          from: fingerprint_query(row.from_fingerprint),
          to: fingerprint_query(row.to_fingerprint),
          kind: "one_way",
          source: "auto",
          transitions: row.transition_count,
          reason: "zero_to_hit"
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
end
