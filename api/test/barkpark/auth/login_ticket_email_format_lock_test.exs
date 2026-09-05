defmodule Barkpark.Auth.LoginTicketEmailFormatLockTest do
  @moduledoc """
  LOCK for a hand-maintained mirror.

  `Barkpark.Auth.LoginTicket` refuses a malformed `user_email` at the mint with
  a copy of `Barkpark.Accounts.User`'s `@email_format` (a private attribute the
  ticket module cannot import). The comment beside the copy says "keep the two
  in lockstep" — prose, not a gate. This test IS the gate: it decodes both
  literals out of the two source files and asserts them term-identical, then
  drives a probe set through both changesets and asserts the verdicts agree.

  Mutation: change one character of either regex → the source arm reds naming
  both literals; a probe that only one side refuses → the behavioural arm reds.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Accounts.User
  alias Barkpark.Auth.LoginTicket

  @user_src "lib/barkpark/accounts/user.ex"
  @ticket_src "lib/barkpark/auth/login_ticket.ex"
  @attr ~r/^\s*@email_format\s+(~r\/.*\/\w*)\s*$/m

  defp literal!(path) do
    src = File.read!(path)

    case Regex.run(@attr, src, capture: :all_but_first) do
      [lit] ->
        lit

      other ->
        flunk("expected exactly one @email_format literal in #{path}, got #{inspect(other)}")
    end
  end

  test "the two @email_format literals are byte-identical" do
    user = literal!(@user_src)
    ticket = literal!(@ticket_src)
    # non-vacuity: the extractor found a real regex literal on both sides
    assert String.starts_with?(user, "~r/") and String.length(user) > 5
    assert String.starts_with?(ticket, "~r/") and String.length(ticket) > 5

    assert user == ticket,
           "#{@ticket_src} copies #{@user_src}'s @email_format and they drifted:\n" <>
             "  user.ex:         #{user}\n  login_ticket.ex: #{ticket}\n" <>
             "The mint must refuse exactly what registration refuses. Change both, or neither."
  end

  @probes [
    "someone@example.com",
    "a@b",
    "not-an-email",
    "has space@example.com",
    "@example.com",
    "someone@",
    "two@at@signs",
    "tab\t@example.com",
    ""
  ]

  test "both changesets return the same format verdict for every probe" do
    base_ticket = %{
      ticket_hash: "h",
      api_token: "t",
      expires_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    verdicts =
      for e <- @probes do
        t = LoginTicket.changeset(%LoginTicket{}, Map.put(base_ticket, :user_email, e))
        u = User.registration_changeset(%User{}, %{email: e, password: String.duplicate("x", 12)})

        {e, format_error?(t, :user_email), format_error?(u, :email)}
      end

    # non-vacuity: the probe set exercises BOTH outcomes on the ticket side
    assert Enum.any?(verdicts, fn {_, t, _} -> t end)
    assert Enum.any?(verdicts, fn {_, t, _} -> not t end)

    disagree = for {e, t, u} <- verdicts, t != u, do: {e, ticket_refuses: t, user_refuses: u}

    assert disagree == [],
           "format verdicts differ between mint and registration: #{inspect(disagree)}"
  end

  # "" is caught by validate_required on the user side and ignored by
  # validate_format on both, so compare the FORMAT message only.
  defp format_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {"must have the @ sign and no spaces", _}} -> true
      _ -> false
    end)
  end
end
