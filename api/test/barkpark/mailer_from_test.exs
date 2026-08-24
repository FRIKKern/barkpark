defmodule Barkpark.MailerFromTest do
  @moduledoc """
  gh-9531 — NAMED FAILURE MODE: the transactional `From` was a compile-time
  `@from` module attribute inside each notifier. A module attribute is frozen
  when the release is BUILT, so runtime config — evaluated at boot — could never
  move it. A self-hoster pointing SMTP_HOST at their own relay still emitted
  `From: no-reply@barkpark.cloud`; relays reject a message whose From is not the
  authenticated sender (and where they do not, the receiver's SPF/DKIM/DMARC
  alignment fails). Because delivery is fire-and-forget through
  `Barkpark.TaskSupervisor`, register and request-reset still answered HTTP 200
  and the mail was simply never delivered — password resets, magic links and
  airdrop-grant invitations, silently.

  These tests guard the runtime seam:

    * unconfigured, the From is the HISTORICAL default — no existing deployment
      changes behaviour;
    * a configured address reaches the WIRE, on every send site (both notifiers
      — the class is exhausted, not just the reported one);
    * the value is read at CALL time, so a boot-time write wins (the property a
      module attribute cannot have);
    * a present-but-malformed value FAILS CLOSED — it raises rather than falling
      back to the barkpark.cloud default, which would be the same defect wearing
      a new costume: the operator believes their sender is set while the box
      keeps emitting ours.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Access.GrantNotifier
  alias Barkpark.Accounts.UserNotifier
  alias Barkpark.Mailer

  @default_pair {"Barkpark", "no-reply@barkpark.cloud"}

  setup do
    original = Application.get_env(:barkpark, :mail)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:barkpark, :mail)
        kw -> Application.put_env(:barkpark, :mail, kw)
      end
    end)

    :ok
  end

  defp put_mail(kw), do: Application.put_env(:barkpark, :mail, kw)

  describe "the default is preserved (no behaviour change for existing deployments)" do
    test "from/0 with NO :mail config returns the historical pair" do
      Application.delete_env(:barkpark, :mail)
      assert Mailer.from() == @default_pair
      assert Mailer.default_from() == @default_pair
    end

    test "from/0 with an EMPTY :mail config returns the historical pair" do
      put_mail([])
      assert Mailer.from() == @default_pair
    end

    test "an unconfigured send puts the historical From on the wire" do
      Application.delete_env(:barkpark, :mail)

      assert {:ok, _} = UserNotifier.deliver_reset("u@example.com", "https://x/r/tok")
      assert_receive {:email, delivered}, 1_000
      assert delivered.from == @default_pair
    end
  end

  describe "MUTATION: a configured From reaches the wire" do
    test "UserNotifier — password reset carries the configured sender" do
      put_mail(from_address: "noreply@acme.test", from_name: "Acme Books")

      assert {:ok, _} = UserNotifier.deliver_reset("u@example.com", "https://x/r/tok")
      assert_receive {:email, delivered}, 1_000
      assert delivered.from == {"Acme Books", "noreply@acme.test"}
      refute delivered.from == @default_pair
    end

    test "UserNotifier — confirmation, magic link and already-registered all follow" do
      put_mail(from_address: "noreply@acme.test", from_name: "Acme Books")

      for send_fn <- [
            fn -> UserNotifier.deliver_confirmation("u@example.com", "https://x/c/tok") end,
            fn -> UserNotifier.deliver_magic_link("u@example.com", "https://x/m/tok") end,
            fn -> UserNotifier.deliver_already_registered("u@example.com") end
          ] do
        assert {:ok, _} = send_fn.()
        assert_receive {:email, delivered}, 1_000
        assert delivered.from == {"Acme Books", "noreply@acme.test"}
      end
    end

    # The class is two notifiers, not one. gh-9531 named only UserNotifier;
    # GrantNotifier carried a byte-identical @from and would have been left
    # un-overridable by a fix that read only the reported file.
    test "GrantNotifier — the airdrop grant invitation carries it too" do
      put_mail(from_address: "noreply@acme.test", from_name: "Acme Books")

      assert {:ok, _} = GrantNotifier.deliver_grant("u@example.com", "https://x/grant/tok")
      assert_receive {:email, delivered}, 1_000
      assert delivered.from == {"Acme Books", "noreply@acme.test"}
    end

    test "the address alone can be set — the default name is kept" do
      put_mail(from_address: "noreply@acme.test")
      assert Mailer.from() == {"Barkpark", "noreply@acme.test"}
    end

    test "an EMPTY name is honoured, not defaulted (bare-address From)" do
      put_mail(from_address: "noreply@acme.test", from_name: "")
      assert Mailer.from() == {"", "noreply@acme.test"}
    end

    # This is the property a compile-time @from cannot have: the value is read
    # at CALL time, so a write that lands AFTER the module was compiled/loaded
    # still takes effect. Boot-time runtime config is exactly such a write.
    test "the value is read at CALL time, so a later write wins" do
      put_mail(from_address: "first@acme.test")
      assert {_, "first@acme.test"} = Mailer.from()

      put_mail(from_address: "second@acme.test")
      assert {_, "second@acme.test"} = Mailer.from()
    end
  end

  describe "FAIL-CLOSED: a malformed value raises instead of falling back" do
    test "a blank address raises" do
      put_mail(from_address: "")
      assert_raise ArgumentError, ~r/must not be blank/, &Mailer.from/0
    end

    test "an address with no at-sign raises" do
      put_mail(from_address: "not-an-address")
      assert_raise ArgumentError, ~r/exactly one/, &Mailer.from/0
    end

    test "an address with two at-signs raises" do
      put_mail(from_address: "a@b@c.test")
      assert_raise ArgumentError, ~r/exactly one/, &Mailer.from/0
    end

    test "an address missing a local part or a domain raises" do
      put_mail(from_address: "@acme.test")
      assert_raise ArgumentError, ~r/non-empty local part and domain/, &Mailer.from/0

      put_mail(from_address: "noreply@")
      assert_raise ArgumentError, ~r/non-empty local part and domain/, &Mailer.from/0
    end

    # SMTP header injection: the From rides ONE header line, so a CR or LF in
    # the configured value would terminate it and let the remainder be parsed as
    # further headers (Bcc, Content-Type).
    test "an address carrying CR or LF raises (header injection)" do
      put_mail(from_address: "noreply@acme.test\r\nBcc: victim@example.com")
      assert_raise ArgumentError, ~r/whitespace, control characters/, &Mailer.from/0
    end

    test "an address carrying a comma or angle brackets raises (mailbox expansion)" do
      put_mail(from_address: "noreply@acme.test,attacker@evil.test")
      assert_raise ArgumentError, ~r/whitespace, control characters/, &Mailer.from/0

      put_mail(from_address: "<noreply@acme.test>")
      assert_raise ArgumentError, ~r/whitespace, control characters/, &Mailer.from/0
    end

    test "a name carrying CR or LF raises (header injection)" do
      put_mail(from_address: "noreply@acme.test", from_name: "Acme\r\nBcc: victim@example.com")
      assert_raise ArgumentError, ~r/control characters/, &Mailer.from/0
    end

    test "a non-string address or name raises rather than reaching Swoosh" do
      put_mail(from_address: :noreply)
      assert_raise ArgumentError, ~r/must be a string/, &Mailer.from/0

      put_mail(from_address: "noreply@acme.test", from_name: 42)
      assert_raise ArgumentError, ~r/must be a string/, &Mailer.from/0
    end

    # The whole point of failing closed: the boot path calls from/0, so a
    # malformed value refuses the node. Barkpark.Application.start/2 makes that
    # call; this pins that a raise is what it will meet.
    test "the boot-time resolution raises on a malformed address" do
      put_mail(from_address: "no-at-sign")

      assert_raise ArgumentError, fn ->
        Barkpark.Mailer.from()
      end
    end
  end
end
