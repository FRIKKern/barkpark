defmodule BarkparkWeb.ScopedSchemaWriteTierPinTest do
  @moduledoc """
  task-8602aee60d6e440e — PIN: scoped schema writes need `write` plus an
  owner or admin seat, NOT the `admin` permission.

  Ruled on purpose (coordinator, on the owner's go-ahead). An owner or admin
  user's self-minted PAT is capped at `read`+`write` and can never carry
  `admin` (`Auth.max_pat_permissions_for_role/1`). Any token that may create
  a workspace becomes its owner (`POST /api/workspaces`), and
  `scripts/bp-vercel-quick-setup.sh` and the js SDK's `upsertSchema` then
  apply schemas there with that same token. Requiring `admin` here would
  refuse them. Scoped secrets and webhooks DO need `admin`
  (`RequireScopedAdminPermission`); schemas deliberately do not.

  If this test goes red, the tier changed: that needs a new ruling, and
  docs/auth.md's `admin` row must change with it.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  test "a read+write token on an admin seat creates and deletes a scoped schema" do
    ws = create_workspace!("schema-tier-pin-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    base = "/w/#{ws.slug}/p/#{project.slug}/v1/schemas/#{@dataset}"

    raw = "schema-tier-pin-#{System.unique_integer([:positive])}"
    {:ok, tok} = Auth.create_token(raw, "rw admin seat", @dataset, ["read", "write"])
    {:ok, seat} = TenancyAuth.create_membership(ws.id, tok.id, "admin", "api_token")
    assert seat.role == "admin"

    body =
      Jason.encode!(%{
        "name" => "post",
        "title" => "Post",
        "visibility" => "public",
        "fields" => []
      })

    upsert = post(req(raw), base, body)
    assert upsert.status == 201, "scoped schema upsert: #{upsert.status} #{upsert.resp_body}"

    removed = delete(req(raw), "#{base}/post")
    assert removed.status == 200, "scoped schema delete: #{removed.status} #{removed.resp_body}"
  end
end
