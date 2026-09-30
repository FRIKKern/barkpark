defmodule BarkparkCloud.AccountsLoginBcryptCountTest do
  @moduledoc """
  task-97852e25746dcd87 — `get_user_by_email_and_password/2` ran TWO bcrypt
  verifications for a known email with a wrong password and ONE for an unknown
  email, so login latency enumerated registered addresses (measured 1.64x).
  Proven structurally — bcrypt call counts via :erlang call_count tracing —
  never by a flaky wall-clock ratio.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.Accounts

  @verify {Bcrypt, :verify_pass, 2}
  @dummy {Bcrypt, :no_user_verify, 1}

  defp bcrypt_calls(fun) do
    for mfa <- [@verify, @dummy], do: :erlang.trace_pattern(mfa, true, [:call_count])

    try do
      fun.()

      for mfa <- [@verify, @dummy], into: %{} do
        {:call_count, n} = :erlang.trace_info(mfa, :call_count)
        {elem(mfa, 1), n || 0}
      end
    after
      for mfa <- [@verify, @dummy], do: :erlang.trace_pattern(mfa, false, [:call_count])
    end
  end

  setup do
    {:ok, user} =
      Accounts.register_user(%{email: "known@example.com", password: "right horse battery"})

    %{user: user}
  end

  test "known email + WRONG password: one verification, not two" do
    calls =
      bcrypt_calls(fn ->
        refute Accounts.get_user_by_email_and_password("known@example.com", "wrong-password-1")
      end)

    assert calls[:verify_pass] + calls[:no_user_verify] == 1, "bcrypt calls: #{inspect(calls)}"
  end

  test "unknown email: one (dummy) verification" do
    calls =
      bcrypt_calls(fn ->
        refute Accounts.get_user_by_email_and_password("nobody@example.com", "wrong-password-1")
      end)

    assert calls == %{verify_pass: 0, no_user_verify: 1}
  end

  test "known email + right password: one verification, and the user comes back", %{user: user} do
    calls =
      bcrypt_calls(fn ->
        assert %{id: id} =
                 Accounts.get_user_by_email_and_password(
                   "known@example.com",
                   "right horse battery"
                 )

        assert id == user.id
      end)

    assert calls == %{verify_pass: 1, no_user_verify: 0}
  end
end
