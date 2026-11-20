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
  a flat create with no workspace given, and a create by a token pinned to
  the other one.

  A pinned token's create lands in its own workspace, and every row that
  writes asserts the committed row's workspace and project.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, LabelFixtures, Repo, Tenancy, TenancyFixtures}
  alias Barkpark.Content.{Broadcast, MutationEvent}
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

  # Every PubSub topic the write's effects send on: the Paper's own topic
  # (`broadcast_paper_update/1`, `broadcast_paper_block/4`, and the doc frame
  # of `ChangeEvents.announce/3`, which share it), the dataset's and the
  # workspace's list topics (the list frames), and the relations topic the
  # edge projection sends on.
  defp effect_topics(slug, ws_id) do
    [
      Broadcast.paper_topic(slug, ws_id, @ds),
      Broadcast.global_list_topic(@ds),
      Broadcast.workspace_list_topic(@ds, ws_id),
      Broadcast.paper_relations_topic(ws_id, @ds)
    ]
  end

  # One listener per effect topic, handing frames on as `{:heard, topic,
  # frame}`, so the test's own mailbox (which also gets the conn test's
  # replies) is not what is counted. The Paper's own topic is this Paper's
  # alone and its block frames do not name the slug, so every frame on it is
  # handed on; the shared topics hand on only frames naming `slug`.
  defp listen!(slug, ws_id) do
    test = self()
    [own | _] = topics = effect_topics(slug, ws_id)
    assert length(Enum.uniq(topics)) == 4

    for topic <- topics do
      only = if topic == own, do: nil, else: slug

      spawn_link(fn ->
        :ok = Phoenix.PubSub.subscribe(Barkpark.PubSub, topic)
        send(test, {:listening, topic})
        forward(test, topic, only)
      end)
    end

    for topic <- topics, do: assert_receive({:listening, ^topic}, 1_000)
    topics
  end

  defp forward(test, topic, only) do
    receive do
      frame ->
        if only == nil or inspect(frame) =~ only, do: send(test, {:heard, topic, frame})
    end

    forward(test, topic, only)
  end

  defp flush_heard do
    receive do
      {:heard, _topic, _frame} -> flush_heard()
    after
      100 -> :ok
    end
  end

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
    topics = listen!(slug, paper.workspace_id)

    # Control: a push that keeps a visible block lands and is heard.
    edited = String.replace(bpml, "Visible.", "Edited.")
    refute edited == bpml
    answer = sync(slug, edited, rev) |> json_response(200)
    paper_topic = hd(topics)
    assert_receive {:heard, ^paper_topic, {:paper_block, _frame}}, 1_000
    flush_heard()
    {pulled, next_rev} = pull!(slug)
    assert answer["bpml"] == pulled
    assert answer["rev"] == next_rev

    before = trace(slug)
    emptied = String.replace(pulled, ~r/\s*<p id="p">Edited\.<\/p>/, "")
    refute emptied == pulled

    resp = sync(slug, emptied, next_rev)
    assert json_response(resp, 422)["error"]["code"] == "semantic_empty"
    assert trace(slug) == before
    refute_receive {:heard, _topic, _frame}, 200
  end

  test "a create whose saved Paper has no view is rolled back with every effect" do
    {source, bpml} = creatable_bpml!([heading(), heading("h2", @second)])
    schema!(default_scope(), true)
    slug = slug("create-rollback")
    listen!(slug, Tenancy.get_default_workspace().id)
    jobs = Repo.aggregate(Oban.Job, :count)

    resp = sync(slug, String.replace(bpml, source, slug), "0")
    assert json_response(resp, 422)["error"]["code"] == "semantic_empty"
    assert trace(slug) == %{row: nil, history: 0, events: 0, jobs: jobs}
    refute_receive {:heard, _topic, _frame}, 200
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

  describe "a pinned token's create" do
    setup do
      {source, bpml} = creatable_bpml!([heading(), heading("h2", @second)])
      other = other_workspace!()
      slug = slug("pinned-scope")
      bpml = String.replace(bpml, source, slug)
      %{other: other, raw: pinned_token!(other.ws), slug: slug, bpml: bpml}
    end

    test "a pinned token naming a project slug outside its workspace writes in its own", c do
      default_project = Tenancy.get_default_project()

      resp = sync(c.slug, c.bpml, "0", c.raw, %{"project" => default_project.slug})
      assert json_response(resp, 200)["created"] == true
      # The request resolves to the token's workspace and no project (the slug
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
