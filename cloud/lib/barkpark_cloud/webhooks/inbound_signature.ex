defmodule BarkparkCloud.Webhooks.InboundSignature do
  @moduledoc """
  The ONE verifier for every INBOUND instance-signed webhook Cloud receives.

  Born as `Sites.ContentPublishVerifier` (site-spawner W5, charter D46) for a
  single receiver; PROMOTED here in the wave-2 push-relay build because it now
  serves two, and a `Sites.*` name on the push relay's auth was a decoy waiting
  to be copy-pasted into a third:

    * `POST /v1/sites/webhooks/content-publish/:site_id` — a document publish on
      a site's bound dataset (verified against the SITE's stored secret).
    * `POST /v1/relay/chat-blocked/:barkpark_id` — the mobile push relay's
      chat_blocked delivery (verified against the BARKPARK's stored relay
      secret, mobile charter D15b).

  Both are signed by the SAME box-side signer, so they share one verifier by
  construction, not by coincidence: `Barkpark.Webhooks.Dispatcher` signs every
  delivery with `x-barkpark-signature: t=<unix>,v1=<hex>`, where the hex is
  `HMAC-SHA256(secret, "<timestamp>.<raw-body>")`, lowercase, with a ±300s replay
  window. This module is a byte-for-byte PORT of `StripeGateway.check_signatures`
  (same `"t.payload"` material, same lower-hex `t=`/`v1=` grammar, same 300s
  tolerance, same constant-time compare) — deliberately NOT the GitHub verifier,
  whose scheme is `sha256=<hex>` over the raw body with NO timestamp, which would
  reject every valid delivery here (or, if adapted, open a replay hole).

  `secrets` is a LIST so a rotated secret still verifies during the overlap window
  — the header is valid iff `expected` constant-time-equals ANY offered `v1` for
  ANY offered secret. cloud/ and api/ are separate mix apps, so we cannot call
  api's `Dispatcher.verify_signature/5`; this is the self-contained CP-side twin.

  Every malformed input returns `{:error, reason}` rather than raising — the
  webhook route stays a clean 401.

  NOTE the tolerance here is only HALF of replay defence: it bounds how long a
  captured signature stays acceptable. Dedupe of a replay INSIDE that window is
  the receiver's job (`Workers.PushDeliveryWorker`'s `unique: [period: 600]`
  covers the push relay; the content-publish receiver is idempotent by
  debounce).
  """

  # Replay-protection window (seconds): reject a delivery whose signed `t=<unix>`
  # is more than this far from now in either direction. 300s matches the box's
  # Dispatcher tolerance and Stripe's documented default.
  @tolerance_seconds 300

  @doc """
  Verify a raw request `body` against the `x-barkpark-signature` header value using
  any of `secrets`. Returns `:ok` on a fresh, matching signature, or
  `{:error, reason}` (`:missing_signature` | `:malformed_header` |
  `:timestamp_out_of_tolerance` | `:invalid_signature`) otherwise.
  """
  @spec verify(binary(), binary() | nil, [binary()]) ::
          :ok
          | {:error,
             :missing_signature
             | :malformed_header
             | :timestamp_out_of_tolerance
             | :invalid_signature}
  def verify(body, signature_header, secrets)
      when is_binary(body) and is_binary(signature_header) and is_list(secrets) do
    with {:ok, timestamp, v1_signatures} <- parse_signature_header(signature_header),
         :ok <- check_timestamp(timestamp),
         :ok <- check_signatures(body, timestamp, v1_signatures, secrets) do
      :ok
    end
  end

  def verify(_body, _signature_header, _secrets), do: {:error, :missing_signature}

  # Parse "t=123,v1=abc,v1=def" into {:ok, 123, ["abc", "def"]}. A missing/
  # non-integer timestamp or a complete absence of v1 values is a malformed header.
  # Unknown schemes are ignored.
  defp parse_signature_header(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.flat_map(fn item ->
        case String.split(String.trim(item), "=", parts: 2) do
          [k, v] -> [{k, v}]
          _ -> []
        end
      end)

    timestamp =
      case List.keyfind(pairs, "t", 0) do
        {"t", value} -> parse_integer(value)
        _ -> :error
      end

    v1_signatures = for {"v1", v} <- pairs, do: v

    case {timestamp, v1_signatures} do
      {:error, _} -> {:error, :malformed_header}
      {_t, []} -> {:error, :malformed_header}
      {t, sigs} -> {:ok, t, sigs}
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> :error
    end
  end

  # Replay protection: the delivery's timestamp must be within the tolerance window
  # of now, in either direction. Wall-clock seconds.
  defp check_timestamp(timestamp) do
    now = System.system_time(:second)

    if abs(now - timestamp) <= @tolerance_seconds do
      :ok
    else
      {:error, :timestamp_out_of_tolerance}
    end
  end

  # Recompute the expected HMAC over "<t>.<body>" for EACH offered secret and
  # constant-time-compare against every offered v1 value. Valid iff any pair
  # matches. Never `==` on the hex.
  defp check_signatures(body, timestamp, v1_signatures, secrets) do
    signed_payload = "#{timestamp}.#{body}"

    match? =
      Enum.any?(secrets, fn secret ->
        expected =
          :crypto.mac(:hmac, :sha256, secret, signed_payload) |> Base.encode16(case: :lower)

        Enum.any?(v1_signatures, &secure_compare(&1, expected))
      end)

    if match?, do: :ok, else: {:error, :invalid_signature}
  end

  # Constant-time comparison — inlined to avoid pulling in Plug.Crypto for one
  # call. Equal length AND every byte equal, in time independent of where the
  # first mismatch is (no early return on the byte loop).
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and constant_time_equal?(a, b, 0)
  end

  defp secure_compare(_a, _b), do: false

  defp constant_time_equal?(<<x, rest_a::binary>>, <<y, rest_b::binary>>, acc) do
    constant_time_equal?(rest_a, rest_b, Bitwise.bor(acc, Bitwise.bxor(x, y)))
  end

  defp constant_time_equal?(<<>>, <<>>, acc), do: acc === 0
end
