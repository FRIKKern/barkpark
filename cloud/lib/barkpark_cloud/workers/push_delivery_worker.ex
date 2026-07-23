defmodule BarkparkCloud.Workers.PushDeliveryWorker do
  @moduledoc """
  Push-relay spike (mobile charter D15d): delivers ONE push notification to ONE
  registered device, off the webhook-receiver's request path, with native Oban
  retry/backoff — deliberately on `ChatNotificationWorker`'s exact contract
  (queue `:default`, `max_attempts: 4`, fixed `[1s, 5s, 30s]` backoff) so the
  wave-2 relay BUILD inherits a proven shape.

  Enqueued (one job per device row) by `Push.enqueue_chat_blocked_fanout/2`.
  Args are JSON-safe and tiny: the device row's id + the D59h 5-field payload —
  never the device token itself (the worker reloads the row, so a token revoked
  between enqueue and perform is honored) and never message content.

  Verdicts (delegated to `Push.deliver/3`):

    * accepted (2xx)                       → `:ok`
    * row gone/revoked, token dead
      (unregistered/invalid — row revoked), or
      no APNs/FCM creds configured         → `{:cancel, reason}` — TERMINAL
    * transport error / 5xx                → `{:error, reason}` — retried on the
      backoff below, up to 4 attempts total
  """

  use Oban.Worker, queue: :default, max_attempts: 4

  alias BarkparkCloud.Push

  # The fixed backoff ported from api/'s webhook dispatcher via
  # ChatNotificationWorker: 1s, 5s, 30s between the (up to) three retries.
  @backoff_seconds [1, 5, 30]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "device_push_token_id" => device_push_token_id,
          "event" => event,
          "payload" => payload
        }
      }) do
    Push.deliver(device_push_token_id, event, payload)
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    Enum.at(@backoff_seconds, attempt - 1, List.last(@backoff_seconds))
  end
end
