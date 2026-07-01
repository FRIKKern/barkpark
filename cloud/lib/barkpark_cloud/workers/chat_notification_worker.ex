defmodule BarkparkCloud.Workers.ChatNotificationWorker do
  @moduledoc """
  notifications-chat: delivers ONE chat notification to ONE channel, off the
  request path, with native Oban retry/backoff — the Oban replacement for the
  swarm candidate's `Task.Supervisor` + inline `Process.sleep` retry loop.

  Enqueued by `BarkparkCloud.Notifications.dispatch_event/3` (folded in next to
  the email fan-out) and by the "send test" endpoint. Args are JSON-safe and
  carry NO plaintext credentials — the worker reloads the team's channel by type
  and decrypts its sealed creds in-process, for the duration of one delivery.

  Retry semantics (delegated to `Notifications.deliver_chat/4`):

    * 2xx           → `:ok`               (delivered; logged)
    * 4xx / bad creds / SSRF / gone → `{:cancel, reason}` — TERMINAL, no retry
      (a revoked token or bad URL won't fix itself).
    * 5xx / transport error → `{:error, reason}` — Oban re-drives with the fixed
      `[1s, 5s, 30s]` backoff below, up to `@max_attempts` total.
  """

  use Oban.Worker, queue: :default, max_attempts: 4

  alias BarkparkCloud.Notifications

  # The fixed backoff ported from api/'s webhook dispatcher: 1s, 5s, 30s between
  # the (up to) three retries. attempt is 1-based; attempt 1 has already run when
  # backoff is consulted for the next try.
  @backoff_seconds [1, 5, 30]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "team_id" => team_id,
          "channel_type" => type,
          "event" => event,
          "payload" => payload
        }
      }) do
    Notifications.deliver_chat(team_id, type, event, payload)
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    Enum.at(@backoff_seconds, attempt - 1, List.last(@backoff_seconds))
  end
end
