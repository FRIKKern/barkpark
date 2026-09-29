defmodule BarkparkCloud.AgentCommandResults do
  @moduledoc """
  The read half of `POST /v1/agent/results` — it turns the on-box agent's
  `[]CommandResult` into a COUNT, so a command that was rejected, timed out or
  exited non-zero is visible to a human instead of being swallowed by a 200.

  ## Why this module exists

  Before dr-w19-bl the route was `Auth.require_agent/2` and then
  `json(conn, 200, %{ok: true})` — the body was never read. The Go side is
  faithful: `internal/agent/commands.go` writes `Approved: false` plus a
  `rejected: …` reason for an allowlisted-name miss, and `runBounded` in
  `internal/agent/report.go` converts a blown `execRunnerTimeout` into
  `"timed out after 5m0s: make -C /opt/barkpark deploy"`. Every one of those
  reached the control plane and was discarded. A 200 OK over a discarded
  failure report is the thing this module removes.

  ## The three failure shapes, and how each is told apart

  The wire type has no outcome field, so the classification reads the two
  fields the agent DOES fill (`commands.go`, `CommandResult`):

    * `:rejected`  — `approved == false`. A real BOOLEAN field, not a string
      match: `runCommand/2` sets it on the allowlist miss and only there.
    * `:timed_out` — `approved == true` and `error` starts with
      `"timed out after "`. This one IS a string match, and that is a wire
      coupling worth naming rather than hiding: `runBounded` builds the message
      as `"%w after %s: %s %s"` over the `errProbeTimedOut` sentinel
      (`"timed out"`), and Go's `exec` has no distinct exit code for a
      context kill. If that prose ever changes, a timeout degrades to
      `:failed` — a WEAKER label, never a silent success.
    * `:failed`    — `approved == true` and a non-empty `error` that is not a
      timeout (an `exec.ExitError`, i.e. `"exit status 1"`).
    * `:ok`        — approved, no error.
    * `:malformed` — the entry was not a map, i.e. the body did not carry
      `[]CommandResult` at all. Counted rather than dropped: a shape the
      control plane cannot read is itself a failure to report, and a silent
      zero would look exactly like a healthy cycle.

  ## What "countable" means here

  Two counters, deliberately cheap — no table, no migration, no
  `agent_events` type. `Registry.record_event/3`'s allowlist is a declared
  capability pinned in both directions by `agent_event_test.exs`; growing it
  for a rail with no console reader would trade one unread word for another.

    * a `Logger.warning` per non-ok result, carrying the barkpark id, the
      command id/name and the agent's own error text, plus one summary line
      per POST. Greppable in `journalctl`, assertable in a test with
      `ExUnit.CaptureLog`.
    * `:telemetry.execute([:barkpark_cloud, :agent, :command_result], counts,
      %{barkpark_id: …})` — the same idiom `Sites.Deploy` and
      `Github.CommitDistanceSweep` use, so a metrics backend can sum the
      buckets without parsing prose. `telemetry_event/0` returns the list so a
      handler attaches without repeating the literal.

  Both fire on EVERY post, including an all-ok one — a counter that only
  exists when something broke cannot distinguish "nothing broke" from "the
  reporting broke".

  ## The rail above this is still inert — see `Web.Router.command_queue/0`

  `GET /v1/agent/commands` serves `command_queue/0`, which reads a config key
  no `cloud/config` file sets and no `cloud/lib` module writes. With no
  producer the agent's `len(cmds) == 0` fast-path always wins and this module
  counts nothing in production TODAY. That is the point of landing it anyway:
  the day a queue producer exists, its failures are already countable, and
  until then the absence is written down where a reader will meet it rather
  than inferred from a green 200.
  """

  require Logger

  @telemetry_event [:barkpark_cloud, :agent, :command_result]

  @buckets [:ok, :failed, :timed_out, :rejected, :malformed]

  @timeout_prefix "timed out after "

  @typedoc "One bucket per distinguishable outcome of a single command attempt."
  @type outcome :: :ok | :failed | :timed_out | :rejected | :malformed

  @doc "The bucket names, in report order. The vocabulary, for tests and readers."
  @spec buckets() :: [outcome()]
  def buckets, do: @buckets

  @doc "The telemetry event this module emits, exposed so a handler can attach without a literal."
  @spec telemetry_event() :: [atom()]
  def telemetry_event, do: @telemetry_event

  @doc """
  Count one `POST /v1/agent/results` body and report it.

  `body` is `conn.body_params`: `Plug.Parsers` wraps a top-level JSON ARRAY as
  `%{"_json" => [...]}`, so both that and a bare list are accepted (and so is a
  single object, which is what a hand-rolled client tends to send). Anything
  else counts as one `:malformed` entry rather than raising — this runs on an
  ingest path, and a body the control plane cannot parse must still be
  reported, never turned into a 500 for the box that told the truth.

  Returns the counts map so the caller can assert on it; the caller ignores it
  today (the route still answers `200 {ok: true}` — the agent has no retry
  behaviour to drive off a different status, and inventing one would change the
  Go contract from the server side).
  """
  @spec record(term(), term()) :: %{outcome() => non_neg_integer()}
  def record(barkpark, body) do
    entries = entries(body)
    counts = tally(entries)
    barkpark_id = barkpark_id(barkpark)

    Enum.each(entries, fn entry ->
      case classify(entry) do
        {:ok, _detail} ->
          :ok

        {outcome, detail} ->
          Logger.warning(
            "agent command #{outcome}: barkpark=#{barkpark_id} " <>
              "id=#{inspect(detail.id)} name=#{inspect(detail.name)} error=#{inspect(detail.error)}"
          )
      end
    end)

    Logger.info(
      "agent command results: barkpark=#{barkpark_id} " <>
        Enum.map_join(@buckets, " ", fn b -> "#{b}=#{counts[b]}" end)
    )

    :telemetry.execute(@telemetry_event, counts, %{barkpark_id: barkpark_id})

    counts
  end

  @doc """
  Bucket one decoded `CommandResult`, returning `{outcome, detail}` where
  `detail` carries the id/name/error a log line quotes. Public because the
  classification IS the contract with `internal/agent`, and a test that pins it
  should not have to go through a full HTTP round-trip.
  """
  @spec classify(term()) :: {outcome(), %{id: term(), name: term(), error: term()}}
  def classify(entry) when is_map(entry) do
    approved = get(entry, "approved")
    error = get(entry, "error")
    detail = %{id: get(entry, "id"), name: get(entry, "name"), error: error}

    outcome =
      cond do
        approved == false -> :rejected
        is_binary(error) and String.starts_with?(error, @timeout_prefix) -> :timed_out
        is_binary(error) and error != "" -> :failed
        true -> :ok
      end

    {outcome, detail}
  end

  # The malformed arm names the SHAPE, never the payload. `error: inspect(entry)`
  # here would both trip the D95 source tripwire in
  # `router_transport_redaction_test.exs` and be the thing that tripwire is
  # about: an unparseable body is exactly the body most likely to carry
  # something nobody vetted, and a count plus a type name is all a reader needs
  # to know the agent sent something this control plane cannot read.
  def classify(entry),
    do: {:malformed, %{id: nil, name: nil, error: "unreadable result entry (#{shape(entry)})"}}

  # ── internals ──

  # Plug.Parsers wraps a top-level JSON array under "_json"; a bare list and a
  # lone object are both accepted so this never depends on parser trivia.
  defp entries(%{"_json" => list}) when is_list(list), do: list
  defp entries(list) when is_list(list), do: list
  # An EMPTY parsed body is no results at all (the agent never posts one), not
  # one malformed result — it must tally to all-zero so the summary line and the
  # telemetry counts stay honest about "nothing arrived".
  defp entries(map) when map == %{}, do: []
  defp entries(%{} = map), do: [map]
  defp entries(other), do: [other]

  defp tally(entries) do
    zero = Map.new(@buckets, &{&1, 0})

    Enum.reduce(entries, zero, fn entry, acc ->
      {outcome, _detail} = classify(entry)
      Map.update!(acc, outcome, &(&1 + 1))
    end)
  end

  # The wire is string-keyed (Plug's JSON parser), but `classify/1` is public and
  # a caller holding an already-built struct-ish map should not have to
  # stringify it first, so both key shapes read.
  defp get(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, atom_key(key))
    end
  end

  defp atom_key("id"), do: :id
  defp atom_key("name"), do: :name
  defp atom_key("approved"), do: :approved
  defp atom_key("error"), do: :error

  defp shape(entry) when is_binary(entry), do: "string"
  defp shape(entry) when is_number(entry), do: "number"
  defp shape(entry) when is_boolean(entry), do: "boolean"
  defp shape(entry) when is_nil(entry), do: "null"
  defp shape(entry) when is_list(entry), do: "list"
  defp shape(_entry), do: "unknown"

  defp barkpark_id(%{id: id}), do: id
  defp barkpark_id(other), do: inspect(other)
end
