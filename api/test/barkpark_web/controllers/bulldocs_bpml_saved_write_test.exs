defmodule BarkparkWeb.BulldocsBpmlSavedWriteTest do
  @moduledoc """
  A BPML push that writes is checked on the Paper as saved, inside the
  write's transaction: the row is read back and its reader's view printed. A
  success answers those bytes, which are the next pull's. A refusal rolls the
  write back: the row, its rev and cache, its history and its change events
  are as they were, no broadcast reaches a subscriber and no job is left.

  The check reads the saved row back by the row's own workspace and project,
  so the schema that decides is the one of the workspace the row lives in,
  whatever the request named. Two workspaces whose `paper` schemas hide
  different things, the default one and another, are each tried both ways:
  a flat create with no workspace given, a flat update of a Paper that lives
  in the other workspace, and a create by a token pinned to the other one.

  The right to write into a workspace or project is decided before the
  action, by the route's scope gate, and these rows pin that it still is: a
  pinned token that names another workspace, or a project outside its own,
  leaves nothing.
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

  defp paper!(slug, blocks, scope \\ []) do
    attrs = %{
      "slug" => slug,
      "blocks" => blocks,
      "workspace_id" => scope[:workspace_id],
      "project_id" => scope[:project_id]
    }

    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(attrs))
    paper
  end

  # A block the write accepts and the BPML printer cannot spell.
  defp image(id),
    do: %{"id" => id, "type" => "image", "src" => "https://cdn.example.com/a.png", "alt" => "A"}

  defp pinned_token!(ws) do
    raw = "bpml-saved-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "bpml saved", @ds, ["admin"], ws.id)
    raw
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

  # The workspace and project of the COMMITTED row, read straight off the
  # table (every row of `slug`, so a second stray row fails the match).
  defp committed_scope(slug) do
    [scope] =
      Repo.all(
        from d in Barkpark.Content.Document,
          where: d.doc_id == ^slug and d.type == "paper",
          select: {d.workspace_id, d.project_id}
      )

    scope
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
        home = default_scope()
        assert committed_scope(slug) == {home[:workspace_id], home[:project_id]}
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
      raw = pinned_token!(other.ws)
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
        assert committed_scope(slug) == {other.ws.id, other.project.id}
        row = Content.get_paper(slug, @ds, other.scope)
        assert {:ok, answer["bpml"]} == BpmlView.print(row, @ds)
        assert answer["bpml"] =~ @hidden
      end
    end
  end

  # The flat route, no workspace given, updating a Paper that lives in the
  # other workspace: the row's own workspace's schema decides, not the
  # request's (which names none, so would fall back to the default).
  for {name, other_hides?} <- [{"it hides", true}, {"only the default hides", false}] do
    test "a flat update of another workspace's Paper when #{name}: its row's schema decides" do
      other = other_workspace!()
      schema!(other.scope, unquote(other_hides?))
      schema!(default_scope(), not unquote(other_hides?))
      slug = slug("flat-update")
      paper = paper!(slug, [heading(), para(), heading("h2", @second)], other.scope)
      assert {paper.workspace_id, paper.project_id} == {other.ws.id, other.project.id}
      {:ok, bpml} = BpmlView.print(Content.get_paper(slug, @ds, other.scope), @ds)
      emptied = String.replace(bpml, ~r/\s*<p id="p">Visible\.<\/p>/, "")
      refute emptied == bpml
      before = trace(slug)

      resp = sync(slug, emptied, to_string(paper.content["rev"]))

      if unquote(other_hides?) do
        assert json_response(resp, 422)["error"]["code"] == "semantic_empty"
        assert trace(slug) == before
      else
        answer = json_response(resp, 200)
        assert committed_scope(slug) == {other.ws.id, other.project.id}
        saved = Content.get_paper(slug, @ds, other.scope)
        assert {:ok, answer["bpml"]} == BpmlView.print(saved, @ds)
        assert answer["bpml"] =~ @hidden
      end
    end
  end

  describe "the right to write is decided before the action" do
    setup do
      {source, bpml} = creatable_bpml!([heading(), heading("h2", @second)])
      other = other_workspace!()
      slug = slug("pinned-scope")
      bpml = String.replace(bpml, source, slug)
      %{other: other, raw: pinned_token!(other.ws), slug: slug, bpml: bpml}
    end

    test "a pinned token naming another workspace is refused and leaves nothing", c do
      jobs = Repo.aggregate(Oban.Job, :count)
      named = %{"workspace" => Tenancy.get_default_workspace().slug}

      resp = sync(c.slug, c.bpml, "0", c.raw, named)
      assert json_response(resp, 422)["error"]["code"] == "workspace_scope_conflict"
      assert trace(c.slug) == %{row: nil, history: 0, events: 0, jobs: jobs}
    end

    test "a pinned token naming another workspace's project is refused, leaving nothing", c do
      jobs = Repo.aggregate(Oban.Job, :count)
      named = %{"workspace_id" => c.other.ws.id, "project_id" => default_scope()[:project_id]}

      resp = sync(c.slug, c.bpml, "0", c.raw, named)
      assert json_response(resp, 422)["error"]["code"] == "project_scope_conflict"
      assert trace(c.slug) == %{row: nil, history: 0, events: 0, jobs: jobs}
    end

    test "a pinned token naming a project slug outside its workspace writes in its own", c do
      default_project = Tenancy.get_default_project()

      resp = sync(c.slug, c.bpml, "0", c.raw, %{"project" => default_project.slug})
      assert json_response(resp, 200)["created"] == true
      # The gate approves the token's workspace and no project (the slug
      # names none of its own). A workspace-only stamp takes that workspace's
      # project slugged "default", else its first (`WriteScope`), and the
      # other workspace's one project is `c.other.project`.
      assert Enum.map(Tenancy.list_projects(c.other.ws.id), & &1.id) == [c.other.project.id]
      assert committed_scope(c.slug) == {c.other.ws.id, c.other.project.id}
      refute c.other.project.id == default_project.id
    end
  end

  # What the removed 200 `bpml: nil` echo answered for: a write that lands a
  # Paper whose view does not print. The check refuses it at the write, so
  # an applied write always has the bytes it answers.
  describe "the check at the write" do
    test "a create whose saved view does not print is refused and leaves no row" do
      schema!(default_scope(), false)
      slug = slug("unprintable")
      ref = make_ref()
      blocks = [image("v"), para()]
      attrs = LabelFixtures.paper_attrs(%{"slug" => slug, "blocks" => blocks})

      assert {:error, {:view_refused, body}} =
               Content.upsert_paper(attrs, before_commit: BpmlView.saved_check(ref))

      assert body.code == "bpml_unprintable"
      assert Content.get_paper(slug, @ds, []) == nil
      assert BpmlView.checked(ref) == nil
    end

    test "a write whose saved view prints answers that view's bytes" do
      schema!(default_scope(), false)
      slug = slug("printable")
      ref = make_ref()
      attrs = LabelFixtures.paper_attrs(%{"slug" => slug, "blocks" => [heading(), para()]})

      assert {:ok, _} = Content.upsert_paper(attrs, before_commit: BpmlView.saved_check(ref))
      assert {:ok, BpmlView.checked(ref)} == BpmlView.print(Content.get_paper(slug), @ds)
    end

    test "a block-op batch whose saved view does not print is refused and the row is unchanged" do
      schema!(default_scope(), false)
      slug = slug("batch-unprintable")
      paper!(slug, [heading(), para()])
      before = trace(slug)
      op = %{"op" => "insert-after", "afterId" => "p", "block" => image("v")}

      opts = [before_commit: BpmlView.saved_check(make_ref())]

      assert {:error, {:view_refused, %{code: "bpml_unprintable"}}} =
               Content.apply_paper_block_ops(slug, [op], @ds, opts)

      assert trace(slug) == before
    end
  end
end
