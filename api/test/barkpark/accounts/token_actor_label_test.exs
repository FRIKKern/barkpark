defmodule Barkpark.Accounts.TokenActorLabelTest do
  @moduledoc """
  A history row written with an app token names the person who owns the token
  (task-d0c6a847e2a4658e). `GET /v1/data/history` returned `actor_label: null`
  for every `api_token` row, so a Studio could name an editor only by listing
  tokens with an admin token. The label is resolved at READ time from the
  owner's account, as a signed-in user's row already is — no email at rest, and
  an erased owner shows the pseudonymised email.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Accounts.Privacy

  defp owned_token(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: "a-long-enough-password-1"})
    raw = "token-actor-#{System.unique_integer([:positive])}"
    {:ok, token} = Auth.create_token(raw, "editor app token", "test", ["read", "write"])
    {:ok, token} = token |> Ecto.Changeset.change(owner_user_id: user.id) |> Repo.update()
    {user, token}
  end

  defp row(token_id), do: %{actor_kind: "api_token", actor_id: token_id, actor_label: nil}

  test "an owned app token's row names its owner" do
    email = "editor-#{System.unique_integer([:positive])}@example.com"
    {_user, token} = owned_token(email)

    assert [%{actor_label: ^email, actor_kind: "api_token"}] =
             Privacy.redact_actor_labels([row(token.id)])
  end

  test "a token with no owner stays unlabelled" do
    {:ok, token} =
      Auth.create_token("service-#{System.unique_integer([:positive])}", "svc", "test", ["read"])

    assert [%{actor_label: nil}] = Privacy.redact_actor_labels([row(token.id)])
  end

  test "an erased owner shows the pseudonymised email" do
    email = "gone-#{System.unique_integer([:positive])}@example.com"
    {user, token} = owned_token(email)
    {:ok, _} = Privacy.erase_subject(user)

    [%{actor_label: label}] = Privacy.redact_actor_labels([row(token.id)])
    assert is_binary(label) and label != email
  end
end
