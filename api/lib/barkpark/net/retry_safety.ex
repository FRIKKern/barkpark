defmodule Barkpark.Net.RetrySafety do
  @moduledoc """
  Replay-safety predicate shared by the outbound HTTP clients that retry.

  ## The failure mode this exists to prevent

  A client that retries the WHOLE request on a transport `:timeout` is
  retrying the one condition under which it cannot know whether the remote
  processed the request. The bytes were written and accepted; only the
  response was lost. Re-sending a `POST` there does not recover a failed
  write — it performs a SECOND write.

  Concretely, before this module existed: `Bokbasen.Client.stage/2` (POST
  `/metadata/import/onix/v2`, 30 s default receive timeout, 3 attempts) would
  mint up to three ONIX submissions at Bokbasen for one document whenever
  Bokbasen was merely slow, and `Github.Client.create_issue/3` would mint up
  to three GitHub issues for one task. Both are the exact condition the retry
  was written for: remote slowness.

  The worker-level idempotency guards do NOT cover this. `PublishWorker`
  skips the stage step when a `submission_id` is already recorded, but the
  duplicate here happens INSIDE one `Client.stage/2` call — below the layer
  that guard reads — so no `submission_id` has been written yet and it cannot
  fire. Same for `MirrorJob`'s Oban-level dedup.

  ## The rule

  A retry may re-send a request only when replaying it cannot duplicate a
  side effect:

    * the method is idempotent by HTTP semantics (`GET`, `HEAD`, `OPTIONS`,
      `PUT`, `DELETE`) — a replay converges on the same state; or
    * the failure proves the request never reached the remote
      (`:econnrefused`, `:nxdomain`, `:ehostunreach`, `:enetunreach` — the
      connection was never established, so nothing was written); or
    * the call site asserts safety explicitly with `idempotent: true` (for a
      write the remote deduplicates itself, e.g. behind an idempotency key).

  `POST` and `PATCH` are non-idempotent and are therefore NOT replayed on an
  ambiguous failure. They still retry on the unambiguous ones: a 401 refresh,
  a 429 (rate-limited means not processed), and connect-stage refusals.

  ## Statuses

  A RECEIVED 5xx is a different case from a lost response: the endpoint we
  spoke to authored the error, which conventionally means it did not process
  the request. The exception is the gateway pair — `502 Bad Gateway` and
  `504 Gateway Timeout` — where an intermediary is reporting a failure that
  happened AFTER it forwarded the request upstream. Those are as ambiguous as
  a transport timeout and are gated the same way. `500`/`503` from the origin
  keep retrying for every method.
  """

  # Idempotent per RFC 9110 §9.2.2. PATCH is deliberately absent: it is
  # non-idempotent by spec even when a particular payload happens to converge.
  @idempotent_methods [:get, :head, :options, :put, :delete]

  # Transport failures raised BEFORE any request byte can have been written.
  @never_sent_reasons [:econnrefused, :nxdomain, :ehostunreach, :enetunreach]

  # 5xx statuses authored by an intermediary about an already-forwarded request.
  @ambiguous_gateway_statuses [502, 504]

  @doc """
  True when replaying a request with this method cannot duplicate a side
  effect. `opts[:idempotent]` overrides the method-based answer in either
  direction.
  """
  @spec replay_safe?(atom(), keyword()) :: boolean()
  def replay_safe?(method, opts \\ []) do
    case Keyword.get(opts, :idempotent) do
      true -> true
      false -> false
      _ -> method in @idempotent_methods
    end
  end

  @doc """
  True when a retry is safe after a transport-level failure with `reason`.

  Safe when the method is replayable, or when the reason proves the request
  never left the client.
  """
  @spec retry_after_transport_error?(atom(), any(), keyword()) :: boolean()
  def retry_after_transport_error?(method, reason, opts \\ []) do
    reason in @never_sent_reasons or replay_safe?(method, opts)
  end

  @doc """
  True when a retry is safe after receiving `status` (a 5xx).

  Safe for every method except on the ambiguous gateway statuses, where the
  method must be replayable.
  """
  @spec retry_after_status?(atom(), integer(), keyword()) :: boolean()
  def retry_after_status?(method, status, opts \\ []) do
    not ambiguous_gateway_status?(status) or replay_safe?(method, opts)
  end

  @doc "True for the 5xx statuses an intermediary authors about a forwarded request."
  @spec ambiguous_gateway_status?(integer()) :: boolean()
  def ambiguous_gateway_status?(status), do: status in @ambiguous_gateway_statuses
end
