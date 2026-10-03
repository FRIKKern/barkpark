defmodule BarkparkWeb.ElevatedTokenMintTest do
  @moduledoc """
  `POST /w/:ws/p/:proj/v1/tokens/elevated` — the admin-to-admin mint
  (task-7d4d405e0ee4bcbf, criterion 0).

  Only a token that already holds the flat `admin` permission AND an admin
  seat in the workspace may mint a `write`/`admin` token there; the minted set
  never exceeds the caller's own. The minted token carries its
  `workspace_memberships` row (the row the guerrilla recovery had to write by
  hand), so it works on workspace-scoped routes at once, and the mint leaves a
  `token_minted` audit row with no secret in it.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @dataset "production"

  setup do
    ws = create_workspace!("elev-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    {admin_raw, admin} = seated!(ws, ["read", "write", "admin"], "admin")
    %{ws: ws, project: project, admin_raw: admin_raw, admin: admin}
  end

  defp seated!(ws, perms, role) do
    raw = "elev-#{System.unique_integer([:positive])}"

    {:ok, t} =
      Auth.create_token(raw, "seated-#{System.unique_integer([:positive])}", @dataset, perms)

    {:ok, _} = TenancyAuth.create_membership(ws.id, t.id, role, "api_token")
    {raw, t}
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp base(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/v1"

  defp mint(raw, ws, project, body),
    do: req(raw) |> post("#{base(ws, project)}/tokens/elevated", Jason.encode!(body))

  defp error(resp), do: Jason.decode!(resp.resp_body)["error"]

  defp labelled(label), do: Repo.aggregate(from(t in ApiToken, where: t.label == ^label), :count)

  defp seats(token_id) do
    Repo.all(
      from m in Membership,
        where: m.principal_type == "api_token" and m.principal_id == ^token_id,
        select: {m.workspace_id, m.role}
    )
  end

  describe "who may mint" do
    test "a write token with an admin seat is refused 403 admin_required, and nothing is minted",
         %{ws: ws, project: project} do
      {raw, _} = seated!(ws, ["read", "write"], "admin")

      resp = mint(raw, ws, project, %{label: "from-write", permissions: ["read", "write"]})

      assert resp.status == 403
      assert error(resp)["code"] == "forbidden"
      assert error(resp)["reason"] == "admin_required"
      assert error(resp)["hint"] =~ "bp instance admin-token"
      assert labelled("from-write") == 0
    end

    test "a read token with an admin seat is refused 403 admin_required", %{
      ws: ws,
      project: project
    } do
      {raw, _} = seated!(ws, ["read"], "admin")

      resp = mint(raw, ws, project, %{label: "from-read", permissions: ["read"]})

      assert resp.status == 403
      assert error(resp)["reason"] == "admin_required"
      assert labelled("from-read") == 0
    end

    test "a flat-admin token that is only a MEMBER of the workspace is refused 403",
         %{ws: ws, project: project} do
      {raw, _} = seated!(ws, ["read", "write", "admin"], "member")

      resp =
        mint(raw, ws, project, %{label: "from-member", permissions: ["read", "write", "admin"]})

      assert resp.status == 403
      assert labelled("from-member") == 0
    end

    test "asking for a permission the caller lacks is refused 403 permission_escalation",
         %{ws: ws, project: project} do
      {raw, _} = seated!(ws, ["read", "admin"], "admin")

      resp = mint(raw, ws, project, %{label: "escalate", permissions: ["read", "write", "admin"]})

      assert resp.status == 403
      assert error(resp)["reason"] == "permission_escalation"
      assert error(resp)["message"] =~ ~s("write")
      assert labelled("escalate") == 0
    end

    test "a permission outside read/write/admin is a 422", ctx do
      resp = mint(ctx.admin_raw, ctx.ws, ctx.project, %{label: "ops", permissions: ["ops"]})
      assert resp.status == 422
      assert labelled("ops") == 0
    end

    test "a missing label is a 422", ctx do
      resp = mint(ctx.admin_raw, ctx.ws, ctx.project, %{permissions: ["read", "write", "admin"]})
      assert resp.status == 422
      assert error(resp)["message"] =~ "label"
    end
  end

  describe "what an admin mints" do
    test "an admin token mints an admin token that is seated and works on scoped routes", ctx do
      resp =
        mint(ctx.admin_raw, ctx.ws, ctx.project, %{
          label: "restored-admin",
          permissions: ["read", "write", "admin"]
        })

      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)
      assert body["permissions"] == ["read", "write", "admin"]
      assert body["workspace"] == ctx.ws.slug
      raw = body["token"]
      assert is_binary(raw) and raw != ""

      # The membership row the hand-written SQL had to add after the fact.
      assert seats(body["id"]) == [{ctx.ws.id, "admin"}]

      # Admin on a workspace-scoped route: register a task schema.
      schema =
        req(raw)
        |> post(
          "#{base(ctx.ws, ctx.project)}/schemas/#{@dataset}",
          Jason.encode!(%{name: "task", title: "Task", visibility: "private", fields: []})
        )

      assert schema.status == 201, schema.resp_body

      # Write on a workspace-scoped route: create a task document.
      created =
        req(raw)
        |> post(
          "#{base(ctx.ws, ctx.project)}/data/mutate/#{@dataset}",
          Jason.encode!(%{
            mutations: [
              %{
                create: %{
                  _id: "restored-1",
                  _type: "task",
                  title: "made by the minted token",
                  kind: "task",
                  lifecycle_status: "open"
                }
              }
            ]
          })
        )

      assert created.status == 200, created.resp_body
    end

    test "the mint writes a token_minted audit row with the actor and no secret", ctx do
      resp =
        mint(ctx.admin_raw, ctx.ws, ctx.project, %{
          label: "audited",
          permissions: ["read", "write"]
        })

      assert resp.status == 201
      %{"id" => id, "token" => raw} = Jason.decode!(resp.resp_body)

      [event] =
        Repo.all(
          from e in Barkpark.Audit.Event,
            where: e.action == "token_minted" and e.subject == ^id
        )

      assert event.category == "token"
      assert event.actor_id == ctx.admin.id
      assert event.workspace_id == ctx.ws.id
      assert event.metadata["permissions"] == ["read", "write"]
      refute inspect(event) =~ raw
      refute inspect(event) =~ ApiToken.hash_token(raw)
    end

    test "--no-expiry mints a token with no expires_at and records the opt-out", ctx do
      resp =
        mint(ctx.admin_raw, ctx.ws, ctx.project, %{
          label: "forever",
          permissions: ["read", "write", "admin"],
          no_expiry: true
        })

      assert resp.status == 201
      %{"id" => id, "expires_at" => nil} = Jason.decode!(resp.resp_body)

      assert Repo.exists?(
               from e in Barkpark.Audit.Event,
                 where: e.action == "token_no_expiry_opt_out" and e.subject == ^id
             )
    end

    test "an expires_at in the future is stored as given", ctx do
      at = DateTime.utc_now() |> DateTime.add(30 * 86_400, :second) |> DateTime.truncate(:second)

      resp =
        mint(ctx.admin_raw, ctx.ws, ctx.project, %{
          label: "thirty-days",
          permissions: ["read", "write", "admin"],
          expires_at: DateTime.to_iso8601(at)
        })

      assert resp.status == 201
      {:ok, got, _} = DateTime.from_iso8601(Jason.decode!(resp.resp_body)["expires_at"])
      assert DateTime.diff(got, at, :second) |> abs() <= 1
    end
  end

  describe "the read-only mint is unchanged" do
    test "POST …/v1/tokens still refuses write/admin, even for an admin caller", ctx do
      resp =
        req(ctx.admin_raw)
        |> post(
          "#{base(ctx.ws, ctx.project)}/tokens",
          Jason.encode!(%{label: "via-read-mint", permissions: ["read", "admin"]})
        )

      assert resp.status == 422
      assert labelled("via-read-mint") == 0
    end
  end
end
