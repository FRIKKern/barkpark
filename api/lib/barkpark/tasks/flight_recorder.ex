defmodule Barkpark.Tasks.FlightRecorder do
  @moduledoc """
  THE TWO ENDS OF A LEASE THAT NOBODY RECORDED (task-a42dccec2fe4a406, under
  epic task-b55fafd148bb2578).

  A claim records WHO took a row and WHEN. A close records who sealed it. Neither
  records what the agent was HOLDING at either end — which primer documents it had
  read, at which bytes, from which checkout, at which HEAD, under which model; and
  at the other end, the compact of what it actually learned. The CLI already writes
  the first half to a LOCAL directory (PR #19114,
  `internal/cli/tasks_priming_manifest.go`, schema=1), which is exactly as durable
  as the machine it ran on. This module is the part that reaches the ledger.

  TWO FIELDS, ONE LEASE. Both land INSIDE `content.claim`, beside `work_digest`
  and `session_origin`, because both are facts ABOUT THE LEASE and not about the
  row: `claim.priming_start` is stamped by the claim that opened it, and
  `claim.context_compact` by the close that sealed it. A re-claim opens a NEW
  lease and therefore a new (empty) recorder — which is correct, and is the reason
  they are not top-level content keys that would silently outlive their flight.

  ## The three-state law (inherited verbatim from the local manifest)

      absent   UNMEASURED — the caller sent nothing. NOTHING is stored, and the
               key reads back ABSENT: not `null`, not `{}`. A reader that finds
               no key knows only that nobody measured.
      present  a RECORD — the caller sent something and it is stored verbatim.

  The whole value of the distinction is that a claim carrying no manifest must be
  BYTE-IDENTICAL to one issued before this module existed. `put_priming_start/2`
  and `put_context_compact/2` are `Map.put` only on the present arm; there is no
  arm that writes a placeholder.

  ## The bound

  `context_compact` is agent-written prose and therefore unbounded by nature, so
  the server bounds it at #{16 * 1024} bytes — `byte_size/1`, never
  `String.length/1`: the label says bytes and a character count would let a
  multi-byte compact past a limit expressed in bytes (a whole memory lesson of
  this repo's own). A compact over the bound is REFUSED with a NAMED code and
  nothing is written at all — the refusal happens in the controller, before
  `Tasks.Close` is called, so the row's `rev` is untouched.

  `priming_start` is machine-written and small, but it is still caller-supplied
  JSON on a write door, so it carries the same bound under its own code. Neither
  code is a generic `bad_request`: a caller that hits a size wall must be able to
  tell it from every other 4xx without reading prose.
  """

  @max_bytes 16 * 1024

  @doc "The byte bound both recorder fields are held to."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Validate a caller-supplied `priming_start` manifest.

  `nil` (the key was absent) is `{:ok, nil}` — UNMEASURED, store nothing. A map is
  accepted as-is: this door does not police the manifest's INTERNAL shape, because
  the schema version travels inside it (`"schema" => 1`) and a server that rejected
  an unknown schema would make the CLI unable to ship a newer one to an older box.
  """
  @spec validate_priming_start(term()) ::
          {:ok, nil} | {:ok, map()} | {:error, :priming_start_invalid | :priming_start_too_large}
  def validate_priming_start(nil), do: {:ok, nil}

  def validate_priming_start(value) when is_map(value) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= @max_bytes -> {:ok, value}
      {:ok, _} -> {:error, :priming_start_too_large}
      {:error, _} -> {:error, :priming_start_invalid}
    end
  end

  def validate_priming_start(_), do: {:error, :priming_start_invalid}

  @doc """
  Validate a caller-supplied `context_compact`.

  `nil` is `{:ok, nil}` — UNMEASURED. A blank or whitespace-only string is ALSO
  `{:ok, nil}`: an empty compact records nothing, and storing `""` would make the
  key present while saying less than its absence does. Anything that is not a
  string is refused rather than coerced.
  """
  @spec validate_context_compact(term()) ::
          {:ok, nil}
          | {:ok, binary()}
          | {:error, :context_compact_invalid | :context_compact_too_large}
  def validate_context_compact(nil), do: {:ok, nil}

  def validate_context_compact(value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> {:ok, nil}
      byte_size(value) > @max_bytes -> {:error, :context_compact_too_large}
      true -> {:ok, value}
    end
  end

  def validate_context_compact(_), do: {:error, :context_compact_invalid}

  @doc """
  Stamp the priming manifest onto a claim map — or leave it BYTE-IDENTICAL.

  The nil arm is the control the whole feature is measured against: a claim that
  carries no manifest must produce exactly the map it produced before this
  existed.
  """
  @spec put_priming_start(map(), map() | nil) :: map()
  def put_priming_start(claim, nil) when is_map(claim), do: claim

  def put_priming_start(claim, manifest) when is_map(claim) and is_map(manifest),
    do: Map.put(claim, "priming_start", manifest)

  @doc "Stamp the context compact onto a claim map — or leave it byte-identical."
  @spec put_context_compact(map(), binary() | nil) :: map()
  def put_context_compact(claim, nil) when is_map(claim), do: claim

  def put_context_compact(claim, compact) when is_map(claim) and is_binary(compact),
    do: Map.put(claim, "context_compact", compact)
end
