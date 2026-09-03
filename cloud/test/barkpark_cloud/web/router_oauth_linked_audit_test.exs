defmodule BarkparkCloud.Web.RouterOAuthLinkedAuditTest do
  @moduledoc """
  cch-w53-bl-oauth-linked-needs-a-branch-reporting-return — `oauth.linked` is
  produced on the LINK branch ONLY.

  The verb sat declared-but-unproduced for two waves, and the reason was not a
  missing seam: the OAuth callback really does link identities. It could not
  SAY so. `Accounts.get_or_create_user_from_oauth/1` answered a bare
  `{:ok, user}` for all three of its precedence arms, so a producer wired to it
  would have stamped `oauth.linked` on every first-ever OAuth signup — a trail
  entry describing a linking event that did not happen, which is worse than the
  silence it replaced.

  These tests drive the REAL route (`GET /v1/auth/oauth/:provider/callback`
  through `BarkparkCloud.OAuthStub`, zero network) rather than the context
  function, because the branch gate lives at the call site and a context-level
  test would prove nothing about what the callback stamps.

  THE PAIR IS THE POINT — one arm without the other proves nothing:

    * a first-ever OAuth signup writes NO `oauth.linked` row (the birth arm), and
    * an IdP converging onto an account that already existed writes EXACTLY one.

  A producer with no branch gate passes the second and fails the first; a
  producer that never runs passes the first and fails the second.

  The third test is the `audit_account_security/2` precedent: an account whose
  `primary_team/1` is nil (a membership-less user — `list_user_teams()
  |> List.first()`) hits a `team_id` column that is `null: false`. That is a
  LOGGED SKIP with a normal 302, never a 500 on a sign-in that already
  succeeded, and never a silent discard.
  """
  use BarkparkCloud.DataCase, async: false

  import Plug.Test
  import ExUnit.CaptureLog

  alias BarkparkCloud.{Accounts, OAuth}
  alias BarkparkCloud.Accounts.AuditEvent
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  # The GitHub stub's canned identity: profile id 4242, verified primary email
  # octocat@example.com (test/support/oauth_stub.ex). Pre-creating a password
  # account on THAT address is what turns the callback's birth arm into its link
  # arm — the same convergence a real human performs by clicking "Continue with
  # GitHub" on an account they made with a password.
  @stub_email "octocat@example.com"

  defp callback(provider) do
    state = OAuth.mint_state(provider)
    Router.call(conn(:get, "/v1/auth/oauth/#{provider}/callback?code=abc&state=#{state}"), @opts)
  end

  defp linked_rows do
    Repo.all(from(e in AuditEvent, where: e.action == "oauth.linked"))
  end

  defp password_account(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct horse battery"})
    user
  end

  test "a FIRST-EVER OAuth signup writes NO oauth.linked row" do
    conn = callback("github")
    assert conn.status == 302

    # The signup really happened — without this the assertion below is vacuous:
    # a callback that 302'd to the error page writes no row for the boring
    # reason that it created no user either.
    user = Accounts.get_user_by_external_identity("github", "4242")
    assert user != nil
    assert user.email == @stub_email
    assert Accounts.primary_team(user) != nil

    assert linked_rows() == [],
           "a first-ever OAuth signup stamped oauth.linked. There was no account for the " <>
             "identity to be LINKED onto — the row describes an event that did not happen. " <>
             "The producer must gate on get_or_create_user_from_oauth/1's :linked branch, " <>
             "not on the call succeeding."
  end

  test "an IdP converging onto an EXISTING account writes EXACTLY one oauth.linked row" do
    user = password_account(@stub_email)
    {:ok, team} = Accounts.create_team(%{name: "Octo Co", slug: "octo-co"})
    {:ok, _} = Accounts.add_member(team, user, "owner")

    conn = callback("github")
    assert conn.status == 302

    # The link is real: the identity now resolves to the account that already
    # existed, and no second user was forked.
    assert Accounts.get_user_by_external_identity("github", "4242").id == user.id

    rows = linked_rows()

    assert length(rows) == 1,
           "the LINK branch produced #{length(rows)} oauth.linked rows, expected 1. " <>
             "An existing account gaining a provider identity is the one event this verb names."

    [row] = rows

    assert row.team_id == team.id
    assert row.actor_user_id == user.id
    assert row.target_type == "user"
    assert row.target_id == user.id
    assert row.metadata["provider"] == "github"
  end

  test "a SECOND sight of the same identity adds no further row (the :existing branch)" do
    user = password_account(@stub_email)
    {:ok, team} = Accounts.create_team(%{name: "Octo Co", slug: "octo-co-2"})
    {:ok, _} = Accounts.add_member(team, user, "owner")

    assert callback("github").status == 302
    assert length(linked_rows()) == 1

    # Signing in again links nothing — the identity was already ours.
    assert callback("github").status == 302

    assert length(linked_rows()) == 1,
           "a repeat sign-in stamped a second oauth.linked row. The :existing branch links " <>
             "nothing; only :linked may produce."
  end

  test "a nil primary_team is a LOGGED SKIP with a normal 302, never a 500 and never silence" do
    # A membership-less account: Accounts.primary_team/1 is
    # list_user_teams() |> List.first(), so this user resolves to nil while
    # audit_events.team_id is null: false. The convergence still happens.
    user = password_account(@stub_email)
    assert Accounts.primary_team(user) == nil

    log =
      capture_log(fn ->
        conn = callback("github")

        assert conn.status == 302,
               "a failed audit insert changed the OUTCOME of a sign-in that had already " <>
                 "succeeded — the identity row is committed by the time the producer runs."
      end)

    assert Accounts.get_user_by_external_identity("github", "4242").id == user.id

    assert linked_rows() == [],
           "a row was written for a user with no team — audit_events.team_id is null: false, " <>
             "so this could only have been a crash or a fabricated team_id."

    assert log =~ "oauth.linked SKIPPED",
           "the skip was SILENT. A discarded audit write with no log is the shape " <>
             "cch-w51-bl-record-audit-errors-are-discarded-at-every-call-site exists to stop."

    assert log =~ user.id
  end
end
