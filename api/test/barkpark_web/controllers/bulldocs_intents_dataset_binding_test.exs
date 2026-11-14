defmodule BarkparkWeb.BulldocsIntentsDatasetBindingTest do
  @moduledoc """
  task-ad7114cdcb1200b9: the pending-intents drain holds a dataset-bound token
  to its dataset.

  A `paper_events` row carries no dataset of its own; it follows its paper
  (`paper_slug` + the row's workspace/project). Both actions scoped on the
  token's workspace only, so an admin token minted for `staging` listed and
  marked intents raised on `production` papers of the same workspace.

  Every refusal is paired with a control in the same run: the bound token
  still drains its own dataset, and an unbound token of the same workspace
  still drains both.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Plugins.Bulldocs.Events

  @index_path "/v1/plugins/bulldocs/intents"
  @own "staging"
  @other "production"

  setup do
    ws = create_workspace!()
    project = create_project!(ws)
    n = System.unique_integer([:positive])

    bound = "bib-bound-#{n}"
    unbound = "bib-unbound-#{n}"
    perms = ["read", "write", "admin"]

    {:ok, _} = Auth.create_token(bound, "bib-bound", @own, perms, ws.id, dataset_bound: true)
    {:ok, _} = Auth.create_token(unbound, "bib-unbound", @own, perms, ws.id)

    %{
      bound: bound,
      unbound: unbound,
      own: intent_on_paper!(ws, project, @own, "bib-own-#{n}"),
      other: intent_on_paper!(ws, project, @other, "bib-other-#{n}")
    }
  end

  # A paper in `dataset`, and an intent raised on it the way the reader's
  # action button records one: paper slug + the paper's own workspace/project.
  defp intent_on_paper!(ws, project, dataset, slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => dataset,
          "blocks" => [%{"id" => "p", "type" => "paragraph", "text" => "Body"}],
          "workspace_id" => ws.id,
          "project_id" => project.id
        })
      )

    assert paper.dataset == dataset

    {:ok, intent} =
      Events.create_event(%{
        "event_type" => "action:build",
        "paper_slug" => slug,
        "payload_html" => "<p>PAYLOAD-#{slug}</p>",
        "workspace_id" => paper.workspace_id,
        "project_id" => paper.project_id
      })

    intent
  end

  defp bearer(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp listed_ids(token) do
    bearer(token)
    |> get(@index_path)
    |> json_response(200)
    |> Map.fetch!("intents")
    |> Enum.map(& &1["id"])
  end

  defp mark(token, intent), do: bearer(token) |> post("#{@index_path}/#{intent.id}/processed")

  describe "GET /v1/plugins/bulldocs/intents" do
    test "a bound token lists its own dataset's intent and not another dataset's", ctx do
      conn = bearer(ctx.bound) |> get(@index_path)
      ids = conn |> json_response(200) |> Map.fetch!("intents") |> Enum.map(& &1["id"])

      assert ctx.own.id in ids
      refute ctx.other.id in ids
      refute conn.resp_body =~ "PAYLOAD-#{ctx.other.paper_slug}"
    end

    test "control: an unbound token of the same workspace lists both", ctx do
      ids = listed_ids(ctx.unbound)

      assert ctx.own.id in ids
      assert ctx.other.id in ids
    end
  end

  describe "POST /v1/plugins/bulldocs/intents/:id/processed" do
    test "a bound token cannot mark another dataset's intent", ctx do
      conn = mark(ctx.bound, ctx.other)

      # The same answer an intent of another workspace gets.
      body = json_response(conn, 404)
      assert body["ok"] == false
      assert body["error"] == "not_found"
      assert is_nil(Events.get_event(ctx.other.id).processed_at)
    end

    test "control: a bound token marks its own dataset's intent", ctx do
      assert json_response(mark(ctx.bound, ctx.own), 200)["ok"] == true
      refute is_nil(Events.get_event(ctx.own.id).processed_at)
    end

    test "control: an unbound token marks an intent of either dataset", ctx do
      assert json_response(mark(ctx.unbound, ctx.other), 200)["ok"] == true
      assert json_response(mark(ctx.unbound, ctx.own), 200)["ok"] == true
      refute is_nil(Events.get_event(ctx.other.id).processed_at)
    end
  end
end
