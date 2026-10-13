defmodule BarkparkWeb.PaperMastersControllerTest do
  @moduledoc """
  task-2dc7b441443f3aaf — `/w/:ws/p/:proj/v1/papers/:slug/masters` (list/save)
  and `/masters/:master_id/insert`, `/masters/blocks/:block_id/{pin,detach}`
  (write) expose `Barkpark.Plugins.Bulldocs.Masters` over HTTP with a member
  token, the same checks the Studio canvas's events get in-process.
  """
  # async: false — the op path's idempotency store is a shared table (see
  # Barkpark.Plugins.Bulldocs.MastersTest's own note).
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  @section %{
    "id" => "sec",
    "type" => "section",
    "blocks" => [
      %{"id" => "sec-h", "type" => "heading", "level" => 2, "text" => "Pricing"},
      %{"id" => "sec-p", "type" => "paragraph", "text" => "Master body copy"}
    ]
  }

  setup do
    ws = create_workspace!("pm-#{System.unique_integer([:positive])}")
    project = create_project!(ws)

    member_raw = "pm-member-#{System.unique_integer([:positive])}"
    {:ok, member} = Auth.create_token(member_raw, "pm-member", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "api_token")

    slug = "paper-masters-http-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
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
          %{"id" => "lead", "type" => "paragraph", "text" => "Lead"},
          @section
        ],
        workspace_id: ws.id,
        project_id: project.id
      })

    {:ok, _paper} = Content.upsert_paper(attrs)

    %{ws: ws, project: project, member_raw: member_raw, slug: slug}
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp base_path(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/v1/papers"

  describe "GET /v1/papers/:slug/masters" do
    test "lists nothing before any master is saved", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug
    } do
      conn = get(req(raw), "#{base_path(ws, project)}/#{slug}/masters")
      assert %{"masters" => []} = json_response(conn, 200)
    end

    test "an unknown paper slug is a 404", %{ws: ws, project: project, member_raw: raw} do
      conn = get(req(raw), "#{base_path(ws, project)}/no-such-paper/masters")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "an anonymous caller is refused", %{ws: ws, project: project, slug: slug} do
      conn = get(scoped_conn(), "#{base_path(ws, project)}/#{slug}/masters")
      assert conn.status in [401, 403]
    end
  end

  describe "POST /v1/papers/:slug/masters (save)" do
    test "saves the node as a published master and lists it", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug
    } do
      conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters", %{
          "blockId" => "sec",
          "title" => "Pricing"
        })

      body = json_response(conn, 201)
      assert body["title"] == "Pricing"
      assert body["tier"] == "section"
      assert body["sourcePaper"] == slug
      assert body["sourceBlockId"] == "sec"
      assert is_binary(body["docId"])
      assert is_binary(body["rev"])

      list_conn = get(req(raw), "#{base_path(ws, project)}/#{slug}/masters")
      assert %{"masters" => [listed]} = json_response(list_conn, 200)
      assert listed["docId"] == body["docId"]
    end

    test "a locked (slot-role) block is 422 :locked_block", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug
    } do
      conn = post(req(raw), "#{base_path(ws, project)}/#{slug}/masters", %{"blockId" => "t"})
      assert %{"error" => %{"code" => "locked_block"}} = json_response(conn, 422)
    end

    test "a missing blockId is a 422 malformed_request", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug
    } do
      conn = post(req(raw), "#{base_path(ws, project)}/#{slug}/masters", %{})
      assert %{"error" => %{"code" => "malformed_request"}} = json_response(conn, 422)
    end
  end

  describe "POST /v1/papers/:slug/masters/:master_id/insert" do
    setup %{ws: ws, project: project, member_raw: raw, slug: slug} do
      conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters", %{"blockId" => "sec"})

      %{master_id: json_response(conn, 201)["docId"]}
    end

    test "detached insert appends a fresh copy and bumps the paper's rev", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      master_id: master_id
    } do
      conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters/#{master_id}/insert", %{
          "mode" => "detached"
        })

      body = json_response(conn, 200)
      assert body["slug"] == slug
      assert body["opCount"] == 1
      assert [new_id] = body["blockIds"]
      assert is_binary(new_id)
      assert is_integer(body["rev"])
    end

    test "linked insert appends a master-ref block", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      master_id: master_id
    } do
      conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters/#{master_id}/insert", %{
          "mode" => "linked"
        })

      body = json_response(conn, 200)
      assert body["opCount"] == 1
      assert [_new_id] = body["blockIds"]
    end

    test "a foreign master id is a 404 :master_not_found", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug
    } do
      conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters/no-such-master/insert", %{
          "mode" => "detached"
        })

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "an unknown mode is a 422 malformed_request", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      master_id: master_id
    } do
      conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters/#{master_id}/insert", %{
          "mode" => "sideways"
        })

      assert %{"error" => %{"code" => "malformed_request"}} = json_response(conn, 422)
    end

    test "the same requestId replays the same receipt instead of inserting twice", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      master_id: master_id
    } do
      request_id = Ecto.UUID.generate()
      path = "#{base_path(ws, project)}/#{slug}/masters/#{master_id}/insert"
      body = %{"mode" => "detached", "requestId" => request_id}

      first = json_response(post(req(raw), path, body), 200)
      second = json_response(post(req(raw), path, body), 200)

      assert first == second
    end
  end

  describe "POST .../blocks/:block_id/pin and /detach" do
    setup %{ws: ws, project: project, member_raw: raw, slug: slug} do
      master_conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters", %{"blockId" => "sec"})

      master_id = json_response(master_conn, 201)["docId"]

      insert_conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters/#{master_id}/insert", %{
          "mode" => "linked"
        })

      [block_id] = json_response(insert_conn, 200)["blockIds"]
      %{block_id: block_id}
    end

    test "pin freezes the instance, unpin follows latest again", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      block_id: block_id
    } do
      path = "#{base_path(ws, project)}/#{slug}/masters/blocks/#{block_id}/pin"

      pin_conn = post(req(raw), path, %{"pin" => true})
      assert %{"opCount" => 1} = json_response(pin_conn, 200)

      unpin_conn = post(req(raw), path, %{"pin" => false})
      assert %{"opCount" => 1} = json_response(unpin_conn, 200)
    end

    test "detach replaces the instance with a plain copy", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      block_id: block_id
    } do
      conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters/blocks/#{block_id}/detach", %{})

      assert %{"opCount" => 1} = json_response(conn, 200)
    end

    test "pinning a non-linked block is a 422 :not_linked", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug
    } do
      conn =
        post(req(raw), "#{base_path(ws, project)}/#{slug}/masters/blocks/lead/pin", %{
          "pin" => true
        })

      assert %{"error" => %{"code" => "not_linked"}} = json_response(conn, 422)
    end
  end
end
