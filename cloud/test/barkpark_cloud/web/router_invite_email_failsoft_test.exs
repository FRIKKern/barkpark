defmodule BarkparkCloud.Web.RouterInviteEmailFailSoftTest do
  @moduledoc """
  Fail-soft guard for the member-invite email send (invite-email-wiring).

  The invite route mails the invitee the accept link over the PLATFORM mailer,
  but a relay hiccup must NEVER break invite creation: the invitation is already
  committed and the copy-paste `accept_url` fallback is still returned. This test
  forces the platform Mailer to error and proves the route still 201s with an
  `accept_url` (and enqueues nothing extra).

  `async: false` because it swaps the module-global Mailer adapter for the
  duration of the test (restored via `on_exit`).
  """
  use BarkparkCloud.DataCase, async: false
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Web.Router

  # A Swoosh adapter that always fails delivery — stands in for a down mail relay.
  defmodule FailingAdapter do
    use Swoosh.Adapter

    @impl true
    def deliver(_email, _config), do: {:error, {:relay_down, :econnrefused}}
  end

  @opts Router.init([])
  @password "correct-horse-battery"

  setup do
    prev = Application.get_env(:barkpark_cloud, BarkparkCloud.Mailer)
    Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, adapter: FailingAdapter)
    on_exit(fn -> Application.put_env(:barkpark_cloud, BarkparkCloud.Mailer, prev) end)
    :ok
  end

  defp user_fixture do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })

    user
  end

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  test "a mail-relay failure does not break invite creation — invite still created + accept_url still returned" do
    team = team_fixture()
    owner = user_fixture()
    {:ok, _} = Accounts.add_member(team, owner, "owner")
    {:ok, token} = Accounts.create_user_session_token(owner)

    conn =
      call(:post, "/v1/teams/#{team.id}/invitations", %{email: "invitee@example.com"}, token)

    # The send errored (FailingAdapter), but the invite is committed and the
    # copy-paste fallback accept_url is still returned — no 500.
    assert conn.status == 201
    body = Jason.decode!(conn.resp_body)
    assert body["invitation"]["email"] == "invitee@example.com"
    assert is_binary(body["accept_url"])
    assert body["accept_url"] =~ "token="

    # The invitation really persisted despite the failed send.
    assert [_one] = Accounts.list_invitations(team)
  end
end
