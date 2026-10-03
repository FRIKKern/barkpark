defmodule BarkparkWeb.BulldocsProposalsScopeTest do
  @moduledoc """
  `POST /v1/plugins/bulldocs/papers/:slug/proposals` writes only inside the
  caller's workspace (r2-lane-b paper write-path audit, 2026-09-30).

  The action never passed the request's resolved scope to
  `Content.propose_paper_blocks/5`, so `get_scoped_paper/3` fell back to the
  Default workspace for EVERY caller: an admin api token bound to workspace B
  (the ingest pipeline accepts it) proposed into Default's papers (200). The
  second test is a guard for the draft-twin lookup: a proposal on a Default
  paper must never land in another workspace's draft of the same slug.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, TenancyFixtures}
  alias Barkpark.Content.Document

  @dataset "production"

  defp propose_path(slug), do: "/v1/plugins/bulldocs/papers/#{slug}/proposals"

  defp body(block_id, source) do
    %{
      "ops" => [
        %{
          "op" => "append-block",
          "block" => %{
            "id" => block_id,
            "type" => "paragraph",
            "content" => [%{"type" => "text", "value" => "proposed #{block_id}"}]
          }
        }
      ],
      "source" => %{"doc_id" => source, "agent" => "agent-x"}
    }
  end

  defp seed_default_paper!(slug) do
    {:ok, _} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "blocks" => [
            %{
              "id" => "intro",
              "type" => "paragraph",
              "content" => [%{"type" => "text", "value" => "Default prose."}]
            }
          ]
        })
      )

    Barkpark.LabelFixtures.exempt!([slug], @dataset)
  end

  defp rows(doc_id) do
    Repo.all(from d in Document, where: d.doc_id == ^doc_id and d.dataset == ^@dataset)
  end

  defp block_ids(%Document{content: content}),
    do: (get_in(content || %{}, ["blocks"]) || []) |> Enum.map(& &1["id"])

  setup do
    TenancyFixtures.ensure_default_scope!()
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b, "default")
    %{ws_b: ws_b, proj_b: proj_b}
  end

  test "an admin token bound to workspace B cannot propose into the Default workspace's paper",
       %{conn: conn, ws_b: ws_b} do
    seed_default_paper!("prop-scope-a")
    seed_default_paper!("prop-scope-src")

    raw = "prop-scope-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "workspace B admin", @dataset, ["admin"], ws_b.id)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
      |> post(propose_path("prop-scope-a"), body("b-prop", "prop-scope-src"))

    assert conn.status == 404

    refute Enum.any?(rows("drafts.prop-scope-a"), &("b-prop" in block_ids(&1))),
           "workspace B's credential wrote a proposal into Default's paper"
  end

  test "a proposal on a Default paper never lands in another workspace's draft of the same slug",
       %{conn: conn, ws_b: ws_b, proj_b: proj_b} do
    seed_default_paper!("prop-scope-twin")
    seed_default_paper!("prop-scope-src2")

    {:ok, foreign} =
      TenancyFixtures.create_document_in!(
        ws_b,
        proj_b,
        "paper",
        %{
          "doc_id" => "prop-scope-twin",
          "content" => %{"blocks" => [%{"id" => "b-own", "type" => "paragraph", "content" => []}]}
        },
        @dataset
      )

    assert foreign.doc_id == "drafts.prop-scope-twin"
    assert foreign.workspace_id == ws_b.id

    conn =
      conn
      |> put_req_header("authorization", "Bearer barkpark-test-ingest-token")
      |> put_req_header("content-type", "application/json")
      |> post(propose_path("prop-scope-twin"), body("d-prop", "prop-scope-src2"))

    assert json_response(conn, 200)["applied_block_ids"] == ["d-prop"]

    foreign_after = Repo.get!(Document, foreign.id)
    assert block_ids(foreign_after) == ["b-own"], "the proposal wrote into workspace B's draft"

    default_draft =
      rows("drafts.prop-scope-twin")
      |> Enum.find(&(&1.workspace_id == TenancyFixtures.default_workspace_id!()))

    assert default_draft, "the proposal seeded Default's own draft twin"
    assert "d-prop" in block_ids(default_draft)
  end

  # task-dbd897d8b3623175: the draft twin was looked up with NO scope, which
  # resolves the dataset to Default's. In workspace B the paper's own draft was
  # never found, so a second proposal re-seeded it and failed, and a same-slug
  # Default draft was found and written instead.
  describe "proposals on a non-Default workspace's own paper" do
    setup %{ws_b: ws_b, proj_b: proj_b} do
      scope = [workspace_id: ws_b.id, project_id: proj_b.id]

      for slug <- ["prop-b-own", "prop-b-src"] do
        {:ok, _} =
          Content.upsert_paper(
            Barkpark.LabelFixtures.paper_attrs(%{
              "slug" => slug,
              "workspace_id" => ws_b.id,
              "project_id" => proj_b.id,
              "blocks" => [
                %{
                  "id" => "intro",
                  "type" => "paragraph",
                  "content" => [%{"type" => "text", "value" => "B prose."}]
                }
              ]
            }),
            scope
          )
      end

      Barkpark.LabelFixtures.exempt!(["prop-b-own", "prop-b-src"], @dataset)

      raw = "prop-b-admin-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "workspace B admin", @dataset, ["admin"], ws_b.id)
      %{token: raw}
    end

    defp propose_as(conn, token, slug, block_id, source) do
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(propose_path(slug), body(block_id, source))
    end

    test "a second proposal lands in the same draft", %{conn: conn, token: token, ws_b: ws_b} do
      first = propose_as(conn, token, "prop-b-own", "b-1", "prop-b-src")
      assert first.status == 200, "first proposal: #{first.status} #{first.resp_body}"

      second = propose_as(build_conn(), token, "prop-b-own", "b-2", "prop-b-src")
      assert second.status == 200, "second proposal: #{second.status} #{second.resp_body}"

      [draft] = rows("drafts.prop-b-own") |> Enum.filter(&(&1.workspace_id == ws_b.id))
      assert "b-1" in block_ids(draft) and "b-2" in block_ids(draft)
    end

    test "a same-slug Default draft is never written", %{conn: conn, token: token} do
      # Default holds its own paper of the same slug, with a draft seeded by an
      # ingest-token proposal.
      seed_default_paper!("prop-b-own")
      seed_default_paper!("prop-b-dsrc")

      ingest =
        build_conn()
        |> put_req_header("authorization", "Bearer barkpark-test-ingest-token")
        |> put_req_header("content-type", "application/json")
        |> post(propose_path("prop-b-own"), body("d-1", "prop-b-dsrc"))

      assert json_response(ingest, 200)["applied_block_ids"] == ["d-1"]

      before = rows("drafts.prop-b-own") |> Enum.filter(&(&1.workspace_id == default_ws()))
      assert length(before) == 1, "fixture: Default's draft twin must exist"

      first = propose_as(conn, token, "prop-b-own", "b-1", "prop-b-src")
      assert first.status == 200
      second = propose_as(build_conn(), token, "prop-b-own", "b-2", "prop-b-src")
      assert second.status == 200

      after_rows = rows("drafts.prop-b-own") |> Enum.filter(&(&1.workspace_id == default_ws()))

      assert Enum.map(after_rows, &block_ids/1) == Enum.map(before, &block_ids/1),
             "workspace B's proposal wrote into Default's draft"
    end
  end

  defp default_ws, do: TenancyFixtures.default_workspace_id!()
end
