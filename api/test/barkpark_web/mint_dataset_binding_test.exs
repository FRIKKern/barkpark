defmodule BarkparkWeb.MintDatasetBindingTest do
  @moduledoc """
  A token minted by a dataset-bound token inherits the binding
  (`Barkpark.Auth.inherit_dataset_binding/3`). The bound minter may mint a
  token bound to its own dataset. A request that names another dataset is
  refused. An unbound admin token mints as before.

  The elevated mint is tested over HTTP. The other mint paths are tested at
  the function that owns the rule.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.{Access, Auth, Repo}
  alias Barkpark.Auth.{ApiToken, TokenSeatRestore}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @own "mdb-own"
  @other "mdb-other"

  setup do
    ws = create_workspace!("mdb-#{System.unique_integer([:positive])}")
    project = create_project!(ws)
    {bound_raw, bound} = admin!(ws, @own, true)
    {unbound_raw, unbound} = admin!(ws, "production", nil)

    %{
      ws: ws,
      project: project,
      bound_raw: bound_raw,
      bound: bound,
      unbound_raw: unbound_raw,
      unbound: unbound
    }
  end

  defp admin!(ws, dataset, dataset_bound) do
    raw = "mdb-#{System.unique_integer([:positive])}"

    {:ok, t} =
      Auth.create_token(
        raw,
        "mdb-admin-#{System.unique_integer([:positive])}",
        dataset,
        [
          "read",
          "write",
          "admin"
        ],
        nil,
        dataset_bound: dataset_bound
      )

    {:ok, _} = TenancyAuth.create_membership(ws.id, t.id, "admin", "api_token")
    {raw, t}
  end

  defp elevated(raw, ws, project, body) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
    |> post("/w/#{ws.slug}/p/#{project.slug}/v1/tokens/elevated", Jason.encode!(body))
  end

  defp labelled(label), do: Repo.one(from t in ApiToken, where: t.label == ^label)

  describe "POST /v1/tokens/elevated" do
    test "a bound token minting without a dataset gets a token bound to its dataset", ctx do
      resp =
        elevated(ctx.bound_raw, ctx.ws, ctx.project, %{
          label: "mdb-inherit",
          permissions: ["read"]
        })

      assert resp.status == 201, resp.resp_body
      assert Jason.decode!(resp.resp_body)["dataset"] == @own
      assert %ApiToken{dataset: @own, dataset_bound: true} = labelled("mdb-inherit")
    end

    test "a bound token may mint a token bound to the same dataset", ctx do
      resp =
        elevated(ctx.bound_raw, ctx.ws, ctx.project, %{
          label: "mdb-same",
          permissions: ["read", "write"],
          dataset: @own
        })

      assert resp.status == 201, resp.resp_body
      assert %ApiToken{dataset: @own, dataset_bound: true} = labelled("mdb-same")
    end

    test "a bound token cannot mint a token bound to another dataset", ctx do
      resp =
        elevated(ctx.bound_raw, ctx.ws, ctx.project, %{
          label: "mdb-other",
          permissions: ["read"],
          dataset: @other
        })

      assert resp.status == 403, resp.resp_body
      assert labelled("mdb-other") == nil
    end

    test "an unbound admin token still mints an unbound token", ctx do
      resp =
        elevated(ctx.unbound_raw, ctx.ws, ctx.project, %{
          label: "mdb-unbound",
          permissions: ["read", "write", "admin"]
        })

      assert resp.status == 201, resp.resp_body
      assert %ApiToken{dataset: "production", dataset_bound: nil} = labelled("mdb-unbound")
    end

    test "an unbound admin token still mints a token bound to a named dataset", ctx do
      resp =
        elevated(ctx.unbound_raw, ctx.ws, ctx.project, %{
          label: "mdb-unbound-named",
          permissions: ["read"],
          dataset: @other
        })

      assert resp.status == 201, resp.resp_body
      assert %ApiToken{dataset: @other, dataset_bound: true} = labelled("mdb-unbound-named")
    end
  end

  # The read-tier mint recorded the named dataset and did not bind the token,
  # so "a read token for staging" read every dataset of its workspace.
  describe "POST /v1/tokens (read tier)" do
    defp read_mint(raw, ws, project, body) do
      scoped_conn()
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("content-type", "application/json")
      |> post("/w/#{ws.slug}/p/#{project.slug}/v1/tokens", Jason.encode!(body))
    end

    # No schema is seeded, so an admitted read is a 404 for the type. The
    # binding's refusal is the 403.
    defp refused?(raw, ws, project, dataset) do
      resp =
        scoped_conn()
        |> put_req_header("authorization", "Bearer #{raw}")
        |> get("/w/#{ws.slug}/p/#{project.slug}/v1/data/query/#{dataset}/post")

      resp.status == 403 and resp.resp_body =~ "dataset_not_bound"
    end

    test "a mint that names a dataset is bound to it, and refused on another", ctx do
      resp =
        read_mint(ctx.unbound_raw, ctx.ws, ctx.project, %{
          label: "mdb-read-named",
          permissions: ["read"],
          dataset: @other
        })

      assert resp.status == 201, resp.resp_body
      assert %ApiToken{dataset: @other, dataset_bound: true} = labelled("mdb-read-named")

      minted = Jason.decode!(resp.resp_body)["token"]
      refute refused?(minted, ctx.ws, ctx.project, @other)
      assert refused?(minted, ctx.ws, ctx.project, @own)
    end

    test "a mint that names no dataset stays unbound and reads both (control)", ctx do
      resp =
        read_mint(ctx.unbound_raw, ctx.ws, ctx.project, %{
          label: "mdb-read-unnamed",
          permissions: ["read"]
        })

      assert resp.status == 201, resp.resp_body
      assert %ApiToken{dataset: "production", dataset_bound: nil} = labelled("mdb-read-unnamed")

      minted = Jason.decode!(resp.resp_body)["token"]
      refute refused?(minted, ctx.ws, ctx.project, @other)
      refute refused?(minted, ctx.ws, ctx.project, @own)
    end
  end

  describe "Auth.mint_delegated_token/3" do
    test "refuses a bound actor naming another dataset, and mints nothing", ctx do
      assert {:error, :dataset_binding} =
               Auth.mint_delegated_token(ctx.bound, ctx.ws.id,
                 label: "mdb-fn-other",
                 permissions: ["read"],
                 dataset: @other,
                 dataset_bound: true
               )

      assert labelled("mdb-fn-other") == nil
    end

    test "binds the token of a bound actor that names no dataset", ctx do
      assert {:ok, {_raw, token}} =
               Auth.mint_delegated_token(ctx.bound, ctx.ws.id,
                 label: "mdb-fn-default",
                 permissions: ["read"]
               )

      assert {token.dataset, token.dataset_bound} == {@own, true}
    end
  end

  describe "the other mint paths" do
    test "create_token/6 with a bound actor inherits or refuses", ctx do
      assert {:ok, %ApiToken{dataset: @own, dataset_bound: true}} =
               Auth.create_token("mdb-ct-1", "mdb-ct-1", "production", ["read"], ctx.ws.id,
                 actor: ctx.bound
               )

      assert {:error, :dataset_binding} =
               Auth.create_token("mdb-ct-2", "mdb-ct-2", @other, ["read"], ctx.ws.id,
                 actor: ctx.bound,
                 dataset_bound: true
               )

      assert {:ok, %ApiToken{dataset: "production", dataset_bound: nil}} =
               Auth.create_token("mdb-ct-3", "mdb-ct-3", "production", ["read"], ctx.ws.id,
                 actor: ctx.unbound
               )
    end

    test "a chat token minted by a bound token is bound", ctx do
      assert {:ok, _raw, %ApiToken{dataset: @own, dataset_bound: true}} =
               Auth.create_chat_token("mdb-chat", "production", ctx.ws.id, ctx.bound)
    end

    test "a Claude session token minted by a bound token is bound", ctx do
      assert {:ok, {_raw, %ApiToken{dataset: @own, dataset_bound: true}}} =
               Auth.create_claude_session_token(ctx.bound, "mdb-sid", workspace_id: ctx.ws.id)

      assert {:error, :dataset_binding} =
               Auth.create_claude_session_token(ctx.bound, "mdb-sid-2",
                 workspace_id: ctx.ws.id,
                 dataset: @other
               )
    end

    test "a bound token rotates only tokens bound to its dataset", ctx do
      {:ok, unbound_child} =
        Auth.create_token("mdb-rot-1", "mdb-rot-1", "production", ["read"], ctx.ws.id)

      {:ok, bound_child} =
        Auth.create_token("mdb-rot-2", "mdb-rot-2", @own, ["read"], ctx.ws.id,
          dataset_bound: true
        )

      assert {:error, :forbidden} = Auth.rotate_token(unbound_child.id, ctx.bound)
      assert {:ok, {_raw, successor, _old}} = Auth.rotate_token(bound_child.id, ctx.bound)
      assert {successor.dataset, successor.dataset_bound} == {@own, true}
    end

    test "a grant minted by a bound token covers its dataset only", ctx do
      attrs = %{workspace_id: ctx.ws.id, grantee_email: "mdb@example.com", capabilities: ["read"]}

      assert {:ok, %{grant: grant}} = Access.mint(ctx.bound, attrs)
      assert grant.dataset == @own

      assert {:error, :dataset_binding} = Access.mint(ctx.bound, Map.put(attrs, :dataset, @other))

      assert {:ok, %{grant: unbound_grant}} = Access.mint(ctx.unbound, attrs)
      assert unbound_grant.dataset == nil
    end

    test "a bound caller cannot restore seats on a token outside its binding", ctx do
      assert {:error, :dataset_binding} =
               TokenSeatRestore.restore(ctx.unbound.id, [], actor: ctx.bound)

      assert {:ok, _plan} = TokenSeatRestore.restore(ctx.bound.id, [], actor: ctx.unbound)
    end
  end
end
