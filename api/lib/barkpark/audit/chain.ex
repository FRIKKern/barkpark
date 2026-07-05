defmodule Barkpark.Audit.Chain do
  @moduledoc """
  Pure hashing for the audit hash chain. Shared by the writer
  (`Barkpark.Audit.emit/1`) and the verifier (`Barkpark.Audit.verify_chain/1`)
  so the exact same bytes are hashed on both sides — the invariant that makes
  tamper-evidence real.

  A row's `hash` is `sha256(prev_hash <> canonical(row))`, hex-encoded.
  `prev_hash` is the previous row's `hash` in the same workspace chain, or the
  empty string for the genesis row.
  """

  @genesis ""

  @typedoc "The business fields that are hashed (never the DB id)."
  @type fields :: %{
          category: String.t(),
          action: String.t(),
          subject: String.t() | nil,
          actor_type: String.t() | nil,
          actor_id: String.t() | nil,
          workspace_id: String.t() | nil,
          project_id: String.t() | nil,
          metadata: map(),
          occurred_at: DateTime.t()
        }

  @doc "The genesis prev_hash — the empty string, for a workspace's first row."
  @spec genesis() :: String.t()
  def genesis, do: @genesis

  @doc """
  Deterministic serialization of a row's business fields. Order-stable and
  independent of the DB id. `metadata` is encoded with sorted keys so two
  logically-equal maps always serialize identically.
  """
  @spec canonical(fields()) :: iodata()
  def canonical(f) do
    Enum.join(
      [
        DateTime.to_iso8601(f.occurred_at),
        to_s(f.category),
        to_s(f.action),
        to_s(f.subject),
        to_s(f.actor_type),
        to_s(f.actor_id),
        to_s(f.workspace_id),
        to_s(f.project_id),
        canonical_metadata(f.metadata)
      ],
      "\n"
    )
  end

  @doc "The chained hash for a row given the previous row's hash (or genesis)."
  @spec hash(fields(), String.t() | nil) :: String.t()
  def hash(fields, prev_hash) do
    prev = prev_hash || @genesis

    :crypto.hash(:sha256, [prev, "\n", canonical(fields)])
    |> Base.encode16(case: :lower)
  end

  @doc """
  Verify a workspace's chain: a list of rows in ascending id order. Returns
  `:ok` when every row's `hash` recomputes and every `prev_hash` links to its
  predecessor; `{:error, {:broken_at, id}}` at the first divergence.
  """
  @spec verify([map()]) :: :ok | {:error, {:broken_at, term()}}
  def verify(rows) do
    Enum.reduce_while(rows, {:ok, @genesis}, fn row, {:ok, expected_prev} ->
      fields = %{
        category: row.category,
        action: row.action,
        subject: row.subject,
        actor_type: row.actor_type,
        actor_id: row.actor_id,
        workspace_id: uuid_to_s(row.workspace_id),
        project_id: uuid_to_s(row.project_id),
        metadata: row.metadata,
        occurred_at: row.occurred_at
      }

      recomputed = hash(fields, expected_prev)

      if (row.prev_hash || @genesis) == expected_prev and row.hash == recomputed do
        {:cont, {:ok, row.hash}}
      else
        {:halt, {:error, {:broken_at, row.id}}}
      end
    end)
    |> case do
      {:ok, _last} -> :ok
      other -> other
    end
  end

  defp to_s(nil), do: ""
  defp to_s(v) when is_binary(v), do: v
  defp to_s(v), do: to_string(v)

  defp uuid_to_s(nil), do: nil

  defp uuid_to_s(v) when is_binary(v) do
    case Ecto.UUID.cast(v) do
      {:ok, s} -> s
      :error -> v
    end
  end

  # Stable JSON-ish encoding of metadata: sort keys recursively so equal maps
  # hash equal. Values are stringified; nested maps recurse.
  defp canonical_metadata(nil), do: ""

  defp canonical_metadata(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_s(k), canonical_value(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(";", fn {k, v} -> k <> "=" <> v end)
  end

  defp canonical_value(v) when is_map(v), do: "{" <> canonical_metadata(v) <> "}"

  defp canonical_value(v) when is_list(v),
    do: "[" <> Enum.map_join(v, ",", &canonical_value/1) <> "]"

  defp canonical_value(v), do: to_s(v)
end
