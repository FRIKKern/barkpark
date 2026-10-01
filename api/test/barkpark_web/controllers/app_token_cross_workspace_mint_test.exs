defmodule BarkparkWeb.AppTokenCrossWorkspaceMintTest do
  @moduledoc """
  `task-a5c90e1a783555da` — `POST /v1/auth/app-tokens` must not mint into a
  workspace the WORKSPACE-BOUND bearer does not administer.

  The mint checked only `Auth.has_permission?(bearer, "admin")` and then took
  any workspace slug/id from the body, so an admin token bound to workspace B
  minted a member token into workspace A and JIT-seated an arbitrary email
  there. Its revoke and list siblings were already confined through
  `Auth.administrable_by?` -> `Tenancy.Auth.workspace_admin?/2`; the mint now
  uses the same predicate for a bearer bound to a NON-Default workspace. The
  instance-level admin bearers — unbound, or bound to the seeded Default
  workspace (the Cloud control plane's stored per-instance credential, which the
  mint and token-expiry suites exercise) — keep minting where they name.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.RateLimiterSandbox
  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Accounts, Auth, Repo}
  alias Barkpark.Auth.ApiToken

  @dataset "production"

  setup :reset_rate_limiter!

  setup do
    ws_a = create_workspace!()
    ws_b = create_workspace!()
    admin_b = "adm-b-#{System.unique_integer([:positive])}"

    {:ok, _} = Auth.create_token(admin_b, "adm-b", @dataset, ["read", "write", "admin"], ws_b.id)

    %{ws_a: ws_a, ws_b: ws_b, admin_b: admin_b}
  end

  defp mint(bearer, body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{bearer}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/auth/app-tokens", body)
  end

  defp email, do: "mint-victim-#{System.unique_integer([:positive])}@example.com"

  defp tokens_in(ws_id),
    do: Repo.all(from(t in ApiToken, where: t.workspace_id == ^ws_id and like(t.label, "app:%")))

  test "an admin token bound to B cannot mint into A, and seats nobody there",
       %{ws_a: ws_a, admin_b: admin_b} do
    mail = email()
    conn = mint(admin_b, %{email: mail, workspace: ws_a.slug})

    assert conn.status == 422, conn.resp_body
    assert tokens_in(ws_a.id) == []
    assert Accounts.get_user_by_email(mail) == nil
  end

  test "the same bearer still mints into the workspace it administers (positive control)",
       %{ws_b: ws_b, admin_b: admin_b} do
    conn = mint(admin_b, %{email: email(), workspace: ws_b.slug})

    assert conn.status == 201, conn.resp_body
    assert Jason.decode!(conn.resp_body)["workspace_id"] == ws_b.id
  end
end
