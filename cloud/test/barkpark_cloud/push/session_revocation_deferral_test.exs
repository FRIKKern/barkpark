defmodule BarkparkCloud.Push.SessionRevocationDeferralTest do
  @moduledoc """
  The TRIPWIRE for the deferral recorded in `BarkparkCloud.Push`'s moduledoc
  under "## Deferred: session-lifecycle revocation (2026-09-13)", owned by row
  `cch-w53-bl-device-push-tokens-survive-sign-out-everywhere`.

  The finding: `Accounts.revoke_all_user_sessions/2` ("sign out everywhere")
  stamps `user_tokens` and NOTHING ELSE, while `device_push_tokens` has exactly
  three revocation paths — platform-reported-dead in `Push.deliver/3`, cap
  eviction in `Push.register_device_token/2`, and the UPSERT that CLEARS
  `revoked_at` — none of them a session event. A signed-out phone stays a live
  fan-out target, and the notification body is the chat session's title.

  The RULING is that no revocation path is built while push cannot fire:
  no adapter can be selected (credential half) and no row can be written
  (row half). A deferral that nobody is forced to revisit is an acceptance in
  disguise, so this test makes it expire ON ITS OWN TERMS: the moment EITHER
  half opens, the assertion below demands the owed revocation path exist and
  fails loudly, naming the row, if it does not.

  HONEST LIMIT — read before trusting this: both halves are read from THIS
  node's config and THIS checkout's files. The credential half is supplied in
  production by env vars inside `if config_env() == :prod` in
  `config/runtime.exs`, which a `mix test` node never evaluates; so this guard
  fires on a credential that is committed to the repo's config or pinned via
  `:push_adapter`, not on one exported only on the prod box. The row half is
  read from `apps/mobile/package.json` and IS repo-observable — and it is the
  half that must open first, because no adapter can deliver to a token the
  client was never able to mint.

  `async: false`: it swaps the node-global `:push_adapter` to `:auto` (the prod
  value) to exercise the real per-platform resolution the rest of the suite
  bypasses via `PushFakeAdapter`.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Push
  alias BarkparkCloud.Push.Adapters

  @row "cch-w53-bl-device-push-tokens-survive-sign-out-everywhere"

  # The owed path, named in the moduledoc paragraph this test guards.
  @owed_fun {BarkparkCloud.Push, :revoke_device_tokens_for_user, 1}

  setup do
    previous = Application.get_env(:barkpark_cloud, :push_adapter)
    Application.put_env(:barkpark_cloud, :push_adapter, :auto)
    on_exit(fn -> Application.put_env(:barkpark_cloud, :push_adapter, previous) end)
    :ok
  end

  test "the sign-out-everywhere deferral for device_push_tokens is still unfired" do
    credential_half_open = Push.credential_status() |> Map.values() |> Enum.any?()
    row_half_open = mobile_can_mint_device_tokens?()

    if credential_half_open or row_half_open do
      {mod, fun, arity} = @owed_fun

      assert owed_revocation_path_exists?(),
             """
             PUSH IS NO LONGER INERT — the deferral recorded in #{inspect(Push)}'s
             moduledoc ("## Deferred: session-lifecycle revocation (2026-09-13)",
             row #{@row}) has EXPIRED, and the revocation path it owes does not exist.

               credential half open (an adapter is selectable): #{credential_half_open}
                 #{inspect(Push.credential_status())}
               row half open (apps/mobile can mint a device token): #{row_half_open}

             OWED: #{inspect(mod)}.#{fun}/#{arity} — revoke every unrevoked
             device_push_tokens row for a user — CALLED FROM
             BarkparkCloud.Accounts.revoke_all_user_sessions/2, so that "Every other
             browser and device is signed out" is true of the device half as well.
             Until it lands, a phone whose sessions were all revoked keeps receiving
             chat_blocked notifications whose body is the session title.
             """
    else
      # The deferral's precondition, asserted rather than assumed: with no
      # credentials, EVERY platform (including an unknown one) resolves to the
      # honest terminal adapter, so nothing can be delivered to a stale row.
      assert Push.adapter_for("apns") == Adapters.NotConfigured
      assert Push.adapter_for("fcm") == Adapters.NotConfigured
      assert Push.adapter_for("carrier-pigeon") == Adapters.NotConfigured
      assert Push.credential_status() == %{"apns" => false, "fcm" => false}
    end
  end

  defp owed_revocation_path_exists? do
    {mod, fun, arity} = @owed_fun
    Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)
  end

  # The row half: `apps/mobile/src/push/deviceToken.ts` resolves
  # `expo-notifications` OPTIONALLY and reports `unavailable` when it is absent,
  # so no device_push_tokens row can be written until the dependency lands.
  defp mobile_can_mint_device_tokens? do
    path = Path.expand("../../../../apps/mobile/package.json", __DIR__)

    case File.read(path) do
      {:ok, json} ->
        json
        |> Jason.decode!()
        |> Map.take(["dependencies", "devDependencies"])
        |> Map.values()
        |> Enum.any?(&Map.has_key?(&1, "expo-notifications"))

      {:error, _} ->
        # The manifest moved or the checkout is partial: this guard cannot see
        # the row half, so it does not get to claim the half is closed.
        true
    end
  end
end
