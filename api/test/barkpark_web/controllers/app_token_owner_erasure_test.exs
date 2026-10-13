defmodule BarkparkWeb.AppTokenOwnerErasureTest do
  @moduledoc """
  Owner ruling #32 item 3 (2026-10-03, task-43179d8d03efe969): an app token
  minted FOR a user (`POST /v1/auth/app-tokens`, label `app:<email>`) is that
  user's credential, so erasing the user revokes it.

  The mint used to record no `owner_user_id`, and `Privacy.erase_subject/1`
  revokes only tokens the subject owns — so a phone session stayed live after
  its user was erased, under a label that still carried the email. The mint now
  stamps `owner_user_id` (the user keeps the member seat the mint JIT-creates,
  so the token keeps working while the user exists). Erasure revokes it, also
  revokes LEGACY tokens minted before this change (label `app:<email>`, no
  owner), and rewrites those labels to the pseudonym.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Accounts.Privacy
  alias Barkpark.Auth.ApiToken

  @dataset "production"

  setup do
    admin = "app-owner-admin-#{System.unique_integer([:positive])}"

    {:ok, _} =
      Auth.create_token(
        admin,
        "app-owner-admin",
        @dataset,
        ["read", "write", "admin"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    %{admin: admin, email: "app-owner-#{System.unique_integer([:positive])}@example.com"}
  end

  defp as(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp mint!(admin, email) do
    as(admin)
    |> post("/v1/auth/app-tokens", Jason.encode!(%{email: email}))
    |> json_response(201)
    |> Map.fetch!("token")
  end

  test "the mint records the user as owner, and the token works for that user", ctx do
    raw = mint!(ctx.admin, ctx.email)
    user = Accounts.get_user_by_email(ctx.email)

    assert {:ok, token} = Auth.verify_token(raw)
    assert token.owner_user_id == user.id

    # The legitimate path: the minted token reads and writes as a member.
    assert as(raw) |> get("/v1/data/query/#{@dataset}/post") |> Map.get(:status) == 200

    create =
      as(raw)
      |> post(
        "/v1/data/mutate/#{@dataset}",
        Jason.encode!(%{
          mutations: [
            %{
              create: %{
                _id: "drafts.app-owner-#{System.unique_integer([:positive])}",
                _type: "post",
                title: "hi"
              }
            }
          ]
        })
      )

    assert create.status in [200, 201], "the app token could not write: #{create.resp_body}"
  end

  test "erasing the user revokes the app token minted for them", ctx do
    raw = mint!(ctx.admin, ctx.email)
    assert {:ok, _} = Auth.verify_token(raw)

    {:ok, _} = Privacy.erase_subject(Accounts.get_user_by_email(ctx.email))

    assert match?({:error, _}, Auth.verify_token(raw)),
           "the erased user's app token still verifies"

    row = Repo.get_by!(ApiToken, token_hash: ApiToken.hash_token(raw))
    refute is_nil(row.revoked_at)
    refute row.label =~ ctx.email, "the revoked token's label still carries the email"
  end

  test "a LEGACY app token (label app:<email>, no owner) is revoked by erasure too", ctx do
    {:ok, user} = Accounts.register_user(%{email: ctx.email, password: "correct-horse-battery"})
    legacy_raw = "bpapp_legacy_#{System.unique_integer([:positive])}"

    {:ok, legacy} =
      Auth.create_token(
        legacy_raw,
        "app:" <> ctx.email,
        @dataset,
        ["read"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    assert is_nil(legacy.owner_user_id)

    # A workspace machine token the user merely created is the workspace's.
    machine_raw = "machine-#{System.unique_integer([:positive])}"

    {:ok, machine} =
      Auth.create_token(
        machine_raw,
        "ci deploy",
        @dataset,
        ["read"],
        Barkpark.TenancyFixtures.default_workspace_id!()
      )

    {:ok, _} = machine |> Ecto.Changeset.change(created_by: ctx.email) |> Repo.update()

    {:ok, _} = Privacy.erase_subject(user)

    refute is_nil(Repo.get!(ApiToken, legacy.id).revoked_at)
    refute Repo.get!(ApiToken, legacy.id).label =~ ctx.email
    assert {:ok, _} = Auth.verify_token(machine_raw)
  end
end
