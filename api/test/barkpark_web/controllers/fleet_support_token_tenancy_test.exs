defmodule BarkparkWeb.FleetSupportTokenTenancyTest do
  @moduledoc """
  Gyldendal field report — the last Class A remnant `#12826` did not reach.

  `POST /v1/fleet/support-tokens` rode `[:api, :require_admin]`. `:api` runs
  `AssignDefaultScope`, which stamps `current_workspace = <seeded Default>`
  BEFORE the admin gate, and `create/2` binds the MINTED CREDENTIAL to that
  assign. So a tenant admin whose only membership was workspace A minted a live,
  write-capable token bound to the seeded Default — plus a `member` row in
  Default, because `Auth.create_token/5` writes the membership alongside the
  token — and that token could then read Default's content. A durable credential
  manufactured inside a workspace the caller was never a member of.

  The fix repoints the scope onto `:flat_admin_api`, the flat admin pipeline
  whose whole reason to exist is ordering `DeriveWorkspaceFromToken` BEFORE
  `AssignDefaultScope` ("Adding a flat admin surface? Mount it HERE").

  MUTATION-PROOF, run, with the output recorded here so the merge carries it.
  Revert ONLY `pipe_through(:flat_admin_api)` back to
  `pipe_through([:api, :require_admin])` on the `/v1/fleet/support-tokens`
  scope → 2 failures here, while the six tests of the OTHER half of this fix
  (`BarkparkWeb.Plugs.ScopedApiSessionCredentialTest`, run in the same
  invocation: "9 tests, 2 failures") stay green:

      1) test the minted token is bound to the CALLER's workspace, never the seeded Default
         code:  assert minted.workspace_id == tenant.id
         left:  "e1c1316c-…"   # the seeded Default's id
         right: "2044712c-…"   # the caller's own workspace
      2) test the mint inserts NO membership row in Default for a caller who is not a member there
         code: assert MapSet.equal?(before_default, after_default)

  Restore → green. The existing `FleetSupportTokenControllerTest` (whose actors
  carry NO `workspace_id`, so they legitimately fall back to Default) stays
  green in both states, which is exactly why it never caught this.
  """
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query
  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Membership

  setup do
    {default_ws, _project} = ensure_default_scope!()
    tenant = create_workspace!()
    {:ok, default_ws: default_ws, tenant: tenant}
  end

  # An admin whose ONLY membership is `ws` — `create_token/5`'s 5th arg is
  # load-bearing: passing nil would bind to Default and the test would pass for
  # the wrong reason.
  defp tenant_admin_token!(ws) do
    raw = "tok-fleet-" <> Ecto.UUID.generate()

    {:ok, _} =
      Auth.create_token(
        raw,
        "fleet-tenancy-actor",
        "production",
        ["read", "write", "admin"],
        ws.id
      )

    raw
  end

  defp mint(conn, raw, name) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> post("/v1/fleet/support-tokens", Jason.encode!(%{name: name}))
  end

  defp memberships_in(workspace_id),
    do: Repo.all(from(m in Membership, where: m.workspace_id == ^workspace_id))

  test "the minted token is bound to the CALLER's workspace, never the seeded Default", %{
    conn: conn,
    default_ws: default_ws,
    tenant: tenant
  } do
    raw = tenant_admin_token!(tenant)

    %{"token_id" => token_id} = conn |> mint(raw, "ascprobe") |> json_response(201)

    minted = Repo.get!(ApiToken, token_id)

    assert minted.workspace_id == tenant.id
    refute minted.workspace_id == default_ws.id
  end

  test "the mint inserts NO membership row in Default for a caller who is not a member there", %{
    conn: conn,
    default_ws: default_ws,
    tenant: tenant
  } do
    raw = tenant_admin_token!(tenant)
    before_default = memberships_in(default_ws.id) |> Enum.map(& &1.principal_id) |> MapSet.new()

    %{"token_id" => token_id} = conn |> mint(raw, "ascprobe2") |> json_response(201)

    after_default = memberships_in(default_ws.id) |> Enum.map(& &1.principal_id) |> MapSet.new()

    # Nothing new landed in Default at all, and specifically not the minted
    # credential — the row it DOES get belongs in the minter's own workspace.
    assert MapSet.equal?(before_default, after_default)
    refute MapSet.member?(after_default, token_id)

    assert token_id in (memberships_in(tenant.id) |> Enum.map(& &1.principal_id))
  end

  test "a token with NO workspace_id still falls back to Default — no regression", %{
    conn: conn,
    default_ws: default_ws
  } do
    raw = "tok-fleet-nilws-" <> Ecto.UUID.generate()

    {:ok, _} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "fleet-nil-ws-actor",
        dataset: "production",
        permissions: ["read", "write", "admin"],
        workspace_id: nil
      })
      |> Repo.insert()

    %{"token_id" => token_id} = conn |> mint(raw, "legacy") |> json_response(201)

    assert Repo.get!(ApiToken, token_id).workspace_id == Tenancy.get_default_workspace().id
    assert default_ws.id == Tenancy.get_default_workspace().id
  end
end
