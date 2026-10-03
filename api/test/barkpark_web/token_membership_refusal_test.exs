defmodule BarkparkWeb.TokenMembershipRefusalTest do
  @moduledoc """
  task-7d4d405e0ee4bcbf, criterion 3.

  1. A token with permissions but no seat in the URL's workspace gets a 403
     that NAMES the workspace, says the token has no membership there, and
     says how to get a seated token. `code`/`status`/`reason` stay
     `forbidden`/403/`not_a_member`, so a client keying on them is unchanged.
     This is the state the guerrilla admin credential was in after its
     `api_tokens` row was inserted by hand.
  2. `GET /v1/tokens/current` lets a token see its own seats (what
     `bp whoami -o json` prints as `memberships`).
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  setup do
    ws = create_workspace!("seatless-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    %{ws: ws, project: project}
  end

  defp token!(perms) do
    raw = "seat-#{System.unique_integer([:positive])}"

    {:ok, t} =
      Auth.create_token(raw, "seat-#{System.unique_integer([:positive])}", "production", perms)

    {raw, t}
  end

  defp get_as(raw, path),
    do: scoped_conn() |> put_req_header("authorization", "Bearer #{raw}") |> get(path)

  describe "the not_a_member 403 for a token" do
    test "names the workspace, says the token has no seat there, and how to get one", ctx do
      # Flat admin, no membership row: the hand-inserted credential's state.
      {raw, _} = token!(["read", "write", "admin"])

      resp = get_as(raw, "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/query/production/post")

      assert resp.status == 403
      err = Jason.decode!(resp.resp_body)["error"]
      assert err["code"] == "forbidden"
      assert err["reason"] == "not_a_member"
      assert err["message"] == ~s(this token has no membership in workspace "#{ctx.ws.slug}")
      assert err["hint"] =~ "bp token create"
      assert err["hint"] =~ ctx.ws.slug
    end

    test "a seated token is admitted, so the arm fires only on a missing seat", ctx do
      {raw, t} = token!(["read"])
      {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, t.id, "member", "api_token")

      resp = get_as(raw, "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/query/production/post")

      refute resp.status in [401, 403]
    end
  end

  describe "GET /v1/tokens/current" do
    test "lists the token's seats with workspace id, slug and role", ctx do
      {raw, t} = token!(["read", "write", "admin"])
      {:ok, _} = TenancyAuth.create_membership(ctx.ws.id, t.id, "admin", "api_token")

      resp = get_as(raw, "/v1/tokens/current")

      assert resp.status == 200
      body = Jason.decode!(resp.resp_body)
      assert body["token"]["id"] == t.id
      assert body["token"]["permissions"] == ["read", "write", "admin"]
      refute Map.has_key?(body["token"], "token_hash")

      assert body["memberships"] == [
               %{"workspace_id" => ctx.ws.id, "workspace_slug" => ctx.ws.slug, "role" => "admin"}
             ]
    end

    test "a token with no seat answers an empty list, not an error" do
      {raw, _} = token!(["read"])

      resp = get_as(raw, "/v1/tokens/current")

      assert resp.status == 200
      assert Jason.decode!(resp.resp_body)["memberships"] == []
    end

    test "needs a token" do
      assert scoped_conn() |> get("/v1/tokens/current") |> Map.fetch!(:status) == 401
    end
  end
end
