defmodule BarkparkCloud.Push.Adapters.NotConfigured do
  @moduledoc """
  The fallback `BarkparkCloud.Push.Adapter`, selected whenever a platform's
  credentials are absent: every send terminates as an HONEST
  `{:error, :not_configured}` → the worker cancels terminally, never retries,
  never fakes a delivery.

  As of the wave-2 relay BUILD the real adapters EXIST
  (`Push.Adapters.APNS`, `Push.Adapters.FCM`) and are exercised end-to-end
  against a faked HTTP boundary. What does not exist is credentials. `Push`
  selects per platform at send time: `apns` → `APNS` iff `APNS.configured?()`,
  `fcm` → `FCM` iff `FCM.configured?()`, otherwise THIS module. So the relay
  turns itself on the moment a credential appears — no flag, no deploy switch,
  no code change.

  ═══════════════════════════════════════════════════════════════════════════
  ## THE CREDENTIAL GATE — exactly what a human must supply

  Five environment variables on the CONTROL PLANE (`cloud/`, `/opt/barkpark/cloud/.env`,
  read by `cloud/config/runtime.exs`) turn on iOS; one turns on Android. Each
  platform is independent — shipping Android alone is valid, and iOS devices
  simply keep cancelling.

  ### iOS / APNs — needs the Apple Developer ACCOUNT HOLDER

      APNS_KEY_P8    the FULL contents of the .p8 auth key, PEM and all, newlines
                     preserved (`-----BEGIN PRIVATE KEY-----\\n…\\n-----END PRIVATE KEY-----`).
                     developer.apple.com → Certificates, Identifiers & Profiles →
                     Keys → "+" → enable "Apple Push Notifications service (APNs)"
                     → Continue → Register → Download. THE FILE DOWNLOADS ONCE.
      APNS_KEY_ID    the 10-character Key ID shown on that key's page (e.g. ABC123DEFG).
      APNS_TEAM_ID   the 10-character Team ID, top-right of the developer portal
                     (Membership details).
      APNS_BUNDLE_ID the app's bundle identifier, which is ALSO the `apns-topic`.
                     Must match `apps/mobile/app.json` → `expo.ios.bundleIdentifier`,
                     and that identifier must be registered as an App ID with the
                     Push Notifications capability enabled.
      APNS_ENV       "sandbox" (default; Xcode/TestFlight-development builds) or
                     "production" (App Store / TestFlight distribution builds).
                     WRONG VALUE = every send 400s `BadDeviceToken` with a
                     perfectly valid token — the single most common APNs
                     misconfiguration.

  ### Android / FCM — needs the Firebase PROJECT OWNER

      FCM_SERVICE_ACCOUNT_JSON  the entire downloaded service-account key file,
                     verbatim (a JSON object with `project_id`, `client_email`,
                     `private_key`). console.firebase.google.com → the project →
                     ⚙ Project settings → Service accounts → "Generate new
                     private key". The service account needs the **Firebase
                     Cloud Messaging API (V1)** enabled on the project.

  ### After setting them

      1. restart the control plane (the vars are read at boot by runtime.exs);
      2. nothing else — `Push.adapter_for/1` picks the real adapter on the next
         send, and `Push.credential_status/0` reports which platforms are live.

  ### Still needed on the CLIENT side, separately from these secrets

  The server can only deliver to a device token the OS issued, and the OS only
  issues one to a build that carries the platform's push entitlement:

      * iOS — the `aps-environment` entitlement (Expo: `expo.ios.entitlements`)
        in a build signed by the same team as `APNS_TEAM_ID`.
      * Android — `google-services.json` from the SAME Firebase project as
        `FCM_SERVICE_ACCOUNT_JSON`, in the app build.
      * both — the `expo-notifications` package installed in `apps/mobile`.
        `apps/mobile/src/push/deviceToken.ts` resolves it OPTIONALLY and reports
        `{status: 'unavailable'}` when it is absent, which is the app's honest
        state today.

  Until all three land, registration returns `unavailable`, no
  `device_push_tokens` row is written, and the fan-out selects nothing — the
  row-absence half of severability, unchanged.
  ═══════════════════════════════════════════════════════════════════════════
  """

  @behaviour BarkparkCloud.Push.Adapter

  @impl true
  def send_push(_device_token, _notification), do: {:error, :not_configured}
end
