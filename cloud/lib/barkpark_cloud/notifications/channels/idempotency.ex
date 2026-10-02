defmodule BarkparkCloud.Notifications.Channels.Idempotency do
  @moduledoc """
  The ONE delivery id, and the headers that carry it.

  ## Why it exists

  `ChatNotificationWorker` is `max_attempts: 4` with a fixed `[1s, 5s, 30s]`
  backoff, and the retry is driven by the TRANSPORT outcome, not by whether the
  receiver got the message. A 5xx, or a response that never arrived, re-drives a
  POST that the receiver may already have processed. That is deliberate
  at-least-once — it matches api/'s webhook dispatcher port and is NOT a defect.
  But at-least-once is only usable by a receiver that can recognise the repeat,
  and until now nothing on the wire let it: the only per-send value in any
  envelope was `Channels.Webhook`'s `DateTime.utc_now()`, which is minted INSIDE
  `shape/4` and is therefore DIFFERENT on every attempt. A per-attempt value
  dedupes nothing; it is the exact opposite of what a dedupe key must be.

  ## Where it is minted — and where it must NOT be

  At ENQUEUE, in `Notifications.enqueue_channel/4`, and stored in the Oban job's
  args. Oban retries re-run the SAME job row with the SAME args, so all four
  attempts of one notification carry one id. Minting it in the worker, in
  `deliver_chat/5`, or in a shaper would put it back on the attempt and restore
  the defect under a new name.

  ## What each channel can actually DO with it

  Only `webhook` posts to an OPERATOR-SUPPLIED endpoint, so only `webhook` has a
  receiver that can be made to dedupe. It gets the id BOTH as a body field
  (`delivery_id`) and in the headers. The other four post to a PROVIDER whose
  request schema we do not own — Slack/Discord incoming webhooks, the Telegram
  Bot API, the Pushover messages endpoint. None of them dedupes on a custom key,
  and an unrecognised top-level body field is at best ignored and at worst a
  400, so the id must NOT go in their bodies. It goes in their HEADERS, which
  every one of them ignores harmlessly — where it is still readable by an
  operator's proxy, gateway or capture, and by our own request log. Stated
  plainly: for discord/slack/telegram/pushover this id is OBSERVABILITY, not
  dedupe. Claiming otherwise would be the stronger-sounding claim on the weaker
  measurement that `Delivery`'s moduledoc exists to refuse.

  ## Both headers, on purpose

  `Idempotency-Key` is the name receivers and API gateways already recognise;
  `X-Barkpark-Delivery-Id` is unambiguous in a log that carries other vendors'
  idempotency keys. A receiver behind a proxy that strips one may still see the
  other. They always carry the SAME value.
  """

  @key_header "idempotency-key"
  @vendor_header "x-barkpark-delivery-id"

  @doc "A fresh delivery id. Call this ONCE per notification, at enqueue time."
  @spec mint() :: String.t()
  def mint, do: Ecto.UUID.generate()

  @doc "The header names this module writes, lowercase."
  @spec headers_names() :: [String.t()]
  def headers_names, do: [@key_header, @vendor_header]

  @doc """
  Append the id headers to `headers`. A nil id (a job enqueued before this
  existed, still retrying) appends NOTHING rather than a blank or a fresh value —
  an empty key is worse than an absent one, and a fresh one would be per-attempt.
  """
  @spec put_headers([{String.t(), String.t()}], String.t() | nil) ::
          [{String.t(), String.t()}]
  def put_headers(headers, id) when is_binary(id) and id != "" do
    headers ++ [{@key_header, id}, {@vendor_header, id}]
  end

  def put_headers(headers, _id), do: headers

  @doc "Read the delivery id out of a shaper's `opts`."
  @spec from_opts(keyword()) :: String.t() | nil
  def from_opts(opts), do: Keyword.get(opts, :delivery_id)
end
