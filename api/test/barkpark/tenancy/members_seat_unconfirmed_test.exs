defmodule Barkpark.Tenancy.MembersSeatUnconfirmedTest do
  @moduledoc """
  Seating an email (`Members.add_user_member/3`, behind
  `POST /w/:ws/p/:p/v1/members`) resolved the account with
  `Sso.find_or_create_user/1`, which returns ANY existing row. A squatter who
  self-registered the victim's address (never confirmed, password known to
  them) therefore received the seat the admin meant for the victim, and the
  seat then satisfied `org_member?` for later SSO adoption. An unconfirmed
  account is now reclaimed before it is seated (task-02cb6bfc7b54924d).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures
  import Barkpark.AccountsFixtures

  alias Barkpark.Accounts
  alias Barkpark.Tenancy.Members

  @password "correct-horse-battery"

  test "seating an unconfirmed account takes it away from whoever registered it" do
    ws = create_workspace!("seat-squat-#{System.unique_integer([:positive])}")
    email = "victim-#{System.unique_integer([:positive])}@example.com"
    squatter = register_unconfirmed_user(email, @password)
    {:ok, squatter_session} = Accounts.create_user_session_token(squatter)

    assert {:ok, _} = Members.add_user_member(ws.id, email, "admin")

    refute Accounts.get_user_by_email_and_password(email, @password),
           "the squatter's password still signs in to the seated account"

    refute Accounts.verify_user_session_token(squatter_session)
  end

  test "seating a CONFIRMED account keeps its password (control)" do
    ws = create_workspace!("seat-confirmed-#{System.unique_integer([:positive])}")
    email = "owner-#{System.unique_integer([:positive])}@example.com"
    _user = register_user(email, @password)

    assert {:ok, _} = Members.add_user_member(ws.id, email, "member")

    assert Accounts.get_user_by_email_and_password(email, @password)
  end
end
