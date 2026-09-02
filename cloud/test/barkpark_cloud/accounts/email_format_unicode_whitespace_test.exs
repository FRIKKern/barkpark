defmodule BarkparkCloud.Accounts.EmailFormatUnicodeWhitespaceTest do
  @moduledoc """
  cch-email-format-missing-u-modifier — the email shape regexes carry the `u`
  modifier, so Unicode whitespace (NBSP and friends) is whitespace. Without `u`
  PCRE's `\\s` is ASCII-only and "a\u00A0b@example.com" validated as an address
  with no spaces in it. RED-FIRST: drop the `u` from either `@email_format` and
  the matching assertion below fails.
  """
  use BarkparkCloud.DataCase, async: true

  alias BarkparkCloud.Accounts.{TeamInvitation, User}

  @spaces [
    {"NBSP", "\u00A0"},
    {"EN SPACE", "\u2002"},
    {"IDEOGRAPHIC SPACE", "\u3000"},
    {"NARROW NBSP", "\u202F"}
  ]

  test "User.registration_changeset rejects an email carrying Unicode whitespace" do
    for {name, sp} <- @spaces do
      cs =
        User.registration_changeset(%User{}, %{
          email: "ops#{sp}team@example.com",
          password: "correct horse battery"
        })

      refute cs.valid?, "#{name} passed the email shape"
      assert {"must have the @ sign and no spaces", _} = cs.errors[:email], name
    end
  end

  test "TeamInvitation.changeset rejects an email carrying Unicode whitespace" do
    for {name, sp} <- @spaces do
      cs =
        TeamInvitation.changeset(%TeamInvitation{}, %{
          email: "ops#{sp}team@example.com",
          role: "member"
        })

      refute cs.valid?, "#{name} passed the email shape"
      assert {"must have the @ sign and no spaces", _} = cs.errors[:email], name
    end
  end

  test "a plain ASCII address still passes both shapes" do
    assert User.registration_changeset(%User{}, %{
             email: "ops@example.com",
             password: "correct horse battery"
           }).errors[:email] == nil

    assert TeamInvitation.changeset(%TeamInvitation{}, %{email: "ops@example.com", role: "member"}).errors[
             :email
           ] == nil
  end
end
