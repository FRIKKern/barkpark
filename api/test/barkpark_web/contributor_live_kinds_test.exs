defmodule BarkparkWeb.ContributorLiveKindsTest do
  @moduledoc """
  A contributor seat gets READ on kinds without a draft layer and is refused
  every write there (task-348a4fbe24feede6, lead ruling B, 2026-10-10).

  Each door is tried with a contributor seat (refused with 403
  `publish_not_permitted`, nothing written) and, as the control, the same
  credential shape in a seat that may publish (the write lands).

  Doors: paper block ops (`POST /w/:ws/p/:proj/v1/papers/:slug/ops`), paper
  ingest (`POST /v1/plugins/bulldocs/papers`), sheet cell ops
  (`POST /v1/plugins/sheets/:slug/ops`, which rides the same ingest gate), and
  a reference disconnect that would rewrite a published referencer.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, LabelFixtures, Repo}
  alias Barkpark.Content.{CallerContext, Edges}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth
  alias Barkpark.Tenancy.Membership

  @dataset "production"

  defp set_role!(token_id, ws_id, role) do
    Membership
    |> Repo.get_by!(principal_id: token_id, principal_type: "api_token", workspace_id: ws_id)
    |> Ecto.Changeset.change(role: role)
    |> Repo.update!()
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp assert_refused(conn) do
    body = json_response(conn, 403)
    assert body["error"]["reason"] == "publish_not_permitted"
  end

  describe "paper block ops" do
    setup do
      ws = create_workspace!("clk-#{System.unique_integer([:positive])}")
      project = create_project!(ws)
      slug = "clk-paper-#{System.unique_integer([:positive])}"

      {:ok, paper} =
        Content.upsert_paper(
          LabelFixtures.paper_attrs(%{
            slug: slug,
            blocks: [
              %{
                "id" => "t",
                "type" => "heading",
                "level" => 1,
                "role" => "title",
                "locked" => true,
                "text" => "T"
              },
              %{"id" => "lead", "type" => "paragraph", "text" => "Lead"}
            ],
            workspace_id: ws.id,
            project_id: project.id
          })
        )

      %{ws: ws, project: project, slug: slug, rev: get_in(paper.content, ["rev"])}
    end

    defp seated(ws, role) do
      raw = "clk-#{role}-#{System.unique_integer([:positive])}"
      {:ok, token} = Auth.create_token(raw, "clk", @dataset, ["read", "write"])
      {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role, "api_token")
      raw
    end

    defp op_body(rev),
      do: %{
        "ifRev" => rev,
        "requestId" => Ecto.UUID.generate(),
        "ops" => [
          %{
            "op" => "append-block",
            "block" => %{"id" => "new", "type" => "paragraph", "text" => "x"}
          }
        ]
      }

    defp paper_ops_path(ws, project, slug),
      do: "/w/#{ws.slug}/p/#{project.slug}/v1/papers/#{slug}/ops"

    defp block_ids(ws, slug) do
      {:ok, doc} = Content.get_document(slug, "paper", @dataset, workspace_id: ws.id)
      Enum.map(get_in(doc.content, ["blocks"]) || [], & &1["id"])
    end

    test "refused for a contributor, applied for a member", %{
      ws: ws,
      project: project,
      slug: slug,
      rev: rev
    } do
      assert_refused(
        post(req(seated(ws, "contributor")), paper_ops_path(ws, project, slug), op_body(rev))
      )

      refute "new" in block_ids(ws, slug)

      assert json_response(
               post(req(seated(ws, "member")), paper_ops_path(ws, project, slug), op_body(rev)),
               200
             )

      assert "new" in block_ids(ws, slug)
    end

    test "a contributor can still READ the paper", %{ws: ws, project: project, slug: slug} do
      conn =
        get(
          req(seated(ws, "contributor")),
          "/w/#{ws.slug}/p/#{project.slug}/v1/data/doc/#{@dataset}/paper/#{slug}"
        )

      assert json_response(conn, 200)
    end
  end

  describe "the ingest door (paper ingest, sheet cell ops)" do
    setup do
      ws_id = default_workspace_id!()
      raw = "clk-admin-#{System.unique_integer([:positive])}"

      {:ok, token} =
        Auth.create_token(raw, "clk admin", @dataset, ["read", "write", "admin"], ws_id)

      %{ws_id: ws_id, raw: raw, token: token}
    end

    defp paper_body(slug),
      do:
        LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => [
            %{"id" => "h-1", "type" => "heading", "level" => 1, "text" => slug},
            %{"id" => "p-1", "type" => "paragraph", "text" => "contributor ingest"}
          ]
        })

    defp find_paper(slug) do
      import Ecto.Query

      Repo.one(
        from d in Barkpark.Content.Document,
          where: d.type == "paper" and d.doc_id in ^[slug, "drafts.#{slug}"],
          limit: 1
      )
    end

    test "paper ingest: refused for a contributor seat, written for the admin seat",
         %{ws_id: ws_id, raw: raw, token: token} do
      set_role!(token.id, ws_id, "contributor")
      slug = "clk-ingest-#{System.unique_integer([:positive])}"

      assert_refused(post(req(raw), "/v1/plugins/bulldocs/papers", paper_body(slug)))
      refute find_paper(slug)

      set_role!(token.id, ws_id, "admin")
      conn = post(req(raw), "/v1/plugins/bulldocs/papers", paper_body(slug))
      assert conn.status in [200, 201], conn.resp_body
      assert find_paper(slug)
    end

    test "sheet cell ops: refused for a contributor seat", %{ws_id: ws_id, raw: raw, token: token} do
      set_role!(token.id, ws_id, "contributor")
      slug = "clk-sheet-#{System.unique_integer([:positive])}"

      conn =
        post(req(raw), "/v1/plugins/sheets/#{slug}/ops", %{
          "request_id" => "clk-#{System.unique_integer([:positive])}",
          "ops" => [%{"op" => "set", "tab" => 0, "cell" => "A1", "value" => "1"}]
        })

      assert_refused(conn)
    end

    test "reads on the ingest pipeline stay open to a contributor seat",
         %{ws_id: ws_id, raw: raw, token: token} do
      set_role!(token.id, ws_id, "contributor")
      conn = get(req(raw), "/v1/plugins/bulldocs/intents")
      refute conn.status in [401, 403], conn.resp_body
    end
  end

  describe "reference disconnect" do
    test "refused for a contributor when a published document references the target" do
      ws_id = default_workspace_id!()
      suffix = System.unique_integer([:positive])

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "clkTarget",
            "title" => "T",
            "visibility" => "public",
            "fields" => [%{"name" => "title", "type" => "string"}]
          },
          @dataset
        )

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "clkRef",
            "title" => "R",
            "visibility" => "public",
            "fields" => [%{"name" => "target", "type" => "reference", "to" => ["clkTarget"]}]
          },
          @dataset
        )

      target = "clk-target-#{suffix}"
      referrer = "clk-ref-#{suffix}"

      {:ok, _} =
        Content.create_document("clkTarget", %{"doc_id" => target, "title" => "T"}, @dataset)

      {:ok, _} = Content.publish_document(target, "clkTarget", @dataset)

      {:ok, _} =
        Content.create_document(
          "clkRef",
          %{"doc_id" => referrer, "title" => "R", "content" => %{"target" => target}},
          @dataset
        )

      {:ok, _} = Content.publish_document(referrer, "clkRef", @dataset)

      raw = "clk-disc-#{suffix}"
      {:ok, token} = Auth.create_token(raw, "clk", @dataset, ["read", "write"], ws_id)
      set_role!(token.id, ws_id, "contributor")

      opts = [caller_context: CallerContext.from_token(token), workspace_id: ws_id]

      assert {:error, :publish_not_permitted} =
               Edges.disconnect_references(target, @dataset, opts)

      {:ok, ref} = Content.get_document(referrer, "clkRef", @dataset)
      assert ref.content["target"] == target

      # Control: the same token in a member seat disconnects.
      set_role!(token.id, ws_id, "member")

      assert Edges.disconnect_references(target, @dataset, opts) !=
               {:error, :publish_not_permitted}

      {:ok, ref} = Content.get_document(referrer, "clkRef", @dataset)
      refute ref.content["target"] == target
    end
  end
end
