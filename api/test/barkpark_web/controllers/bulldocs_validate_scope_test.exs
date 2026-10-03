defmodule BarkparkWeb.BulldocsValidateScopeTest do
  @moduledoc """
  task-5322b07a9f2e7416: `POST /v1/plugins/bulldocs/papers/validate` ran the
  publish-wall gates with NO scope, so the duplicate scan and the tag registry
  read every workspace. A workspace-B token's dry-run named workspace A's paper
  (id and title) as a duplicate. The gates now run in the caller's scope, as
  the real write's wall does.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, LabelFixtures, Repo, TenancyFixtures}
  alias Barkpark.Content.Document

  @dataset "production"
  @path "/v1/plugins/bulldocs/papers/validate"
  @title "Rate limiting the mutate controller endpoint"

  defp blocks(text) do
    [
      %{"id" => "h", "type" => "heading", "level" => 1, "text" => @title},
      %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => text}]
      }
    ]
  end

  @body_text "Inspect every crane cable, log the wear, and replace any cable past its limit before the winter shift."

  # A PUBLISHED paper in the given workspace, inserted directly (the
  # dedup_wall_workspace_scope_test shape): the duplicate scan reads published
  # rows only.
  defp seed_paper!(slug, ws, proj) do
    %Document{}
    |> Document.changeset(%{
      "doc_id" => slug,
      "type" => "paper",
      "dataset" => @dataset,
      "title" => @title,
      "status" => "published",
      "content" => %{"blocks" => blocks(@body_text)},
      "rev" => "rev-#{slug}",
      "workspace_id" => ws.id,
      "project_id" => proj.id
    })
    |> Repo.insert!()
  end

  defp token_for!(ws) do
    raw = "validate-scope-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "ws admin", @dataset, ["admin"], ws.id)
    raw
  end

  defp validate(token, slug) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(
      @path,
      LabelFixtures.paper_attrs(%{
        "slug" => slug,
        "title" => @title,
        "blocks" => blocks(@body_text)
      })
    )
    |> json_response(200)
  end

  setup do
    TenancyFixtures.ensure_default_scope!()
    ws_a = TenancyFixtures.create_workspace!()
    proj_a = TenancyFixtures.create_project!(ws_a, "default")
    ws_b = TenancyFixtures.create_workspace!()
    proj_b = TenancyFixtures.create_project!(ws_b, "default")
    %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, proj_b: proj_b}
  end

  test "workspace B's dry-run never names workspace A's paper", ctx do
    a_paper = seed_paper!("crane-plan-a", ctx.ws_a, ctx.proj_a)

    # Control: the same dry-run from A's own token does see A's paper, so the
    # duplicate scan is live and the B assertion below is not vacuous.
    a_reply = validate(token_for!(ctx.ws_a), "crane-plan-new-a")

    assert Jason.encode!(a_reply) =~ a_paper.doc_id,
           "control: the scan must flag A's own duplicate: #{inspect(a_reply)}"

    b_reply = validate(token_for!(ctx.ws_b), "crane-plan-new-b")

    refute Jason.encode!(b_reply) =~ a_paper.doc_id,
           "workspace B's dry-run named workspace A's paper: #{inspect(b_reply)}"
  end
end
