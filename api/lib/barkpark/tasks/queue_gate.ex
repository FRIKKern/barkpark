defmodule Barkpark.Tasks.QueueGate do
  @moduledoc """
  Strict, versioned execution gate carried by a Task.

  Persisted version-1 states describe author-controlled readiness. A live
  claim owned by another worker is intentionally not persisted as a gate:
  `execution_class/2` derives `foreign_claimed` from authoritative claim state.
  Legacy Tasks without `queue_gate` remain executable.

  A claim map OUTLIVES its lease, so "is there a `claim.worker`" is not the
  same question as "does anybody hold this row". `claim_lease_live?/1` is the
  one place that answers the second one, and `live_claim_worker/1` and
  `executable_query/0` — the Elixir predicate and its SQL twin — both call it.
  """

  @version 1
  @persisted_states ~w(executable human_gated parked evidence_stalled)
  @derived_states ["foreign_claimed" | @persisted_states]
  @allowed_fields ~w(version state reason evidence)
  @default_lease_ttl_seconds 2700
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

  "Live" is `live_claim_worker/1` below, and it is live in three parts: a
  worker name, no close stamp, AND a lease that has not lapsed
  (`claim_lease_live?/1`, measured against `:task_lease_ttl_seconds` — the
  same TTL `TtlSweeper` reaps on).
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

  @doc """
  Is this content's `claim` a LEASE, or RESIDUE a lease left behind?

  Compares `claim.ts_iso` against the SAME `:task_lease_ttl_seconds` the
  `TtlSweeper` reaps on, read from config rather than hardcoded, so the two
  cannot drift apart.

  FAILS CLOSED ON PURPOSE: no timestamp, or one that will not parse, counts as
  LIVE. This predicate can only ever DOWNGRADE somebody from holder to residue,
  so an unprovable case must keep the protective answer — a parse bug here
  would hand one lane another lane's row, which is worse than the bug it fixes.

  WHY IT IS NEEDED AT ALL, given the sweeper: `TtlSweeper.expired_candidates/2`
  selects only rows whose `lifecycle_status` is `in_progress`. `bp task stage
  <id> open` moves a row OUT of `in_progress` without touching `content.claim`
  (Stage "never reads or writes `content.claim`"), so a staged-open row keeps
  its dead holder's name FOREVER and no sweep will ever blank it.
  """
  @spec claim_lease_live?(map() | nil) :: boolean()
  def claim_lease_live?(content) when is_map(content),
    do: content |> fetch("claim") |> lease_live?()

  def claim_lease_live?(_content), do: true

  @doc """
  The claim lease TTL in seconds — `:task_lease_ttl_seconds`, default 2700.

  ONE reader for a number that had grown three private copies (this module,
  `TasksController`, `TasksController.Params`). `TtlSweeper` keeps its own
  because it is the writer of the reap boundary, not a reader of it.
  """
  @spec lease_ttl_seconds() :: non_neg_integer()
  def lease_ttl_seconds,
    do: Application.get_env(:barkpark, :task_lease_ttl_seconds, @default_lease_ttl_seconds)

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
      # The SQL half of `lease_live?/1`. CASE, not `AND`, because Postgres is
      # free to reorder the arms of an AND — the CASE pins the order so the
      # shape guard always runs first.
      #
      # THERE IS NO CAST, AND THAT IS THE POINT. A `::timestamptz` cast RAISES
      # on a malformed string rather than returning NULL, and this query gates
      # the READY QUEUE: one bad `ts_iso` anywhere in the ready population would
      # break `bp task ready` and `bp task next` for everyone — strictly worse
      # than the defect this predicate exists to fix. Found by lead-ledger-c5's
      # fence review, which measured it: the earlier prefix regex admitted
      # anything with a well-formed first 19 characters straight into the cast.
      #
      # ANCHORING ALONE WOULD NOT HAVE FIXED IT — a regex cannot validate
      # CALENDAR semantics. '2026-13-45T99:99:99Z' and '2026-02-30T12:00:00Z'
      # both match a fully anchored pattern and both still raise. So the shape
      # guard and the comparison each do the job the other cannot: the anchored
      # pattern (T and Z REQUIRED, which is what every writer emits — claim.ex
      # :446 and :527 and pulse.ex:177 are all `DateTime.utc_now() |>
      # DateTime.to_iso8601()`) makes LEXICOGRAPHIC ordering well-defined, and
      # the text comparison cannot raise whatever the tail says.
      #
      # Requiring `T` and `Z` is load-bearing, not tidiness: a space separator
      # sorts BELOW 'T', and a '-05:00' offset compares by its literal local
      # digits — either would let a live claim read as expired, which is the one
      # direction that must never fail. Anything not matching falls to `false`,
      # i.e. NOT expired, i.e. still claim-held: the same FAIL-CLOSED direction
      # the Elixir arm takes.
      #
      # The cutoff carries no trailing `Z` so a fractional stamp at the exact
      # boundary second sorts GREATER than it — erring toward LIVE by under a
      # second against a 2700-second lease.
      (fragment("COALESCE(btrim(?->'claim'->>'worker'), '') = ''", d.content) or
         fragment("COALESCE(btrim(?->'claim'->>'closed_at'), '') <> ''", d.content) or
         fragment("COALESCE(btrim(?->'claim'->>'closed_by'), '') <> ''", d.content) or
         fragment(
           "CASE WHEN ?->'claim'->>'ts_iso' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?Z$' THEN ?->'claim'->>'ts_iso' < to_char(now() - (? * interval '1 second'), 'YYYY-MM-DD\"T\"HH24:MI:SS') ELSE false END",
           d.content,
           d.content,
           ^lease_ttl_seconds()
         )) and
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

  # Every call site passes a compile-time string literal — "claim",
  # "queue_gate", "state", "worker", "closed_at", "closed_by" — so
  # `String.to_atom/1` can only ever mint atoms from that fixed, closed set.
  # No request data reaches `key`, so the atom table cannot be grown by input.
  # Inline rather than a line-pinned `.sobelow-skips` row: the row this
  # replaces (queue_gate.ex:245) was already dead from an edit above it.
  # sobelow_skip ["DOS.StringToAtom"]
  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  # Same closed set as `fetch/2` above: the only caller passes the literal
  # "queue_gate". Bounded atom creation, no request data on `key`.
  # Replaces the two dead line-pinned rows at queue_gate.ex:252.
  # sobelow_skip ["DOS.StringToAtom"]
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
  #
  # THE THIRD PART, and the one the docstring above used to promise without
  # checking (task-f48b0d7c943fc3a5): A LEASE THAT HAS NOT LAPSED. Without it
  # "live" meant "has a worker name and was never closed", under which a claim
  # that expired SIX DAYS AGO is LIVE — and every reader of `execution_class/2`
  # was told `foreign_claimed` about a row nobody holds. `TtlSweeper` does NOT
  # cover this: it only reaps `in_progress` rows, so a row staged back to `open`
  # keeps its dead holder's name permanently. See `claim_lease_live?/1`, which
  # fails CLOSED so this arm can only ever release a row, never take one.
  defp live_claim_worker(claim) when is_map(claim) do
    worker = fetch(claim, "worker")

    if non_blank?(worker) and not closed_claim?(claim) and lease_live?(claim),
      do: worker,
      else: nil
  end

  defp live_claim_worker(_claim), do: nil

  defp closed_claim?(claim),
    do: non_blank?(fetch(claim, "closed_at")) or non_blank?(fetch(claim, "closed_by"))

  defp lease_live?(claim) when is_map(claim) do
    case fetch(claim, "ts_iso") do
      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, claimed_at, _} ->
            DateTime.diff(DateTime.utc_now(), claimed_at) < lease_ttl_seconds()

          _ ->
            true
        end

      _ ->
        true
    end
  end

  defp lease_live?(_claim), do: true

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""
end
