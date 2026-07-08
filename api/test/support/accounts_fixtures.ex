defmodule Barkpark.AccountsFixtures do
  @moduledoc """
  ONE source of truth for the user-registration test fixtures.

  A real claimant is a CONFIRMED account — claim requires proven mailbox
  control (`confirmed_at`). Registration is self-serve; the email round-trip
  (or IdP provisioning) stamps confirmation via `User.confirm_changeset`, the
  same path SSO/SCIM use.

  `register_user/1,2` is confirmed-by-default (the real-claimant fixture);
  `register_unconfirmed_user/1,2` is the never-confirmed variant — the
  self-serve impersonation hole those tests probe.

  These previously lived as diverging module-local `register_user/1` copies in
  three controller tests; one copy was missed when the confirmed-account gate
  landed and two legit positive tests went RED. Kept here so a future
  auth-fixture change touches exactly one place.

      import Barkpark.AccountsFixtures

      user = register_user("grantee@example.com")          # confirmed
      hole = register_unconfirmed_user("attacker@example.com")
  """

  alias Barkpark.Accounts
  alias Barkpark.Repo

  @default_password "correct-horse-battery"

  @doc "Register a CONFIRMED user (the real-claimant fixture)."
  def register_user(email, password \\ @default_password) do
    user = register_unconfirmed_user(email, password)
    Repo.update!(Accounts.User.confirm_changeset(user))
  end

  @doc "Register a user that never confirmed its mailbox (the impersonation hole)."
  def register_unconfirmed_user(email, password \\ @default_password) do
    {:ok, user} = Accounts.register_user(%{email: email, password: password})
    user
  end
end
