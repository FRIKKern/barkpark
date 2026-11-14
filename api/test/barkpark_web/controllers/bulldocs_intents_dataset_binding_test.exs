defmodule BarkparkWeb.BulldocsIntentsDatasetBindingTest do
  @moduledoc """
  task-ad7114cdcb1200b9: the pending-intents drain holds a dataset-bound token
  to its dataset.

  A `paper_events` row carries no dataset of its own; it follows its paper
  (`paper_slug` + the row's workspace/project). Both actions scoped on the
  token's workspace only, so an admin token minted for `staging` listed and
  marked intents raised on `production` papers of the same workspace.

  Placement (`Barkpark.Plugins.Bulldocs.EventDataset`): an intent with no paper
  to follow counts as the paper default dataset; a slug that exists in two
  datasets is shown to no bound token.

  Every refusal is paired with a control in the same run: a bound token still
  drains its own dataset, and an unbound token of the same workspace still
  drains everything.
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Bulldocs.Events
  alias Barkpark.Repo

  @index_path "/v1/plugins/bulldocs/intents"
  @legacy_path "/v1/paperflow/intents"
  @staging "staging"
  @default "production"

  setup do
    ws = create_workspace!()
    project = create_project!(ws)
    n = System.unique_integer([:positive])
    perms = ["read", "write", "admin"]

    staging = "bib-staging-#{n}"
    default = "bib-default-#{n}"
    unbound = "bib-unbound-#{n}"

    {:ok, _} = Auth.create_token(staging, "bib-s", @staging, perms, ws.id, dataset_bound: true)
    {:ok, _} = Auth.create_token(default, "bib-d", @default, perms, ws.id, dataset_bound: true)
    {:ok, _} = Auth.create_token(unbound, "bib-u", @staging, perms, ws.id)

    %{ws: ws, project: project, n: n, staging: staging, default: default, unbound: unbound}
  end

  defp paper!(ctx, dataset, slug) do
    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => dataset,
          "blocks" => [%{"id" => "p", "type" => "paragraph", "text" => "Body"}],
          "workspace_id" => ctx.ws.id,
          "project_id" => ctx.project.id
        })
      )

    assert paper.dataset == dataset
    paper
  end

  # An intent the way the reader's action button records one: the paper slug
  # (nil = goal-only) + the paper's own workspace/project.
  defp intent!(ctx, slug) do
    {:ok, intent} =
      Events.create_event(%{
        "event_type" => "action:build",
        "goal_id" => "bib-goal-#{ctx.n}",
        "paper_slug" => slug,
        "payload_html" => "<p>PAYLOAD-#{slug || "goal-only"}-#{ctx.n}</p>",
        "workspace_id" => ctx.ws.id,
        "project_id" => ctx.project.id
      })

    intent
  end

  defp intent_on_paper!(ctx, dataset, slug) do
    paper!(ctx, dataset, slug)
    intent!(ctx, slug)
  end

  defp paper_rows(ctx, slug) do
    from(d in Document,
      where:
        d.type == "paper" and d.workspace_id == ^ctx.ws.id and
          d.doc_id in [^slug, ^("drafts." <> slug)]
    )
  end

  defp bearer(token) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("content-type", "application/json")
  end

  defp listed_ids(token, path \\ @index_path) do
    bearer(token)
    |> get(path)
    |> json_response(200)
    |> Map.fetch!("intents")
    |> Enum.map(& &1["id"])
  end

  defp mark(token, intent, path),
    do: bearer(token) |> post("#{path}/#{intent.id}/processed")

  defp assert_hidden(token, intent, path \\ @index_path) do
    refute intent.id in listed_ids(token, path)

    # The same answer an intent of another workspace gets, row untouched.
    body = json_response(mark(token, intent, path), 404)
    assert body["ok"] == false
    assert body["error"] == "not_found"
    assert is_nil(Events.get_event(intent.id).processed_at)
  end

  defp assert_drains(token, intent, path \\ @index_path) do
    assert intent.id in listed_ids(token, path)
    assert json_response(mark(token, intent, path), 200)["ok"] == true
    refute is_nil(Events.get_event(intent.id).processed_at)
  end

  describe "an intent on a paper" do
    test "a bound token lists its own dataset's intent and not another dataset's", ctx do
      own = intent_on_paper!(ctx, @staging, "bib-own-#{ctx.n}")
      other = intent_on_paper!(ctx, @default, "bib-other-#{ctx.n}")

      conn = bearer(ctx.staging) |> get(@index_path)
      ids = conn |> json_response(200) |> Map.fetch!("intents") |> Enum.map(& &1["id"])

      assert own.id in ids
      refute other.id in ids
      refute conn.resp_body =~ "PAYLOAD-#{other.paper_slug}"
    end

    test "a bound token cannot mark another dataset's intent, and marks its own", ctx do
      own = intent_on_paper!(ctx, @staging, "bib-own-#{ctx.n}")
      other = intent_on_paper!(ctx, @default, "bib-other-#{ctx.n}")

      assert_hidden(ctx.staging, other)
      assert_hidden(ctx.default, own)
      assert_drains(ctx.staging, own)
      assert_drains(ctx.default, other)
    end

    test "control: an unbound token of the same workspace lists and marks both", ctx do
      own = intent_on_paper!(ctx, @staging, "bib-own-#{ctx.n}")
      other = intent_on_paper!(ctx, @default, "bib-other-#{ctx.n}")

      assert_drains(ctx.unbound, own)
      assert_drains(ctx.unbound, other)
    end

    test "a draft-only paper places its intent", ctx do
      slug = "bib-draft-#{ctx.n}"
      intent = intent_on_paper!(ctx, @staging, slug)

      {1, _} =
        Repo.update_all(from(d in paper_rows(ctx, slug), where: d.doc_id == ^slug),
          set: [doc_id: "drafts." <> slug]
        )

      assert_hidden(ctx.default, intent)
      assert_drains(ctx.staging, intent)
    end

    test "the legacy /v1/paperflow/intents alias holds the binding too", ctx do
      own = intent_on_paper!(ctx, @staging, "bib-own-#{ctx.n}")
      other = intent_on_paper!(ctx, @default, "bib-other-#{ctx.n}")

      assert_hidden(ctx.staging, other, @legacy_path)
      assert_drains(ctx.staging, own, @legacy_path)
    end
  end

  describe "an intent with no paper to follow counts as the paper default dataset" do
    test "goal-only intent: drained by the default-bound token, hidden from another", ctx do
      intent = intent!(ctx, nil)

      assert_hidden(ctx.staging, intent)
      assert_drains(ctx.default, intent)
    end

    test "intent whose paper is gone: the same", ctx do
      slug = "bib-gone-#{ctx.n}"
      intent = intent_on_paper!(ctx, @staging, slug)

      # Placed in staging while its paper lives...
      assert intent.id in listed_ids(ctx.staging)
      refute intent.id in listed_ids(ctx.default)

      {deleted, _} = Repo.delete_all(paper_rows(ctx, slug))
      assert deleted >= 1

      assert_hidden(ctx.staging, intent)
      assert_drains(ctx.default, intent)
    end
  end

  describe "a slug that exists in two datasets" do
    test "is hidden from both bound tokens and still drained by the unbound one", ctx do
      slug = "bib-twin-#{ctx.n}"
      paper!(ctx, @staging, slug)
      paper!(ctx, @default, slug)

      assert Repo.aggregate(from(d in paper_rows(ctx, slug), where: d.doc_id == ^slug), :count) ==
               2

      intent = intent!(ctx, slug)

      assert_hidden(ctx.staging, intent)
      assert_hidden(ctx.default, intent)
      assert_drains(ctx.unbound, intent)
    end
  end
end
