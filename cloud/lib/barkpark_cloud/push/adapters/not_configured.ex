defmodule BarkparkCloud.Push.Adapters.NotConfigured do
  @moduledoc """
  The default `BarkparkCloud.Push.Adapter`: no APNs/FCM credentials are
  provisioned in any environment yet (verified 2026-07-24 — zero APNs/FCM code
  or secrets anywhere in the tree), so every send terminates as an HONEST
  `{:error, :not_configured}` → the worker cancels terminally, never retries,
  never fakes a delivery.

  ## Human gate: provisioning real sandbox credentials (wave 2)

  APNs (iOS) — requires the Apple Developer account owner:

    1. developer.apple.com → Certificates, Identifiers & Profiles → Keys →
       create an APNs AUTH KEY (`.p8`); record Key ID + Team ID.
    2. Register the app's bundle id with the Push Notifications capability.
    3. Provide `APNS_KEY_P8` (contents), `APNS_KEY_ID`, `APNS_TEAM_ID`,
       `APNS_BUNDLE_ID` as cloud/ runtime env; sandbox host is
       `api.sandbox.push.apple.com`.

  FCM (Android) — requires the Firebase project owner:

    1. console.firebase.google.com → project settings → Service accounts →
       generate a service-account JSON key.
    2. Provide `FCM_SERVICE_ACCOUNT_JSON` as cloud/ runtime env; sends go to
       `https://fcm.googleapis.com/v1/projects/<project>/messages:send` with an
       OAuth2 bearer minted from the service account.

  Then implement the real adapter(s) behind `BarkparkCloud.Push.Adapter` and
  point `config :barkpark_cloud, :push_adapter` at them. The worker's retry
  classification is already final — adapters only translate platform verdicts
  into the behaviour's return contract.
  """

  @behaviour BarkparkCloud.Push.Adapter

  @impl true
  def send_push(_device_token, _notification), do: {:error, :not_configured}
end
