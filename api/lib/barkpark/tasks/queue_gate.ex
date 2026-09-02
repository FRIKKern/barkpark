defmodule Barkpark.Tasks.QueueGate do
  @moduledoc """
  Strict, versioned execution gate carried by a Task.

  Persisted version-1 states describe author-controlled readiness. A live
  claim owned by another worker is intentionally not persisted as a gate:
  `execution_class/2` derives `foreign_claimed` from authoritative claim state.
  Legacy Tasks without `queue_gate` remain executable.
  """

  @version 1
  @persisted_states ~w(executable human_gated parked evidence_stalled)
  @derived_states ["foreign_claimed" | @persisted_states]
  @allowed_fields ~w(version state reason evidence)
  @reason_max_bytes 500
  @evidence_max_bytes 1_000

  @type gate :: %{String.t() => term()}

  import Ecto.Query, only: [dynamic: 2]

  @doc "Persistable queue gate states. `foreign_claimed` is derived only."
  @spec persisted_states() :: [String.t()]
  def persisted_states, do: @persisted_states

  @doc "All execution classes readers may observe."
  @spec execution_classes() :: [String.t()]
  def execution_classes, do: @derived_states

  @doc "Validate an optional queue gate without returning its normalized form."
  @spec validate(nil | map()) :: :ok | {:error, map()}
  def validate(gate) do
    case sanitize(gate) do
      {:ok, _} -> :ok
      {:error, errors} -> {:error, errors}
    end
  end

  @doc "Validate and normalize a version-1 queue gate."
  @spec sanitize(nil | map()) :: {:ok, nil | gate()} | {:error, map()}
  def sanitize(nil), do: {:ok, nil}

  def sanitize(gate) when is_map(gate) do
    with {:ok, normalized} <- normalize_keys(gate),
         :ok <- reject_unknown_fields(normalized),
         :ok <- validate_version(normalized),
         :ok <- validate_state(normalized),
         :ok <- validate_state_fields(normalized) do
      {:ok, sanitize_values(normalized)}
    end
  end

  def sanitize(other),
    do: {:error, %{"value" => ["must be a map when set, got #{inspect(other)}"]}}

  @doc """
  Derive the current execution class from Task content and a prospective worker.

  A LIVE claim owned by a different worker always wins as `foreign_claimed`.
  The current holder sees the persisted class. Missing gates and legacy content
  default to `executable`.

  "Live" is `live_claim_worker/1` below: a worker name AND no close stamp.
  """
  @spec execution_class(map() | nil, String.t() | nil) :: String.t()
  def execution_class(content, worker_id \\ nil)

  def execution_class(content, worker_id) when is_map(content) do
    claim_worker = content |> fetch("claim") |> live_claim_worker()

    if not is_nil(claim_worker) and claim_worker != worker_id do
      "foreign_claimed"
    else
      case fetch(content, "queue_gate") do
        gate when is_map(gate) -> fetch(gate, "state") || "executable"
        _ -> "executable"
      end
    end
  end

  def execution_class(_content, _worker_id), do: "executable"

  @doc "True only when persisted gate state is valid and executable for the worker."
  @spec executable?(map() | nil, String.t() | nil) :: boolean()
  def executable?(content, worker_id \\ nil)

  def executable?(content, worker_id) when is_map(content) do
    execution_class(content, worker_id) == "executable" and
      case fetch_optional(content, "queue_gate") do
        :absent -> true
        {:present, nil} -> true
        {:present, gate} -> sanitize(gate) == {:ok, %{"version" => 1, "state" => "executable"}}
      end
  end

  def executable?(_content, _worker_id), do: false

  @doc "Fail-closed SQL predicate matching executable?/2 for unclaimed ready rows."
  def executable_query do
    dynamic(
      [doc: d],
      # SQL TWIN of `live_claim_worker/1`. The two predicates answer the same
      # question on the same JSON and MUST move together: the Elixir arm gates
      # the targeted claim (`Claim.check_executable_for_targeted_claim/2`), this
      # one gates the ready queue that `bp task ready` / `bp task next` read.
      # Fixing only one leaves a reopened row claimable-by-name but invisible
      # on the board — the SAME bug wearing the other half of its face.
      (fragment("COALESCE(btrim(?->'claim'->>'worker'), '') = ''", d.content) or
         fragment("COALESCE(btrim(?->'claim'->>'closed_at'), '') <> ''", d.content) or
         fragment("COALESCE(btrim(?->'claim'->>'closed_by'), '') <> ''", d.content)) and
        (not fragment("jsonb_exists(?, 'queue_gate')", d.content) or
           fragment("?->'queue_gate'", d.content) == fragment("'null'::jsonb") or
           fragment("?->'queue_gate'", d.content) ==
             fragment("'{\"version\": 1, \"state\": \"executable\"}'::jsonb"))
    )
  end

  defp normalize_keys(gate) do
    Enum.reduce_while(gate, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      normalized_key =
        case key do
          key when is_binary(key) -> key
          key when is_atom(key) -> Atom.to_string(key)
          _ -> nil
        end

      cond do
        is_nil(normalized_key) ->
          {:halt, {:error, %{"queue_gate" => ["keys must be strings, got #{inspect(key)}"]}}}

        Map.has_key?(acc, normalized_key) ->
          {:halt,
           {:error, %{normalized_key => ["is duplicated by both atom and string key forms"]}}}

        true ->
          {:cont, {:ok, Map.put(acc, normalized_key, value)}}
      end
    end)
  end

  defp reject_unknown_fields(gate) do
    case Map.keys(gate) -- @allowed_fields do
      [] ->
        :ok

      unknown ->
        {:error,
         Map.new(unknown, fn field ->
           {field, ["is not allowed in queue_gate version 1"]}
         end)}
    end
  end

  defp validate_version(%{"version" => @version}), do: :ok

  defp validate_version(%{"version" => other}),
    do: {:error, %{"version" => ["must be integer #{@version}, got #{inspect(other)}"]}}

  defp validate_version(_), do: {:error, %{"version" => ["is required and must be integer 1"]}}

  defp validate_state(%{"state" => state}) when state in @persisted_states, do: :ok

  defp validate_state(%{"state" => "foreign_claimed"}),
    do:
      {:error,
       %{"state" => ["foreign_claimed is derived from live claim state and cannot be persisted"]}}

  defp validate_state(%{"state" => other}),
    do:
      {:error,
       %{"state" => ["must be one of #{inspect(@persisted_states)}, got #{inspect(other)}"]}}

  defp validate_state(_), do: {:error, %{"state" => ["is required"]}}

  defp validate_state_fields(%{"state" => "executable"} = gate) do
    errors =
      %{}
      |> forbid_present(gate, "reason", "must be absent when state is executable")
      |> forbid_present(gate, "evidence", "must be absent when state is executable")

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  defp validate_state_fields(%{"state" => state} = gate) do
    errors =
      %{}
      |> require_non_blank(gate, "reason", @reason_max_bytes)
      |> check_optional_non_blank(gate, "evidence", @evidence_max_bytes)
      |> require_evidence_when_stalled(state, gate)

    if errors == %{}, do: :ok, else: {:error, errors}
  end

  defp require_evidence_when_stalled(errors, "evidence_stalled", gate),
    do: require_non_blank(errors, gate, "evidence", @evidence_max_bytes)

  defp require_evidence_when_stalled(errors, _state, _gate), do: errors

  defp forbid_present(errors, gate, field, message) do
    if Map.has_key?(gate, field), do: Map.put(errors, field, [message]), else: errors
  end

  defp require_non_blank(errors, gate, field, max_bytes) do
    case Map.get(gate, field) do
      value when is_binary(value) ->
        validate_bounded_string(errors, field, value, max_bytes)

      nil ->
        Map.put(errors, field, ["is required"])

      other ->
        Map.put(errors, field, ["must be a string, got #{inspect(other)}"])
    end
  end

  defp check_optional_non_blank(errors, gate, field, max_bytes) do
    case Map.get(gate, field) do
      nil -> errors
      value when is_binary(value) -> validate_bounded_string(errors, field, value, max_bytes)
      other -> Map.put(errors, field, ["must be a string when set, got #{inspect(other)}"])
    end
  end

  defp validate_bounded_string(errors, field, value, max_bytes) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        Map.put(errors, field, ["must not be blank"])

      byte_size(trimmed) > max_bytes ->
        Map.put(errors, field, ["must be at most #{max_bytes} bytes"])

      true ->
        errors
    end
  end

  defp sanitize_values(gate) do
    gate
    |> Map.take(@allowed_fields)
    |> Map.new(fn
      {field, value} when field in ["reason", "evidence"] and is_binary(value) ->
        {field, String.trim(value)}

      pair ->
        pair
    end)
  end

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp fetch_optional(map, key) do
    cond do
      Map.has_key?(map, key) -> {:present, Map.get(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:present, Map.get(map, String.to_atom(key))}
      true -> :absent
    end
  end

  # A claim is LIVE only while it names a worker AND carries no close stamp.
  #
  # `close` DELIBERATELY keeps `claim.worker` and adds `closed_by` + `closed_at`
  # (close.ex, "Stamp close metadata into the claim lease") so the ledger
  # remembers who finished the work. `Stage` — the only door to the `done → open`
  # reopen (Transitions D7) — "never reads or writes `content.claim`". So a
  # REOPENED task still wears its dead holder's name, and deriving
  # `foreign_claimed` from that name made every reopened row PERMANENTLY
  # unclaimable by a new worker (hit live on stw7-backlog-drafts-clamp-gap).
  #
  # Why the close stamp and not `lifecycle_status`: the two OTHER ways a lease
  # ends already blank the worker — `Release` sets `claim.worker` nil, and
  # `TtlSweeper.apply_reap/1` does the same while KEEPING "closed_by/closed_at
  # history if it was set". Close is the one exit that leaves a name behind, so
  # the close stamp is exactly the missing bit, and reading it keeps this
  # predicate claim-local (the same map `executable_query/0` can see in SQL).
  #
  # Agrees with `Claim.renewal?/2` by construction: renewal requires
  # `lifecycle_status == "in_progress"`, which a closed-then-reopened row is
  # not — so neither predicate calls a closed claim live, and the holder cannot
  # renew a lease a contender may now take.
  defp live_claim_worker(claim) when is_map(claim) do
    worker = fetch(claim, "worker")

    if non_blank?(worker) and not closed_claim?(claim), do: worker, else: nil
  end

  defp live_claim_worker(_claim), do: nil

  defp closed_claim?(claim),
    do: non_blank?(fetch(claim, "closed_at")) or non_blank?(fetch(claim, "closed_by"))

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""
end
