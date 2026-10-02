defmodule BarkparkWeb.ScimBodyListBoundTest do
  @moduledoc """
  ROUTE-DRIVEN guard for the two REQUEST-BODY list ceilings in the SCIM
  controllers: the PATCH `Operations` array (RFC 7644 §3.5.2) and the `/Groups`
  `members` array (RFC 7643 §4.2).

  The numeric QUERY parameters were bounded both ends by the `startIndex` work
  (`scim_start_index_bound_test.exs`), but the two body LIST LENGTHS were
  bounded at neither end: a SCIM bearer could send an arbitrarily long
  `Operations` list — each element walked by `ScimPatch.classify/1` and again by
  `ScimUsersController.deactivating?/1` — or an arbitrarily long `members` list,
  each element of which is resolved individually by `Scim.add_group_member/3`.

  These tests drive the ROUTE. `classify/1`'s bound is observable through
  `ScimPatch.max_operations/0` and `ScimPatch.max_members/0` so the ceiling is
  named rather than hard-coded here; the OVER case is `ceiling + 1` and the
  POSITIVE CONTROL is exactly `ceiling`, so the cap cannot be satisfied by a
  refusal that refuses everything.

  Every member id below is deliberately NOT uuid-shaped: `Scim.add_group_member/3`
  short-circuits on `Repo.uuid_or_nil/1` before it issues any query, so a
  ceiling-sized positive control costs no database round trips and still proves
  the request was ACCEPTED rather than refused.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Scim, Tenancy}
  alias BarkparkWeb.ScimPatch

  @max_ops ScimPatch.max_operations()
  @max_members ScimPatch.max_members()

  defp org_with_ws(slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: slug, name: slug})
    {:ok, ws} = Tenancy.create_workspace(%{slug: slug <> "-ws", name: "WS"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, {token, _}} = Scim.mint_token(org.id, "test")
    %{org: org, ws: ws, token: token}
  end

  defp scim(token) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp provision(token, email),
    do:
      scim(token)
      |> post("/scim/v2/Users", Jason.encode!(%{"userName" => email}))
      |> json_response(201)

  defp create_group(token, name, role),
    do:
      scim(token)
      |> post("/scim/v2/Groups", Jason.encode!(%{"displayName" => name, "role" => role}))
      |> json_response(201)

  # `n` path-less `replace` operations. Path-less is the cheapest legal shape:
  # `classify/1` merges each `value` into the whole-resource map, so the cost of
  # the positive control is the walk itself, not N writes.
  defp ops(n), do: for(i <- 1..n, do: %{"op" => "replace", "value" => %{"nickName" => "n#{i}"}})

  defp members(n), do: for(i <- 1..n, do: %{"value" => "not-a-uuid-#{i}"})

  # Every refusal in this file must be the SAME SCIM error: 400 with scimType
  # `invalidValue`. RFC 7644 §3.12 Table 9 scopes every scimType keyword to 400,
  # and lists `invalidValue` against POST (Create §3.3), PUT (§3.5.1) and PATCH
  # (§3.5.2) — the exact three verbs these ceilings guard.
  defp assert_refused(body) do
    assert body["status"] == "400"
    assert body["scimType"] == "invalidValue"
    assert body["schemas"] == ["urn:ietf:params:scim:api:messages:2.0:Error"]
    body
  end

  describe "PATCH Operations ceiling" do
    setup do
      ctx = org_with_ws("scim-oplimit-#{System.unique_integer([:positive])}")
      user = provision(ctx.token, "ops#{System.unique_integer([:positive])}@example.com")
      Map.put(ctx, :user, user)
    end

    test "PATCH /Users refuses an Operations array above the ceiling", ctx do
      body =
        scim(ctx.token)
        |> patch(
          "/scim/v2/Users/#{ctx.user["id"]}",
          Jason.encode!(%{"Operations" => ops(@max_ops + 1)})
        )
        |> json_response(400)
        |> assert_refused()

      assert body["detail"] =~ "Operations"
      assert body["detail"] =~ to_string(@max_ops)
    end

    test "POSITIVE CONTROL: PATCH /Users accepts an Operations array AT the ceiling", ctx do
      body =
        scim(ctx.token)
        |> patch(
          "/scim/v2/Users/#{ctx.user["id"]}",
          Jason.encode!(%{"Operations" => ops(@max_ops)})
        )
        |> json_response(200)

      assert body["id"] == ctx.user["id"]
    end

    test "PATCH /Groups refuses an Operations array above the ceiling", ctx do
      group = create_group(ctx.token, "Ops#{System.unique_integer([:positive])}", "admin")

      scim(ctx.token)
      |> patch(
        "/scim/v2/Groups/#{group["id"]}",
        Jason.encode!(%{"Operations" => ops(@max_ops + 1)})
      )
      |> json_response(400)
      |> assert_refused()
    end

    test "POSITIVE CONTROL: PATCH /Groups accepts an Operations array AT the ceiling", ctx do
      group = create_group(ctx.token, "OpsOk#{System.unique_integer([:positive])}", "admin")

      body =
        scim(ctx.token)
        |> patch(
          "/scim/v2/Groups/#{group["id"]}",
          Jason.encode!(%{"Operations" => ops(@max_ops)})
        )
        |> json_response(200)

      assert body["id"] == group["id"]
    end
  end

  describe "Groups members ceiling" do
    setup do
      ctx = org_with_ws("scim-memlimit-#{System.unique_integer([:positive])}")
      group = create_group(ctx.token, "Mem#{System.unique_integer([:positive])}", "admin")
      Map.put(ctx, :group, group)
    end

    test "POST /Groups refuses a members array above the ceiling", ctx do
      body =
        scim(ctx.token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{
            "displayName" => "Big#{System.unique_integer([:positive])}",
            "role" => "admin",
            "members" => members(@max_members + 1)
          })
        )
        |> json_response(400)
        |> assert_refused()

      assert body["detail"] =~ "members"
      assert body["detail"] =~ to_string(@max_members)
    end

    test "POSITIVE CONTROL: POST /Groups accepts a members array AT the ceiling", ctx do
      body =
        scim(ctx.token)
        |> post(
          "/scim/v2/Groups",
          Jason.encode!(%{
            "displayName" => "BigOk#{System.unique_integer([:positive])}",
            "role" => "admin",
            "members" => members(@max_members)
          })
        )
        |> json_response(201)

      assert body["displayName"] =~ "BigOk"
    end

    test "PUT /Groups refuses a members array above the ceiling", ctx do
      scim(ctx.token)
      |> put(
        "/scim/v2/Groups/#{ctx.group["id"]}",
        Jason.encode!(%{
          "displayName" => ctx.group["displayName"],
          "members" => members(@max_members + 1)
        })
      )
      |> json_response(400)
      |> assert_refused()
    end

    test "POSITIVE CONTROL: PUT /Groups accepts a members array AT the ceiling", ctx do
      body =
        scim(ctx.token)
        |> put(
          "/scim/v2/Groups/#{ctx.group["id"]}",
          Jason.encode!(%{
            "displayName" => ctx.group["displayName"],
            "members" => members(@max_members)
          })
        )
        |> json_response(200)

      assert body["id"] == ctx.group["id"]
    end

    test "PATCH /Groups refuses a PATH-LESS replace whose members value is above the ceiling",
         ctx do
      scim(ctx.token)
      |> patch(
        "/scim/v2/Groups/#{ctx.group["id"]}",
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "replace", "value" => %{"members" => members(@max_members + 1)}}
          ]
        })
      )
      |> json_response(400)
      |> assert_refused()
    end

    test "PATCH /Groups refuses a PATH-KEYED add whose members value is above the ceiling",
         ctx do
      scim(ctx.token)
      |> patch(
        "/scim/v2/Groups/#{ctx.group["id"]}",
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "add", "path" => "members", "value" => members(@max_members + 1)}
          ]
        })
      )
      |> json_response(400)
      |> assert_refused()
    end

    test "PATCH /Groups refuses when the members are SPLIT across operations that sum above the ceiling",
         ctx do
      # A per-operation bound alone is defeatable: two operations of
      # `ceiling` each carry 2x the work one refused operation would have.
      # The bound is on the REQUEST's total member count, so this refuses.
      half = div(@max_members, 2) + 1

      scim(ctx.token)
      |> patch(
        "/scim/v2/Groups/#{ctx.group["id"]}",
        Jason.encode!(%{
          "Operations" => [
            %{"op" => "add", "path" => "members", "value" => members(half)},
            %{"op" => "add", "path" => "members", "value" => members(half)}
          ]
        })
      )
      |> json_response(400)
      |> assert_refused()
    end

    test "POSITIVE CONTROL: PATCH /Groups accepts a path-keyed add AT the ceiling", ctx do
      body =
        scim(ctx.token)
        |> patch(
          "/scim/v2/Groups/#{ctx.group["id"]}",
          Jason.encode!(%{
            "Operations" => [
              %{"op" => "add", "path" => "members", "value" => members(@max_members)}
            ]
          })
        )
        |> json_response(200)

      assert body["id"] == ctx.group["id"]
    end
  end
end
