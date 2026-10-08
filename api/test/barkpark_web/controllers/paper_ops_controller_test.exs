defmodule BarkparkWeb.PaperOpsControllerTest do
  @moduledoc """
  task-7ee817f37630d669 (P1, blocks barkpark-studio's Freeform papers) —
  `POST /w/:ws/p/:proj/v1/papers/:slug/ops`, the member-token twin of the
  `:ingest`-only `POST /v1/plugins/bulldocs/papers/:slug/ops`, exposing
  `Content.apply_paper_block_ops_once/6` to the same write tier
  `PaperMastersController` already rides.
  """
  # async: false — the op path's idempotency store is a shared table (see
  # Barkpark.Plugins.Bulldocs.MastersTest's own note, and
  # PaperMastersControllerTest mirrors it for the same reason).
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("po-#{System.unique_integer([:positive])}")
    project = create_project!(ws)

    member_raw = "po-member-#{System.unique_integer([:positive])}"
    {:ok, member} = Auth.create_token(member_raw, "po-member", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "api_token")

    reader_raw = "po-reader-#{System.unique_integer([:positive])}"
    {:ok, reader} = Auth.create_token(reader_raw, "po-reader", @dataset, ["read"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, reader.id, "member", "api_token")

    outsider_raw = "po-outsider-#{System.unique_integer([:positive])}"
    {:ok, _outsider} = Auth.create_token(outsider_raw, "po-outsider", @dataset, ["read", "write"])

    slug = "paper-ops-http-#{System.unique_integer([:positive])}"

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
          %{"id" => "lead", "type" => "paragraph", "text" => "Lead"}
        ],
        workspace_id: ws.id,
        project_id: project.id
      })

    {:ok, paper} = Content.upsert_paper(attrs)
    rev = get_in(paper.content, ["rev"])

    %{
      ws: ws,
      project: project,
      member_raw: member_raw,
      reader_raw: reader_raw,
      outsider_raw: outsider_raw,
      slug: slug,
      rev: rev
    }
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp ops_path(ws, project, slug), do: "/w/#{ws.slug}/p/#{project.slug}/v1/papers/#{slug}/ops"

  defp append_op(id, text),
    do: %{
      "op" => "append-block",
      "block" => %{"id" => id, "type" => "paragraph", "text" => text}
    }

  describe "POST /v1/papers/:slug/ops — member token, happy path" do
    test "applies a batch of ops and answers the new rev", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      rev: rev
    } do
      conn =
        post(req(raw), ops_path(ws, project, slug), %{
          "ops" => [append_op("b1", "one"), append_op("b2", "two")],
          "ifRev" => rev
        })

      body = json_response(conn, 200)
      assert body["slug"] == slug
      assert body["opCount"] == 2
      assert body["blockIds"] == ["b1", "b2"]
      assert is_integer(body["rev"])
      refute body["rev"] == rev

      # The write actually landed — read it back.
      reloaded = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: project.id)
      ids = get_in(reloaded.content, ["blocks"]) |> Enum.map(& &1["id"])
      assert "b1" in ids and "b2" in ids
    end

    test "the same requestId replays the same receipt instead of applying twice", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      rev: rev
    } do
      request_id = Ecto.UUID.generate()

      body = %{
        "ops" => [append_op("r1", "once")],
        "ifRev" => rev,
        "requestId" => request_id
      }

      first = json_response(post(req(raw), ops_path(ws, project, slug), body), 200)
      second = json_response(post(req(raw), ops_path(ws, project, slug), body), 200)

      assert first == second
    end
  end

  describe "POST /v1/papers/:slug/ops — a stale ifRev" do
    test "answers 412 precondition_failed with details.actual, and writes nothing", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      rev: rev
    } do
      conn =
        post(req(raw), ops_path(ws, project, slug), %{
          "ops" => [append_op("stale1", "x")],
          "ifRev" => rev + 1000
        })

      body = json_response(conn, 412)
      assert body["error"]["code"] == "precondition_failed"
      assert body["error"]["details"]["actual"] == rev
      assert body["error"]["details"]["expected"] == rev + 1000

      reloaded = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: project.id)
      assert get_in(reloaded.content, ["rev"]) == rev
      ids = get_in(reloaded.content, ["blocks"]) |> Enum.map(& &1["id"])
      refute "stale1" in ids
    end
  end

  describe "POST /v1/papers/:slug/ops — security: write authorization" do
    test "a read-only member token is refused (write permission required)", %{
      ws: ws,
      project: project,
      reader_raw: raw,
      slug: slug,
      rev: rev
    } do
      conn =
        post(req(raw), ops_path(ws, project, slug), %{
          "ops" => [append_op("ro1", "x")],
          "ifRev" => rev
        })

      assert conn.status in [401, 403]

      reloaded = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: project.id)
      ids = get_in(reloaded.content, ["blocks"]) |> Enum.map(& &1["id"])
      refute "ro1" in ids
    end

    test "a non-member token (write-capable elsewhere) is refused", %{
      ws: ws,
      project: project,
      outsider_raw: raw,
      slug: slug,
      rev: rev
    } do
      conn =
        post(req(raw), ops_path(ws, project, slug), %{
          "ops" => [append_op("out1", "x")],
          "ifRev" => rev
        })

      assert conn.status in [401, 403, 404]

      reloaded = Content.get_paper(slug, @dataset, workspace_id: ws.id, project_id: project.id)
      ids = get_in(reloaded.content, ["blocks"]) |> Enum.map(& &1["id"])
      refute "out1" in ids
    end

    test "an anonymous caller is refused", %{ws: ws, project: project, slug: slug, rev: rev} do
      conn =
        post(scoped_conn(), ops_path(ws, project, slug), %{
          "ops" => [append_op("anon1", "x")],
          "ifRev" => rev
        })

      assert conn.status in [401, 403]
    end
  end

  describe "POST /v1/papers/:slug/ops — malformed requests" do
    test "missing ops is 422 malformed_op", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      rev: rev
    } do
      conn = post(req(raw), ops_path(ws, project, slug), %{"ifRev" => rev})
      assert %{"error" => %{"code" => "malformed_op"}} = json_response(conn, 422)
    end

    test "an empty ops list is 422 malformed_op", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      rev: rev
    } do
      conn = post(req(raw), ops_path(ws, project, slug), %{"ops" => [], "ifRev" => rev})
      assert %{"error" => %{"code" => "malformed_op"}} = json_response(conn, 422)
    end

    test "missing ifRev is 422 malformed_op", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug
    } do
      conn = post(req(raw), ops_path(ws, project, slug), %{"ops" => [append_op("n1", "x")]})
      assert %{"error" => %{"code" => "malformed_op"}} = json_response(conn, 422)
    end

    test "an unknown paper slug is a 404", %{ws: ws, project: project, member_raw: raw} do
      conn =
        post(req(raw), ops_path(ws, project, "no-such-paper"), %{
          "ops" => [append_op("n1", "x")],
          "ifRev" => 0
        })

      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "an invalid requestId is a 422 malformed_request", %{
      ws: ws,
      project: project,
      member_raw: raw,
      slug: slug,
      rev: rev
    } do
      conn =
        post(req(raw), ops_path(ws, project, slug), %{
          "ops" => [append_op("n1", "x")],
          "ifRev" => rev,
          "requestId" => "not-a-uuid"
        })

      assert %{"error" => %{"code" => "malformed_request"}} = json_response(conn, 422)
    end
  end
end
