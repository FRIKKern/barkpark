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

  ## Replay dedupe (wave-2 hardening, adversarial review of PR #6030)

  `unique: [period: 600]` over the FULL args. Key choice: the D59h payload
  carries no delivery id — its 5 fields `{session_id, title, workspace_id,
  blocked_since, ask_role}` plus the target `device_push_token_id` ARE the
  delivery's only identity, and `blocked_since` (the instance's block
  timestamp) is the field that separates a REPLAY of one event from a
  genuinely NEW blocking of the same session: a re-sent identical request has
  the identical `blocked_since`, a fresh block carries a fresh one. So
  identical-args-within-window is exactly "the same notification to the same
  device" and nothing more. Window choice: the receiver's HMAC verifier
  accepts |now − t| ≤ 300s, so a signature minted at `t` (possibly
  future-dated) stays acceptable up to 600s after the earliest moment it
  could first land — 600s covers the full replayable lifetime of one signed
  request. Uniqueness spans Oban's default states (completed included, within
  the period), so a replay arriving AFTER the original delivered still
  dedupes — and that `:completed` inclusion is correct ONLY BECAUSE
  `blocked_since` makes every genuine event's args distinct; if a future
  payload shape ever drops or trims that field, two DIFFERENT blocks can
  produce identical args and this ruling FLIPS (a genuinely new notification
  would be swallowed by an already-delivered one). The pin that holds it is
  `push_relay_receiver_test.exs`'s "a replay arriving AFTER the first job
  COMPLETED still enqueues ZERO new jobs" — the only test that reaches
  `:completed`. NOTE: enforcement relies on the fan-out using `Oban.insert/2`
  per job — OSS `Oban.insert_all/2` skips unique checks.

  ### Two known edges, RE-RECORDED as still accepted (wave-2 relay build)

  Both were raised on `mob-bl-relay-build-notes` and are deliberately still
  open, with the reason stated rather than quietly dropped:

    1. **Sub-second re-block collides.** A session that blocks, is answered, and
       re-blocks within the SAME second produces an identical `blocked_since`
       and therefore identical args — the second, genuinely-new notification
       dedupes away. Accepted: `blocked_since` comes from the box's
       `BlockedSweeper`, which fires on a `blocked_threshold_s` debounce of at
       least one second (the changeset's `greater_than: 0` on a second-grained
       column), so the window cannot be re-entered inside one second by the
       only producer that exists. Fixing it would mean widening the D59h
       payload with a delivery id — a bound ruling this build does not reopen.

    2. **600 s sits exactly on the max replayable lifetime.** A signature
       future-dated by the full +300 s tolerance first becomes acceptable at
       t−300 and stops at t+300, so the last possible replay lands 600 s after
       the earliest first landing — the boundary, not inside it. A replay
       arriving at exactly the 600 s edge could miss the window. Accepted:
       widening to, say, 900 s costs nothing but would trade a boundary case
       nobody can hit (it needs a clock-skewed sender AND a replay timed to the
       second) for a longer window in which a LEGITIMATE re-block dedupes —
       which is edge 1, made worse. The tighter window is the safer error.

  Verdicts (delegated to `Push.deliver/3`):

    * accepted (2xx)                       → `:ok`
    * row gone/revoked, token dead
      (unregistered/invalid — row revoked), or
      no APNs/FCM creds configured         → `{:cancel, reason}` — TERMINAL
    * transport error / 5xx                → `{:error, reason}` — retried on the
      backoff below, up to 4 attempts total
  """

  use Oban.Worker, queue: :default, max_attempts: 4, unique: [period: 600]

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
