defmodule BarkparkWeb.BulldocsValidateBoundDatasetTest do
  @moduledoc """
  task-a6e42a4bcee63199: `POST /v1/plugins/bulldocs/papers/validate` ran the
  publish-wall gates against the paper default dataset whatever the caller's
  dataset was. A dataset-bound token's dry-run read another dataset: it named
  that dataset's paper as a duplicate and missed the one in its own. The real
  write (`ingest`, `sync`) uses `params["dataset"]`, which the `:ingest`
  pipeline fills with the token's dataset; the dry-run now does the same.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, LabelFixtures, Repo, TenancyFixtures}
  alias Barkpark.Content.Document

  @own "validate-bound-own"
  @path "/v1/plugins/bulldocs/papers/validate"
  @title "Rate limiting the mutate controller endpoint"
  @body_text "Inspect every crane cable, log the wear, and replace any cable past its limit before the winter shift."

  defp blocks do
    [
      %{"id" => "h", "type" => "heading", "level" => 1, "text" => @title},
      %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => @body_text}]
      }
    ]
  end

  # A PUBLISHED paper (the duplicate scan reads published rows only).
  defp seed_paper!(slug, dataset, ws, proj) do
    %Document{}
    |> Document.changeset(%{
      "doc_id" => slug,
      "type" => "paper",
      "dataset" => dataset,
      "title" => @title,
      "status" => "published",
      "content" => %{"blocks" => blocks()},
      "rev" => "rev-#{slug}",
      "workspace_id" => ws.id,
      "project_id" => proj.id
    })
    |> Repo.insert!()
  end

  defp token!(ws, opts) do
    raw = "validate-bound-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "validate bound", @own, ["admin"], ws.id, opts)
    raw
  end

  defp validate(token, extra \\ %{}) do
    attrs =
      LabelFixtures.paper_attrs(%{
        "slug" => "crane-plan-new",
        "title" => @title,
        "blocks" => blocks()
      })

    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
    |> post(@path, Map.merge(attrs, extra))
  end

  setup do
    TenancyFixtures.ensure_default_scope!()
    ws = TenancyFixtures.create_workspace!()
    proj = TenancyFixtures.create_project!(ws, "default")
    default = Content.paper_default_dataset()
    refute default == @own

    seed_paper!("crane-plan-default", default, ws, proj)
    seed_paper!("crane-plan-own", @own, ws, proj)
    %{ws: ws}
  end

  test "a dataset-bound token's dry-run reads its own dataset, not the default", %{ws: ws} do
    reply = ws |> token!(dataset_bound: true) |> validate() |> json_response(200)
    encoded = Jason.encode!(reply)

    assert encoded =~ "crane-plan-own",
           "the dry-run missed the duplicate in the token's own dataset: #{encoded}"

    refute encoded =~ "crane-plan-default",
           "the dry-run named a paper of another dataset: #{encoded}"
  end

  test "a dataset-bound token naming another dataset is still refused", %{ws: ws} do
    resp =
      ws
      |> token!(dataset_bound: true)
      |> validate(%{"dataset" => Content.paper_default_dataset()})

    assert resp.status == 403
    assert resp.resp_body =~ "dataset_not_bound"
  end

  test "an unbound token keeps validating against the default dataset (control)", %{ws: ws} do
    reply = ws |> token!([]) |> validate() |> json_response(200)
    encoded = Jason.encode!(reply)

    assert encoded =~ "crane-plan-default", "control: #{encoded}"
    refute encoded =~ "crane-plan-own", "control: #{encoded}"
  end
end
