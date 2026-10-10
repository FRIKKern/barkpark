defmodule Barkpark.Tenancy.PublishRefusedTest do
  @moduledoc """
  `Tenancy.Auth.publish_refused?/2` — the draft-only seat predicate
  (task-348a4fbe24feede6). It only takes away: a caller refuses publish when a
  seat it acts through is `contributor`, and nothing else changes.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Accounts, Tenancy}
  alias Barkpark.Content.CallerContext
  alias Barkpark.Tenancy.Auth, as: TAuth

  defp workspace!(slug) do
    {:ok, ws} =
      Tenancy.create_workspace(%{
        slug: "#{slug}-#{System.unique_integer([:positive])}",
        name: slug
      })

    ws
  end

  defp user! do
    {:ok, user} =
      Accounts.register_user(%{
        email: "pub-refused-#{System.unique_integer([:positive])}@example.com",
        password: "correct-horse-battery"
      })

    user
  end

  defp token! do
    {:ok, token} =
      Barkpark.Auth.create_token(
        "pub-refused-#{System.unique_integer([:positive])}",
        "pub refused",
        "production",
        ["read", "write"]
      )

    token
  end

  test "a contributor user seat refuses publish in that workspace only" do
    ws_a = workspace!("pub-a")
    ws_b = workspace!("pub-b")
    user = user!()
    {:ok, _} = TAuth.create_membership(ws_a.id, user.id, "contributor", "user")
    {:ok, _} = TAuth.create_membership(ws_b.id, user.id, "member", "user")
    ctx = CallerContext.from_user(user.id, load_grants: false)

    assert TAuth.publish_refused?(ctx, ws_a.id)
    refute TAuth.publish_refused?(ctx, ws_b.id)
  end

  test "a contributor token seat refuses; a member token seat does not" do
    ws = workspace!("pub-tok")
    contributor = token!()
    member = token!()
    {:ok, _} = TAuth.create_membership(ws.id, contributor.id, "contributor", "api_token")
    {:ok, _} = TAuth.create_membership(ws.id, member.id, "member", "api_token")

    assert TAuth.publish_refused?(CallerContext.from_token(contributor), ws.id)
    refute TAuth.publish_refused?(CallerContext.from_token(member), ws.id)
  end

  test "an unresolved workspace refuses when any seat is draft-only" do
    ws = workspace!("pub-unresolved")
    user = user!()
    {:ok, _} = TAuth.create_membership(ws.id, user.id, "contributor", "user")
    ctx = CallerContext.from_user(user.id, load_grants: false)

    assert TAuth.publish_refused?(ctx, :shared_only)
    assert TAuth.publish_refused?(ctx, nil)
    assert TAuth.publish_refused?(ctx, "not-a-uuid")
  end

  test "callers with no seat are never refused here" do
    ws = workspace!("pub-none")

    refute TAuth.publish_refused?(CallerContext.anonymous(), ws.id)
    refute TAuth.publish_refused?(nil, ws.id)
    refute TAuth.publish_refused?(CallerContext.from_user(user!().id, load_grants: false), ws.id)
  end

  test "seat_capabilities reports write without publish for a contributor" do
    ws = workspace!("pub-caps")
    user = user!()
    {:ok, row} = TAuth.create_membership(ws.id, user.id, "contributor", "user")

    assert TAuth.seat_capabilities(user, row, ws.id) == %{
             read: true,
             write: true,
             publish: false,
             admin: false
           }

    assert TAuth.authorize(user, ws.id, :write) == :ok
    refute TAuth.workspace_admin?(user, ws.id)
  end
end
