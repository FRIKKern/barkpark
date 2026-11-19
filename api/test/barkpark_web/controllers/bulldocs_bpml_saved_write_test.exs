defmodule BarkparkWeb.BulldocsBpmlSavedWriteTest do
  @moduledoc """
  A BPML push that writes is checked on the Paper as saved, inside the
  write's transaction: the row is read back and its reader's view printed. A
  success answers those bytes, which are the next pull's. A refusal rolls the
  write back: the row, its rev and cache, its history and its change events
  are as they were, no broadcast reaches a subscriber and no job is left.

  A create is checked the same way, on the row as stamped, so the schema that
  decides is the one of the workspace the row lands in. Two workspaces whose
  `paper` schemas hide different things, the default one and another, are
  each tried both ways: a flat create with no workspace given, and a create
  by a token pinned to the other workspace.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, LabelFixtures, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Content.Papers.BpmlView

  @ds "production"
  @token "barkpark-test-ingest-token"
  @hidden "PRIVATE_HEADING"
  @second "SECOND_SECRET"

  defp t(v), do: %{"type" => "text", "value" => v}
  defp slug(name), do: "bpml-saved-#{name}-#{System.unique_integer([:positive])}"

  defp heading(id \\ "h", text \\ @hidden),
    do: %{"id" => id, "type" => "heading", "level" => 2, "text" => text}

  defp para(id \\ "p", v \\ "Visible."),
    do: %{"id" => id, "type" => "paragraph", "content" => [t(v)]}

  defp default_scope,
    do: [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

  # The `paper` schema of `scope`, hiding each block's `text` when `hide?`.
  defp schema!(scope, hide?) do
    item_fields =
      if hide?, do: [%{"name" => "text", "type" => "string", "private" => true}], else: []

    fields = [
      %{"name" => "title", "type" => "string"},
      %{
        "name" => "blocks",
        "type" => "array",
        "of" => [%{"type" => "object", "fields" => item_fields}]
      }
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "paper", "title" => "Papers", "visibility" => "public", "fields" => fields},
        @ds,
        scope
      )
  end

  defp other_workspace! do
    ws = TenancyFixtures.create_workspace!()
    {:ok, project} = Tenancy.create_project_with_dataset(ws, %{name: "bpml saved #{ws.slug}"})
    LabelFixtures.register_tags!(@ds)
    %{ws: ws, project: project, scope: [workspace_id: ws.id, project_id: project.id]}
  end

  defp paper!(slug, blocks) do
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))
    paper
  end

  defp conn_for(token) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
  end

  defp pull(slug), do: get(scoped_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})

  defp pull!(slug) do
    resp = pull(slug)
    assert resp.status == 200, "pull answered #{resp.status}: #{resp.resp_body}"
    [rev] = get_resp_header(resp, "x-paper-rev")
    {resp.resp_body, rev}
  end

  defp sync(slug, bpml, rev, token \\ @token, extra \\ %{}) do
    conn_for(token)
    |> post(
      "/v1/plugins/bulldocs/papers/#{slug}/sync",
      Map.merge(%{"bpml" => bpml, "baseRev" => rev}, extra)
    )
  end

  # What a write leaves behind for `slug`, besides its answer.
  defp trace(slug) do
    paper = Content.get_paper(slug, @ds, [])

    %{
      row: paper && Map.take(paper, [:content, :title, :rev, :updated_at]),
      history: if(paper, do: length(Content.list_revisions(slug, "paper", @ds, [])), else: 0),
      events: Repo.aggregate(from(e in MutationEvent, where: e.doc_id == ^slug), :count),
      jobs: Repo.aggregate(Oban.Job, :count)
    }
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      100 -> :ok
    end
  end

  defp subscribe!(slug, workspace_id),
    do: Phoenix.PubSub.subscribe(Barkpark.PubSub, Content.paper_topic(slug, workspace_id, @ds))

  # The text a pull printed for another Paper before any field was hidden;
  # that Paper is gone, so a create of it duplicates nothing.
  defp creatable_bpml!(blocks) do
    schema!(default_scope(), false)
    source = slug("source")
    paper!(source, blocks)
    {bpml, _rev} = pull!(source)
    Repo.delete!(Content.get_paper(source))
    {source, bpml}
  end

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  test "a push whose saved Paper has no view is rolled back with every effect" do
    schema!(default_scope(), true)
    slug = slug("rollback")
    paper = paper!(slug, [heading(), para(), heading("h2", @second)])
    {bpml, rev} = pull!(slug)
    subscribe!(slug, paper.workspace_id)

    # Control: a push that keeps a visible block lands and is heard.
    edited = String.replace(bpml, "Visible.", "Edited.")
    refute edited == bpml
    answer = sync(slug, edited, rev) |> json_response(200)
    assert_receive {:paper_block, _frame}, 1_000
    flush_mailbox()
    {pulled, next_rev} = pull!(slug)
    assert answer["bpml"] == pulled
    assert answer["rev"] == next_rev

    before = trace(slug)
    emptied = String.replace(pulled, ~r/\s*<p id="p">Edited\.<\/p>/, "")
    refute emptied == pulled

    resp = sync(slug, emptied, next_rev)
    assert json_response(resp, 422)["error"]["code"] == "semantic_empty"
    assert trace(slug) == before
    refute_receive _any, 200
  end

  test "a create whose saved Paper has no view is rolled back with every effect" do
    {source, bpml} = creatable_bpml!([heading(), heading("h2", @second)])
    schema!(default_scope(), true)
    slug = slug("create-rollback")
    subscribe!(slug, Tenancy.get_default_workspace().id)
    jobs = Repo.aggregate(Oban.Job, :count)

    resp = sync(slug, String.replace(bpml, source, slug), "0")
    assert json_response(resp, 422)["error"]["code"] == "semantic_empty"
    assert trace(slug) == %{row: nil, history: 0, events: 0, jobs: jobs}
    refute_receive _any, 200
  end

  # The flat route, no workspace given: the row lands in the default
  # workspace, and only that workspace's schema decides.
  for {name, home_hides?} <- [{"the default workspace hides", true}, {"another hides", false}] do
    test "a flat create when #{name}: the answer is the next pull, or nothing is written" do
      {source, bpml} = creatable_bpml!([heading(), heading("h2", @second)])
      schema!(default_scope(), unquote(home_hides?))
      schema!(other_workspace!().scope, not unquote(home_hides?))
      slug = slug("flat-create")

      resp = sync(slug, String.replace(bpml, source, slug), "0")

      if unquote(home_hides?) do
        assert json_response(resp, 422)["error"]["code"] == "semantic_empty"
        assert Content.get_paper(slug, @ds, []) == nil
      else
        answer = json_response(resp, 200)
        assert answer["created"] == true
        {pulled, rev} = pull!(slug)
        assert answer["bpml"] == pulled
        assert answer["rev"] == rev
        assert pulled =~ @hidden
        assert Content.get_paper(slug, @ds, []).workspace_id == default_scope()[:workspace_id]
      end
    end
  end

  # A token pinned to the other workspace: the row lands there, and only that
  # workspace's schema decides.
  for {name, other_hides?} <- [{"its workspace hides", true}, {"the default hides", false}] do
    test "a pinned token's create when #{name}: the answer is the saved row's view" do
      {source, bpml} = creatable_bpml!([heading(), heading("h2", @second)])
      other = other_workspace!()
      schema!(other.scope, unquote(other_hides?))
      schema!(default_scope(), not unquote(other_hides?))
      raw = "bpml-saved-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(raw, "bpml saved", @ds, ["admin"], other.ws.id)
      slug = slug("pinned-create")

      resp =
        sync(slug, String.replace(bpml, source, slug), "0", raw, %{
          "project" => other.project.slug
        })

      if unquote(other_hides?) do
        assert json_response(resp, 422)["error"]["code"] == "semantic_empty"
        assert Content.get_paper(slug, @ds, []) == nil
      else
        answer = json_response(resp, 200)
        row = Content.get_paper(slug, @ds, other.scope)
        assert {row.workspace_id, row.project_id} == {other.ws.id, other.project.id}
        assert {:ok, answer["bpml"]} == BpmlView.print(row, @ds)
        assert answer["bpml"] =~ @hidden
      end
    end
  end
end
