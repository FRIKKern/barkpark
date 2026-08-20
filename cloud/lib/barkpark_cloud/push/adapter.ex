defmodule BarkparkCloud.Push.Adapter do
  @moduledoc """
  The swappable transport seam for one push-notification send — the push-relay
  spike's equivalent of `:webhook_http_adapter` on the box. Configured via

      config :barkpark_cloud, :push_adapter, <module>

  Defaults to `BarkparkCloud.Push.Adapters.NotConfigured` (honest terminal
  cancel — no APNs/FCM credentials are provisioned yet; see that module for the
  human-gate steps). Tests wire `BarkparkCloud.PushFakeAdapter`. The wave-2
  relay BUILD lands real APNs (token-based JWT) and FCM (HTTP v1) adapters
  behind this same callback, so the worker's retry classification never changes.

  ## Return contract (drives `Workers.PushDeliveryWorker`)

    * `{:ok, term}` — accepted by the platform (2xx). The worker stamps
      `last_used_at` and completes.
    * `{:error, :unregistered}` / `{:error, :invalid_token}` — the platform says
      this device token is dead (APNs 410 `Unregistered` / FCM
      `UNREGISTERED`/`INVALID_ARGUMENT`). TERMINAL: the worker revokes the row
      (self-healing — the delivery path IS the reaper for dead tokens) and
      cancels; no retry can fix a dead token.
    * `{:error, :not_configured}` — no credentials provisioned. TERMINAL cancel.
    * `{:error, term}` — transport error / 5xx. RETRIED on the worker's
      [1s, 5s, 30s] backoff, up to 4 attempts total.
  """

  alias BarkparkCloud.Push.DevicePushToken

  @doc """
  Deliver `notification` (the map built by `BarkparkCloud.Push.notification/1`)
  to the device addressed by `device_token`.
  """
  @callback send_push(DevicePushToken.t(), map()) ::
              {:ok, term()}
              | {:error, :unregistered | :invalid_token | :not_configured | term()}
end
