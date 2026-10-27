defmodule BarkparkWeb.ContributorPaperMasterTest do
  @moduledoc """
  task-a6307f0d04cf513d: saving a block as a paper master PUBLISHES the master
  (`Masters.save_master/4`), so a `contributor` (draft-only) seat may not do
  it. The save rebuilt its opts from the paper's scope only, dropping
  `:caller_context`, and the Studio classed `paper-save-master` as `:write`, so
  both doors let a contributor publish. A member saves as before.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Repo}
  alias Barkpark.Plugins.Bulldocs.Masters
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @dataset "production"

  @blocks [
    %{"id" => "cpm-h", "type" => "heading", "level" => 1, "text" => "Masters"},
    %{
      "id" => "cpm-sec",
      "type" => "section",
      "blocks" => [
        %{"id" => "cpm-sec-h", "type" => "heading", "level" => 2, "text" => "Pricing"},
        %{"id" => "cpm-sec-p", "type" => "paragraph", "text" => "Body copy"}
      ]
    }
  ]

  defp paper!(extra) do
    slug = "cpm-#{System.unique_integer([:positive])}"

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(
          Map.merge(%{slug: slug, dataset: @dataset, blocks: @blocks}, extra)
        )
      )

    {slug, paper}
  end

  defp refused!(conn) do
    body = json_response(conn, 403)
    assert body["error"]["reason"] == "publish_not_permitted", inspect(body)
  end

  describe "HTTP POST /v1/papers/:slug/masters" do
    setup do
      ws = create_workspace!("cpm-#{System.unique_integer([:positive])}")
      project = create_project!(ws)
      {slug, paper} = paper!(%{workspace_id: ws.id, project_id: project.id})
      %{ws: ws, project: project, slug: slug, paper: paper}
    end

    defp seated(ws, role) do
      raw = "cpm-#{role}-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "cpm #{role}", @dataset, ["read", "write"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role, "api_token")
      raw
    end

    defp save(raw, ws, project, slug) do
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post("/w/#{ws.slug}/p/#{project.slug}/v1/papers/#{slug}/masters", %{
        "blockId" => "cpm-sec"
      })
    end

    test "a contributor is refused and no master (draft or published) is left", ctx do
      refused!(save(seated(ctx.ws, "contributor"), ctx.ws, ctx.project, ctx.slug))
      assert Masters.list_for_paper(ctx.paper) == []
    end

    test "a member saves as before", ctx do
      assert json_response(save(seated(ctx.ws, "member"), ctx.ws, ctx.project, ctx.slug), 201)
      assert [_] = Masters.list_for_paper(ctx.paper)
    end
  end

  describe "Studio paper-save-master" do
    setup do
      prev = System.get_env("BARKPARK_PAPER_CANVAS")
      System.put_env("BARKPARK_PAPER_CANVAS", "1")

      on_exit(fn ->
        if prev,
          do: System.put_env("BARKPARK_PAPER_CANVAS", prev),
          else: System.delete_env("BARKPARK_PAPER_CANVAS")
      end)

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "paper",
            "title" => "Papers",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
          },
          @dataset
        )

      {slug, paper} = paper!(%{})
      %{slug: slug, paper: paper, ws_id: default_workspace_id!()}
    end

    defp studio_as(conn, ws_id, role) do
      raw = "cpm-s-#{role}-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "cpm #{role}", @dataset, ["read", "write"], ws_id)

      Membership
      |> Repo.get_by!(principal_id: token.id, principal_type: "api_token", workspace_id: ws_id)
      |> Ecto.Changeset.change(role: role)
      |> Repo.update!()

      init_test_session(conn, %{"api_token" => raw})
    end

    test "is a publish-class event" do
      assert BarkparkWeb.Studio.Caps.classify("paper-save-master") == :publish
    end

    @tag :requires_plugins
    test "a contributor's save is refused and no master is left", ctx do
      {:ok, view, _} =
        live(
          studio_as(ctx.conn, ctx.ws_id, "contributor"),
          scoped_studio("/d/#{@dataset}/studio/paper/#{ctx.slug}")
        )

      render_hook(view, "paper-save-master", %{"block_id" => "cpm-sec"})
      assert Masters.list_for_paper(ctx.paper) == []
    end

    @tag :requires_plugins
    test "a member saves as before", ctx do
      {:ok, view, _} =
        live(
          studio_as(ctx.conn, ctx.ws_id, "member"),
          scoped_studio("/d/#{@dataset}/studio/paper/#{ctx.slug}")
        )

      render_hook(view, "paper-save-master", %{"block_id" => "cpm-sec"})
      assert [_] = Masters.list_for_paper(ctx.paper)
    end
  end
end
