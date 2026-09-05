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

  `classes/0` is the exported vocabulary of FAILURE — every one of its labels
  describes a send this system ATTEMPTED and that did not arrive. `classes/0`
  carries exactly the CONSTANT sentences; the one parameterized family,
  `{:http_status, code}`, is not a member of it, because a list of classes is
  mapped through `label/1` by `Delivery`, by the backfill migration and by the
  tests, and a bare `:http_status` sentence is one `classify/1` can never emit.

  ## A label may only name what the code OBSERVED (wave 35 S3, charter D402)

  The doc above used to promise nine labels; four arms broke the promise by
  naming a MECHANISM nothing observed, which is the same defect this epic ruled
  on one module over in `FailureCopy` (charter D321(3): "refused" and "no route"
  are different remedies and must not be fused):

    * `:no_credentials` is gen_smtp OPTION validation — no socket is ever opened
      — yet it read "The destination rejected our credentials";
    * `{:missing_requirement, :tls}` is thrown AFTER `quit(Socket)` because the
      server never ADVERTISED STARTTLS, yet it read "the TLS handshake failed";
      `:auth` is the same shape;
    * `ehostunreach` / `enetunreach` mean NOBODY ANSWERED, yet they read "The
      destination refused the connection";
    * SMTP 451 (local error in processing) and 452 (insufficient storage) are
      the destination's own trouble, yet they read as rate-limiting.

  Five classes were ADDED for those arms rather than existing sentences being
  reworded: the already-applied backfill (`20260805210000`) and every historical
  row key off the existing constants, so their TEXT is frozen. `:econnrefused`
  (the peer answered and said no) and SMTP 421 (a genuine throttle) are unmoved.

  ## The three arms wave 35 left behind (cch-w35-followup)

  The same shape, one setting and one layer over:

    * `:no_relay` and `:invalid_port` are the other two members of gen_smtp's
      `validate_options_error()` — the sibling atoms of `:no_credentials`, which
      wave 35 gave `:not_configured`. Both fell to `:unknown`, whose sentence
      sends a reader to a server log for a fault the CONSOLE can fix, and
      `:not_configured`'s sentence names the credentials, which is the wrong
      missing setting for both. They get `:relay_not_configured` and
      `:relay_port_invalid` — one class per missing setting, so the sentence
      names what to go and set.
    * `:ehostdown` / `:enetdown` are nobody-answered like `ehostunreach` /
      `enetunreach`, but the observation is a `down` report rather than a
      missing route, and `:unreachable`'s FROZEN sentence names a route. They get
      `:network_down`.
    * `:eacces` is ruled out and stays `:unknown` — see `posix_class/1`.

  Three classes ADDED, zero sentences reworded, for the same reason as wave 35:
  the backfill and every historical row key off the existing bytes.

  THE FIX IS FORWARD-ONLY. Rows already stamped with one of the wrong sentences
  keep it and cannot be repaired: `last_error` stores the classified sentence
  only, the raw transport term is gone, and nothing left on the row can say which
  arm produced it.

  No label promises a RETRY. There is no retry mechanism — `Delivery`'s
  `attempts` / `last_error` shape is the FUTURE seam for one — so a sentence that
  asserted one would be a fresh instance of the defect above.
  `:rate_limited`'s "try again later" is advice to a person, not a claim about
  this system, and survives.

  CORRECTION (wave 32 S2): an earlier draft of this doc claimed the suppressed /
  withheld reasons would name themselves from THIS list. They cannot — nothing
  here can honestly say "we never tried". `status: "suppressed"` rows draw on
  `Notifications.Withhold`'s own small vocabulary instead, and
  `Delivery.changeset/2` clamps `last_error` to the UNION of the two sets in one
  place, so the console still cannot grow a third, drifting set of words. The
  boundary survives wave 35: `:not_configured` reports a send this system TRIED
  to make and that the transport refused to start, which is a `failed` row; a
  withhold is a decision made FOR the user not to send at all, which is a
  `suppressed` one.
  """

  @classes [
    :dns_failure,
    :unreachable,
    :connection_refused,
    :tls_failure,
    :tls_not_offered,
    :auth_rejected,
    :auth_not_offered,
    :not_configured,
    :relay_not_configured,
    :relay_port_invalid,
    :network_down,
    :rate_limited,
    :destination_temporary_error,
    :recipient_rejected,
    :timeout,
    :unknown
  ]

  @type class ::
          :dns_failure
          | :unreachable
          | :connection_refused
          | :tls_failure
          | :tls_not_offered
          | :auth_rejected
          | :auth_not_offered
          | :not_configured
          | :relay_not_configured
          | :relay_port_invalid
          | :network_down
          | :rate_limited
          | :destination_temporary_error
          | :recipient_rejected
          | :timeout
          | :unknown

  @typedoc "A classified reason: a bare class, or `:http_status` carrying only its integer."
  @type classified :: class() | {:http_status, non_neg_integer()}

  @doc """
  The closed failure vocabulary, in reading order — every class whose label is a
  CONSTANT sentence. Exported so adjacent surfaces name their reasons from the
  same set instead of inventing words, and so the clamp in `Delivery.changeset/2`
  and the backfill migration DERIVE their allowlists from here.

  A class listed here MUST have a `label/1` arm and a `label/1` arm MUST have a
  class here: an orphan sentence is one the clamp then rejects, invalidating
  every `Delivery` insert that carries it.
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
  # `:no_credentials` is raised by OPTION VALIDATION (`auth: always` with no
  # username/password): no socket is ever opened, so no destination rejected
  # anything. It is a local configuration fault, not a remote verdict.
  # Its two SIBLINGS are the same shape one setting over: `validate_options`
  # raises `:no_relay` when the relay host is blank and `:invalid_port` when the
  # port is not a valid one. Neither opens a socket either, and neither is about
  # a username or a password — so `:not_configured`'s sentence (which names the
  # credentials) is the WRONG missing setting for both, and `:unknown` (which
  # sends the reader to a server log for a fault the console itself can fix) is
  # no better. Each gets a class that names ITS OWN missing configuration.
  def classify(:no_credentials), do: :not_configured
  def classify(:no_relay), do: :relay_not_configured
  def classify(:invalid_port), do: :relay_port_invalid

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

  # FROZEN TEXT. The applied backfill (20260805210000) and every historical row
  # key off these exact sentences, so an arm below is never reworded — a wrong
  # class grows a NEW class instead (wave 35 S3).
  def label(:dns_failure), do: "The destination host could not be resolved (DNS)."
  def label(:connection_refused), do: "The destination refused the connection."
  def label(:tls_failure), do: "The secure (TLS) handshake with the destination failed."
  def label(:auth_rejected), do: "The destination rejected our credentials."
  def label(:rate_limited), do: "The destination is rate-limiting us — try again later."
  def label(:recipient_rejected), do: "The destination rejected the recipient address."
  def label(:timeout), do: "The destination did not respond in time."
  def label(:unknown), do: "The delivery failed — the server log has the transport detail."

  # ADDED wave 35 S3 — each names only what the code observed, and none of them
  # asserts a retry this system does not perform.
  def label(:unreachable),
    do: "The destination could not be reached — no route from our network to it."

  def label(:tls_not_offered),
    do: "The destination did not offer the secure (TLS) connection our settings require."

  def label(:auth_not_offered),
    do: "The destination did not offer a sign-in method our settings require."

  def label(:not_configured),
    do: "The mail relay has no username or password configured, so the send never started."

  def label(:destination_temporary_error),
    do: "The destination reported a temporary problem of its own and did not accept the message."

  # ADDED cch-w35-followup — the two remaining `validate_options_error()` atoms
  # and the two network-layer `down` reports. Each names what was observed and
  # nothing else; no existing sentence above is reworded.
  def label(:relay_not_configured),
    do: "No mail relay host is configured, so the send never started."

  def label(:relay_port_invalid),
    do: "The mail relay port is not a valid port number, so the send never started."

  def label(:network_down),
    do:
      "The connection could not be made — the network reported the destination " <>
        "or the network itself as down."

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
  # `:econnrefused` is the peer ANSWERING and saying no; `ehostunreach` /
  # `enetunreach` is the routing layer reporting that nobody answered at all.
  # Fusing them hands the reader the one remedy that cannot work (charter
  # D321(3), already law in `FailureCopy`).
  defp posix_class(:econnrefused), do: :connection_refused
  defp posix_class(:ehostunreach), do: :unreachable
  defp posix_class(:enetunreach), do: :unreachable
  # `ehostdown` / `enetdown` are ALSO nobody-answered, but they are not the same
  # observation as `*unreachable`: those two are the routing layer saying it has
  # no path, these two are a `down` report about the destination host or about
  # the network itself. `:unreachable`'s frozen sentence names a ROUTE ("no route
  # from our network to it"), which is a mechanism neither of these observed, so
  # folding them in would be a fresh instance of the defect wave 35 S3 corrected.
  defp posix_class(:ehostdown), do: :network_down
  defp posix_class(:enetdown), do: :network_down
  defp posix_class(:timeout), do: :timeout
  defp posix_class(:etimedout), do: :timeout
  # RULED OUT, NOT OVERLOOKED (cch-w35-followup): `:eacces` is OUR OWN host
  # refusing the socket — a local sandbox/firewall policy, or a bind the process
  # is not privileged to make. It says nothing about the destination and names no
  # setting the console can show, so every sentence in this vocabulary would be a
  # claim nothing observed. `:unknown` — which points the operator at the server
  # log, where the raw term still is — is the accurate answer, and
  # `delivery_reason_test.exs` pins it so this stays a decision rather than a gap.
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

  # A `:missing_requirement` is thrown AFTER the session is quit, because the
  # server never ADVERTISED the capability we require — no handshake was
  # attempted and no credential was offered, so neither can have been rejected.
  # The genuine handshake failure arrives as `{:temporary_failure, :tls_failed}`
  # above and keeps `:tls_failure`.
  defp missing_requirement_class(:tls), do: :tls_not_offered
  defp missing_requirement_class(:auth), do: :auth_not_offered
  defp missing_requirement_class(_other), do: :unknown

  # An SMTP reply line classified on its REPLY CODE ONLY — the free text after
  # the code is server-controlled and never read, so nothing from it can escape.
  defp smtp_reply_class(reply) do
    case reply do
      <<code::binary-size(3), _rest::binary>> -> smtp_code_class(code)
      _short -> :unknown
    end
  end

  # 421 IS a throttle ("too many connections", "service not available"). 450
  # (mailbox unavailable), 451 (local error in processing) and 452 (insufficient
  # system storage) are the destination's OWN trouble and say nothing about our
  # rate.
  defp smtp_code_class("421"), do: :rate_limited

  defp smtp_code_class(code) when code in ["450", "451", "452"],
    do: :destination_temporary_error

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
