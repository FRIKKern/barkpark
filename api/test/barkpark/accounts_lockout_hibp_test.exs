defmodule Barkpark.AccountsLockoutHibpTest do
  @moduledoc "Per-account login lockout + HIBP breached-password check (era-w7)."
  use Barkpark.DataCase, async: false

  alias Barkpark.Accounts

  @password "correct-horse-battery"

  defp user!(email) do
    {:ok, u} = Accounts.register_user(%{email: email, password: @password})
    u
  end

  describe "per-account login lockout" do
    setup do
      prev_max = Application.get_env(:barkpark, :max_failed_logins)
      Application.put_env(:barkpark, :max_failed_logins, 3)
      on_exit(fn -> set_or_del(:max_failed_logins, prev_max) end)
      :ok
    end

    test "N wrong-password attempts lock the account; a CORRECT password then still fails" do
      user!("lock@example.com")

      for _ <- 1..3 do
        assert Accounts.get_user_by_email_and_password("lock@example.com", "wrong") == nil
      end

      # Now locked: even the right password is rejected (generic nil).
      assert Accounts.get_user_by_email_and_password("lock@example.com", @password) == nil

      # The lock is recorded on the account.
      assert Accounts.get_user_by_email("lock@example.com").locked_until
    end

    test "a successful login BEFORE the threshold resets the failure counter" do
      user!("reset@example.com")

      assert Accounts.get_user_by_email_and_password("reset@example.com", "wrong") == nil
      assert Accounts.get_user_by_email_and_password("reset@example.com", "wrong") == nil
      assert %{failed_login_count: 2} = Accounts.get_user_by_email("reset@example.com")

      # A correct login clears the counter…
      assert %Accounts.User{} = Accounts.get_user_by_email_and_password("reset@example.com", @password)
      assert %{failed_login_count: 0, locked_until: nil} = Accounts.get_user_by_email("reset@example.com")

      # …so a fresh failure streak starts from zero (not near the threshold).
      assert Accounts.get_user_by_email_and_password("reset@example.com", "wrong") == nil
      refute Accounts.get_user_by_email("reset@example.com").locked_until
    end

    test "once the lock window PASSES, the correct password works again" do
      user = user!("expire@example.com")
      for _ <- 1..3, do: Accounts.get_user_by_email_and_password("expire@example.com", "wrong")
      assert Accounts.get_user_by_email_and_password("expire@example.com", @password) == nil

      # Simulate the window elapsing.
      user
      |> Ecto.Changeset.change(%{locked_until: DateTime.add(DateTime.utc_now(), -1, :second)})
      |> Barkpark.Repo.update()

      assert %Accounts.User{} = Accounts.get_user_by_email_and_password("expire@example.com", @password)
    end

    test "an unknown email never errors and creates no lock state (no enumeration signal)" do
      for _ <- 1..5 do
        assert Accounts.get_user_by_email_and_password("ghost@example.com", "whatever") == nil
      end

      refute Accounts.get_user_by_email("ghost@example.com")
    end
  end

  describe "HIBP breached-password check" do
    # A mock range client that records the prefix it was asked for and returns a
    # canned body containing the SHA-1 SUFFIX of "#{@password}" (so that exact
    # password reads as breached).
    defmodule MockHibp do
      @behaviour Barkpark.Accounts.Hibp
      # Literal copy of the outer @password (nested modules don't inherit attrs).
      @pw "correct-horse-battery"
      @impl true
      def range(prefix) do
        pid = Application.get_env(:barkpark, :hibp_test_pid)
        if is_pid(pid), do: send(pid, {:range, prefix})

        <<_::binary-size(5), suffix::binary>> =
          :crypto.hash(:sha, @pw) |> Base.encode16(case: :upper)

        {:ok, "#{suffix}:42\nFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF:1"}
      end
    end

    defmodule DownHibp do
      @behaviour Barkpark.Accounts.Hibp
      @impl true
      def range(_prefix), do: {:error, :timeout}
    end

    setup do
      prev_enabled = Application.get_env(:barkpark, :hibp_enabled)
      prev_http = Application.get_env(:barkpark, :hibp_http)
      Application.put_env(:barkpark, :hibp_test_pid, self())

      on_exit(fn ->
        set_or_del(:hibp_enabled, prev_enabled)
        set_or_del(:hibp_http, prev_http)
        Application.delete_env(:barkpark, :hibp_test_pid)
      end)

      :ok
    end

    test "DISABLED by default: a breached password registers fine, no HTTP call" do
      Application.delete_env(:barkpark, :hibp_enabled)
      Application.put_env(:barkpark, :hibp_http, MockHibp)

      assert {:ok, _} = Accounts.register_user(%{email: "off@example.com", password: @password})
      refute_receive {:range, _}, 200
    end

    test "enabled: a breached password is rejected, and only the 5-char SHA-1 prefix is sent" do
      Application.put_env(:barkpark, :hibp_enabled, true)
      Application.put_env(:barkpark, :hibp_http, MockHibp)

      assert {:error, cs} = Accounts.register_user(%{email: "pwned@example.com", password: @password})
      assert "has appeared in a known data breach — choose a different one" in errors_on(cs).password

      # k-anonymity: the client only ever received a 5-char prefix, and it is
      # exactly the password's SHA-1 prefix — the password never left.
      expected = :crypto.hash(:sha, @password) |> Base.encode16(case: :upper) |> binary_part(0, 5)
      assert_received {:range, ^expected}
      assert String.length(expected) == 5
    end

    test "enabled: a NON-breached password registers fine" do
      Application.put_env(:barkpark, :hibp_enabled, true)
      # MockHibp only lists @password's suffix, so a different password's suffix
      # is absent → not breached.
      Application.put_env(:barkpark, :hibp_http, MockHibp)

      assert {:ok, _} = Accounts.register_user(%{email: "clean@example.com", password: "a-totally-different-passphrase-9"})
    end

    test "fails OPEN: when HIBP is unreachable, the password is allowed" do
      Application.put_env(:barkpark, :hibp_enabled, true)
      Application.put_env(:barkpark, :hibp_http, DownHibp)

      assert {:ok, _} = Accounts.register_user(%{email: "open@example.com", password: @password})
    end
  end

  defp set_or_del(key, nil), do: Application.delete_env(:barkpark, key)
  defp set_or_del(key, val), do: Application.put_env(:barkpark, key, val)
end
