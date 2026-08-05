defmodule BarkparkCloud.Notifications.DeliveryReason do
  @moduledoc """
  The CLOSED VOCABULARY of notification-delivery failure classes — the seam
  where a raw transport error term becomes a label that is SAFE TO PUBLISH on
  a `Delivery` row.

  ## Why this exists (wave 31 S1)

  `record_delivery/5` used to store `inspect(why)` — the transport term, raw and
  unbounded — into `Delivery.last_error`, which `Web.Router.delivery_json/1`
  serves to every team admin and `app.js` renders VERBATIM. That term is not
  neutral. gen_smtp's `host_failure()` type
  (`deps/gen_smtp/src/gen_smtp_client.erl:138-144`) carries `smtp_host()` in
  EVERY arm and Swoosh passes it through unmodified
  (`{:error, type, message} -> {:error, {type, message}}`,
  `deps/swoosh/lib/swoosh/adapters/smtp.ex:62`), so one real failed send read
  back as

      {:retries_exceeded, {:network_failure, ~c"relay.example.invalid",
        {:error, :nxdomain}}}

  — publishing the SMTP relay host, which `Notifications.settings_view/1` masks
  to `"********"` for every reader INCLUDING the owner and which is Vault-sealed
  at rest with `redact: true`. The same shape reaches the chat path: `:httpc`
  `{:failed_connect, [{:to_address, {host, port}}, …]}` carries the target host
  and port.

  Bounded honestly: the SMTP USERNAME and PASSWORD never reached `last_error` —
  gen_smtp's `validate_options_error()` is the bare atoms `no_relay |
  invalid_port | no_credentials` and no error arm carries the options list. The
  leak was the HOST (and, on the chat path, the port), not the credentials.

  ## The boundary

  Modelled on `BarkparkCloud.FailureCopy` (`classify |> scrub` — class only,
  never the raw capture; already law at `notifications/render.ex:86` and
  `event_email.ex:97`), with one difference that matters: FailureCopy PASSES
  UNRECOGNIZED INPUT THROUGH, because its input is our own jargon. Here the
  input is attacker-adjacent transport data, so the fallback is `:unknown` and
  NOTHING from the term survives. `classify/1` is total; `label/1` emits a
  constant sentence; the only variable that ever escapes is the integer HTTP
  status of `{:http_status, code}`.

  The raw term still goes to `Logger` at the call sites — operator
  debuggability is not the thing we are taking away, PUBLICATION is.

  `classes/0` is the exported vocabulary of FAILURE — every one of its nine
  labels describes a send that was ATTEMPTED and did not arrive ("The destination
  refused the connection", "The destination did not respond in time").

  CORRECTION (wave 32 S2): an earlier draft of this doc claimed the suppressed /
  withheld reasons would name themselves from THIS list. They cannot — nothing
  here can honestly say "we never tried". `status: "suppressed"` rows draw on
  `Notifications.Withhold`'s own small vocabulary instead, and
  `Delivery.changeset/2` clamps `last_error` to the UNION of the two sets in one
  place, so the console still cannot grow a third, drifting set of words.
  """

  @classes [
    :dns_failure,
    :connection_refused,
    :tls_failure,
    :auth_rejected,
    :rate_limited,
    :recipient_rejected,
    :timeout,
    :http_status,
    :unknown
  ]

  @type class ::
          :dns_failure
          | :connection_refused
          | :tls_failure
          | :auth_rejected
          | :rate_limited
          | :recipient_rejected
          | :timeout
          | :http_status
          | :unknown

  @typedoc "A classified reason: a bare class, or `:http_status` carrying only its integer."
  @type classified :: class() | {:http_status, non_neg_integer()}

  @doc """
  The closed failure vocabulary, in reading order. Exported so adjacent
  surfaces name their reasons from the same set instead of inventing words.
  """
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc """
  Map any transport error term to one class of `classes/0`. Total: anything
  unrecognized is `:unknown`, and NOTHING of the input term is carried out
  except the integer status of `{:http_status, code}`.
  """
  @spec classify(term()) :: classified()
  def classify(term)

  # Unwrap the envelopes the send paths hand us.
  def classify({:error, reason}), do: classify(reason)

  # gen_smtp session errors: `{retries_exceeded | no_more_hosts | send, host_failure()}`
  # (Swoosh folds `{:error, type, message}` into `{type, message}`).
  def classify({stage, inner})
      when stage in [:retries_exceeded, :no_more_hosts, :send],
      do: classify(inner)

  # host_failure() / failure() — the host argument is EXACTLY what must not escape.
  def classify({:network_failure, _host, {:error, posix}}), do: posix_class(posix)
  def classify({:network_failure, {:error, posix}}), do: posix_class(posix)

  def classify({:permanent_failure, _host, reason}), do: smtp_permanent_class(reason)
  def classify({:permanent_failure, reason}), do: smtp_permanent_class(reason)

  def classify({:temporary_failure, _host, reason}), do: smtp_temporary_class(reason)
  def classify({:temporary_failure, reason}), do: smtp_temporary_class(reason)

  def classify({:missing_requirement, _host, requirement}),
    do: missing_requirement_class(requirement)

  def classify({:missing_requirement, requirement}), do: missing_requirement_class(requirement)

  def classify({:unexpected_response, _host, _lines}), do: :unknown
  def classify({:unexpected_response, _lines}), do: :unknown

  # gen_smtp validate_options_error() — bare atoms, no host, no credentials.
  def classify(:no_credentials), do: :auth_rejected
  def classify(:no_relay), do: :unknown
  def classify(:invalid_port), do: :unknown

  # HTTP outcomes on the chat path.
  def classify({:http_status, status}) when is_integer(status), do: {:http_status, status}
  def classify({:http_4xx, status}) when is_integer(status), do: {:http_status, status}

  # :httpc transport errors — `{:failed_connect, [{:to_address, {host, port}}, {:inet, _, posix}]}`.
  def classify({:failed_connect, info}) when is_list(info), do: failed_connect_class(info)

  # Bare posix / socket atoms (Finch, :gen_tcp, :ssl and friends).
  def classify(reason) when is_atom(reason), do: posix_class(reason)

  def classify(_other), do: :unknown

  @doc """
  The person-facing sentence for a classified reason. Every arm is a CONSTANT —
  the only value that ever interpolates is the integer HTTP status.
  """
  @spec label(classified()) :: String.t()
  def label({:http_status, status}) when is_integer(status),
    do: "The channel rejected the message (HTTP #{status})."

  def label(:dns_failure), do: "The destination host could not be resolved (DNS)."
  def label(:connection_refused), do: "The destination refused the connection."
  def label(:tls_failure), do: "The secure (TLS) handshake with the destination failed."
  def label(:auth_rejected), do: "The destination rejected our credentials."
  def label(:rate_limited), do: "The destination is rate-limiting us — try again later."
  def label(:recipient_rejected), do: "The destination rejected the recipient address."
  def label(:timeout), do: "The destination did not respond in time."
  def label(:http_status), do: "The channel rejected the message."
  def label(:unknown), do: "The delivery failed — the server log has the transport detail."

  @doc """
  `classify/1` then `label/1` — the one call a write site makes. `nil` in,
  `nil` out, so a success path can pipe through it unchanged.
  """
  @spec summarize(term()) :: String.t() | nil
  def summarize(nil), do: nil
  def summarize(term), do: term |> classify() |> label()

  ## ── Classification detail ────────────────────────────────────────────────

  defp posix_class(:nxdomain), do: :dns_failure
  defp posix_class(:eai_noname), do: :dns_failure
  defp posix_class(:eai_nodata), do: :dns_failure
  defp posix_class(:econnrefused), do: :connection_refused
  defp posix_class(:ehostunreach), do: :connection_refused
  defp posix_class(:enetunreach), do: :connection_refused
  defp posix_class(:timeout), do: :timeout
  defp posix_class(:etimedout), do: :timeout
  defp posix_class(_other), do: :unknown

  # A 5xx SMTP reply, or gen_smtp's own terminal atoms.
  defp smtp_permanent_class(:auth_failed), do: :auth_rejected
  defp smtp_permanent_class(:ssl_not_started), do: :tls_failure
  defp smtp_permanent_class(reply) when is_binary(reply), do: smtp_reply_class(reply)
  defp smtp_permanent_class(_other), do: :unknown

  # A 4xx SMTP reply, or gen_smtp's own transient atoms.
  defp smtp_temporary_class(:tls_failed), do: :tls_failure
  defp smtp_temporary_class(reply) when is_binary(reply), do: smtp_reply_class(reply)
  defp smtp_temporary_class(_other), do: :unknown

  defp missing_requirement_class(:tls), do: :tls_failure
  defp missing_requirement_class(:auth), do: :auth_rejected
  defp missing_requirement_class(_other), do: :unknown

  # An SMTP reply line classified on its REPLY CODE ONLY — the free text after
  # the code is server-controlled and never read, so nothing from it can escape.
  defp smtp_reply_class(reply) do
    case reply do
      <<code::binary-size(3), _rest::binary>> -> smtp_code_class(code)
      _short -> :unknown
    end
  end

  defp smtp_code_class(code) when code in ["421", "450", "451", "452"], do: :rate_limited

  defp smtp_code_class(code) when code in ["501", "550", "551", "553", "554"],
    do: :recipient_rejected

  defp smtp_code_class(code) when code in ["530", "534", "535", "538"], do: :auth_rejected
  defp smtp_code_class(_other), do: :unknown

  # `:httpc`'s failed_connect info list. Only the `{:inet, _, posix}` leg is
  # read; `{:to_address, {host, port}}` is deliberately ignored.
  defp failed_connect_class(info) do
    Enum.find_value(info, :unknown, fn
      {:inet, _opts, posix} when is_atom(posix) -> posix_class(posix)
      _other -> nil
    end)
  end
end
