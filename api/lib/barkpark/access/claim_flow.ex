defmodule Barkpark.Access.ClaimFlow do
  @moduledoc """
  The ONE no-oracle claim resolution for airdrop grants — shared by BOTH the
  browser flow (`BarkparkWeb.GrantController`) and the JSON API
  (`BarkparkWeb.AccessController.claim/2`), so there is exactly one no-oracle
  contract, not two byte-identical re-improvisations.

  ## What it does

  Given a raw link token and an AUTHENTICATED user, resolve the claim:

    * `{:ok, grant}` — the grant was active, addressed to THIS account, and the
      atomic claim succeeded (`grantee_user_id` + `claimed_at` bound).
    * `:invalid` — EVERY other outcome, collapsed to one value: token unknown,
      addressed to a different account, expired, revoked, or already-spent.

  ## Why it collapses

  `Access.claim/2` binds *whoever is authenticated* and is atomic on
  `claimed_at IS NULL`; it does NOT verify the claimant is the intended grantee.
  The grantee-email match is therefore enforced HERE, before the claim runs.

  Because every non-success returns the SAME `:invalid`, callers cannot branch
  by reason — a wrong-grantee authenticated user and a nonexistent token are
  indistinguishable. Token existence is unobservable. Each surface renders that
  one outcome in its own idiom (a redirect for the browser, a uniform JSON error
  for the API), but the DECISION is made in exactly one place.

  ## Confirmed-account gate (account-binding depends on mailbox control)

  Password registration is self-serve and login has no confirmation gate, so an
  attacker could self-register an UNCONFIRMED account with the grantee's email,
  obtain the raw token, and claim — binding the grant without ever proving they
  control the mailbox the grant is addressed to. Account-binding is therefore
  meaningless unless the claimant proved mailbox control. So a claim succeeds
  ONLY if the grant is active AND `grantee_email` matches AND the user's
  `confirmed_at` is set. An unconfirmed grantee collapses to the SAME `:invalid`
  no-oracle outcome — never a distinct "account not confirmed" error that would
  leak grant existence or account state.

  NOTE (accepted exception): SSO / SCIM / social sign-in stamp `confirmed_at`
  without an email round-trip — that is IdP-trust by design. This gate closes
  the self-serve unconfirmed-password hole, not the IdP-trust variant.
  """
  alias Barkpark.Access
  alias Barkpark.Accounts.User

  @doc """
  Resolve an authenticated claim to `{:ok, grant}` or the single `:invalid`
  no-oracle outcome. Never branches by failure reason.
  """
  @spec resolve(String.t(), User.t()) :: {:ok, Access.Grant.t()} | :invalid
  def resolve(token, %User{} = user) when is_binary(token) do
    grant = Access.lookup_by_token(token)

    if grant && grantee?(grant, user) && confirmed?(user) do
      case Access.claim(token, user) do
        {:ok, claimed} -> {:ok, claimed}
        {:error, _reason} -> :invalid
      end
    else
      :invalid
    end
  end

  def resolve(_token, _user), do: :invalid

  # An account may claim only after it proved mailbox control (`confirmed_at`
  # set). An unconfirmed grantee fails HERE, folding into the single `:invalid`
  # outcome — byte-identical to a wrong-email or nonexistent-token failure, so
  # neither grant existence nor account state is observable. Fail-closed: a nil
  # `confirmed_at` denies.
  @spec confirmed?(User.t()) :: boolean()
  defp confirmed?(%User{confirmed_at: %DateTime{}}), do: true
  defp confirmed?(_user), do: false

  @doc """
  Case-insensitive grantee-email match. User emails are stored downcased
  (citext); a grant's `grantee_email` is not normalized at mint, so downcase
  both sides.
  """
  @spec grantee?(Access.Grant.t(), User.t()) :: boolean()
  def grantee?(%Access.Grant{grantee_email: email}, %User{email: user_email})
      when is_binary(email) and is_binary(user_email) do
    String.downcase(email) == String.downcase(user_email)
  end

  def grantee?(_grant, _user), do: false
end
