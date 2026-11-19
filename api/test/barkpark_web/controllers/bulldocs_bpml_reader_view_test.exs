defmodule BarkparkWeb.BulldocsBpmlReaderViewTest do
  @moduledoc """
  One reader's view of a Paper (`Papers.BpmlView`) serves the BPML pull, the
  answers to a push that updates or creates the Paper, and the comparison a
  push is diffed against. The answer to a write is the pull at the answered
  rev, byte for byte. What the view refuses, the pull and the push refuse
  alike, and a refused push writes nothing.

  Every Paper here is written by the real write path, which leaves its cached
  HTML and stamp. The schemas hide a block field (a heading's `text`) or a
  label field (`description`) through `upsert_schema`.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, LabelFixtures, Repo, Tenancy}
  alias Barkpark.PortableDoc.Render

  @ds "production"
  @token "barkpark-test-ingest-token"
  @hidden "PRIVATE_HEADING"
  @second "SECOND_SECRET"

  defp t(v), do: %{"type" => "text", "value" => v}
  defp slug(name), do: "bpml-reader-view-#{name}-#{System.unique_integer([:positive])}"

  defp heading(id \\ "h", text \\ @hidden),
    do: %{"id" => id, "type" => "heading", "level" => 2, "text" => text}

  defp para(id \\ "p", v \\ "Visible."),
    do: %{"id" => id, "type" => "paragraph", "content" => [t(v)]}

  defp blocks, do: [heading(), para(), heading("h2", @second)]

  defp scope,
    do: [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

  defp schema!(opts) do
    item_fields =
      if opts[:text], do: [%{"name" => "text", "type" => "string", "private" => true}], else: []

    fields = [
      %{"name" => "title", "type" => "string"},
      %{"name" => "description", "type" => "string", "private" => opts[:description] == true},
      %{
        "name" => "blocks",
        "type" => "array",
        "private" => opts[:blocks] == true,
        "of" => [%{"type" => "object", "fields" => item_fields}]
      }
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "paper", "title" => "Papers", "visibility" => "public", "fields" => fields},
        @ds,
        scope()
      )
  end

  defp paper!(slug, blocks) do
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))
    paper
  end

  defp row(slug), do: Content.get_paper(slug).content

  defp update_row!(slug, fun) do
    paper = Content.get_paper(slug)
    paper |> Ecto.Changeset.change(content: fun.(paper.content)) |> Repo.update!()
  end

  defp pull(slug), do: get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})

  defp pull!(slug) do
    resp = pull(slug)
    assert resp.status == 200, "pull answered #{resp.status}: #{resp.resp_body}"
    [rev] = get_resp_header(resp, "x-paper-rev")
    {resp.resp_body, rev}
  end

  defp sync(slug, bpml, rev) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/bulldocs/papers/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  # The answer is the pull at the rev it answers, byte for byte.
  defp answer_is_the_pull!(slug, answer) do
    assert is_binary(answer["bpml"]), "the answer carries no BPML: #{inspect(answer)}"
    {pulled, rev} = pull!(slug)
    assert rev == answer["rev"]
    assert answer["bpml"] == pulled
  end

  defp hidden_text(slug), do: [@hidden, @second, row(slug)["description"]]

  setup do
    LabelFixtures.register_tags!(@ds)
    :ok
  end

  describe "a Paper that hides a block field" do
    setup do
      schema!(text: true)
      :ok
    end

    test "the pull's title is the reader's: a hidden heading is not printed as the title" do
      slug = slug("title")
      paper!(slug, blocks())
      assert Content.get_paper(slug).title == @hidden

      {bpml, _rev} = pull!(slug)
      assert bpml =~ ~s(<h2 id="h"></h2>)
      refute bpml =~ @hidden

      json = get(build_conn(), "/papers/#{slug}/source") |> json_response(200)
      refute json["title"] == @hidden
    end

    test "pulls after a write, and the push answer is that pull" do
      slug = slug("update")
      paper!(slug, blocks())
      {bpml, rev} = pull!(slug)

      answer = sync(slug, String.replace(bpml, "Visible.", "Edited."), rev) |> json_response(200)
      assert answer["ok"] == true
      answer_is_the_pull!(slug, answer)

      assert [heading(), %{"content" => [%{"value" => "Edited."}]}, heading("h2", @second)] ==
               row(slug)["blocks"]
    end

    test "an unedited push writes nothing and keeps every field the pull hid" do
      slug = slug("unedited")
      paper!(slug, blocks())
      before = row(slug)
      {bpml, rev} = pull!(slug)

      assert json_response(sync(slug, bpml, rev), 200)["unchanged"] == true
      assert row(slug) == before
    end

    test "an unedited push keeps every field the pull hid after the cache is repaired in between" do
      slug = slug("repaired")
      paper!(slug, blocks())

      update_row!(
        slug,
        &Map.merge(&1, %{"body_html" => "<p>old render</p>", "body_html_sv" => "old"})
      )

      {bpml, rev} = pull!(slug)

      assert %{rewritten: 1} =
               Mix.Tasks.Barkpark.RehydrateBodyHtml.rehydrate(type: "paper", dataset: @ds)

      before = row(slug)

      assert json_response(sync(slug, bpml, rev), 200)["unchanged"] == true
      assert row(slug) == before
    end

    test "a push that would leave the reader nothing to see is refused before it writes" do
      slug = slug("emptied")
      paper!(slug, blocks())
      before = row(slug)
      {bpml, rev} = pull!(slug)

      emptied = String.replace(bpml, ~r/\s*<p id="p">Visible\.<\/p>/, "")
      resp = sync(slug, emptied, rev)
      assert json_response(resp, 422)["error"]["code"] == "semantic_empty"
      assert row(slug) == before
    end
  end

  test "a Paper that hides a label field: the push answer is the pull" do
    schema!(description: true)
    slug = slug("label")
    paper!(slug, blocks())
    {bpml, rev} = pull!(slug)
    refute bpml =~ row(slug)["description"]

    answer = sync(slug, String.replace(bpml, "Visible.", "Edited."), rev) |> json_response(200)
    answer_is_the_pull!(slug, answer)
  end

  # The text a pull printed for another Paper before its fields were hidden,
  # meta included; that Paper is gone, so the new one duplicates nothing.
  defp creatable_bpml!(blocks) do
    schema!([])
    source = slug("create-source")
    paper!(source, blocks)
    {bpml, _rev} = pull!(source)
    Repo.delete!(Content.get_paper(source))
    {source, bpml}
  end

  for hide <- [:text, :description] do
    test "the answer to a push that creates a Paper hiding its #{hide} is the pull of it" do
      {source, bpml} = creatable_bpml!(blocks())
      schema!([{unquote(hide), true}])

      slug = slug("create")
      answer = sync(slug, String.replace(bpml, source, slug), "0") |> json_response(200)
      assert answer["created"] == true
      answer_is_the_pull!(slug, answer)
    end
  end

  test "a create that would leave the reader nothing to see is refused before it writes" do
    {source, bpml} = creatable_bpml!([heading(), para("p", "")])
    schema!(text: true)

    slug = slug("create-empty")
    resp = sync(slug, String.replace(bpml, source, slug), "0")
    assert json_response(resp, 422)["error"]["code"] == "semantic_empty"
    assert Content.get_paper(slug) == nil
  end

  # Each way the view can fail, set on the row after a pull (the op rev does
  # not move): the pull and an unedited push of that pull refuse with the same
  # error, the push writes nothing, and neither error quotes a stored block.
  defp fail!("redacted_source", _slug), do: schema!(text: true, blocks: true)

  defp fail!(code, slug), do: update_row!(slug, &failed(code, &1))

  defp failed("bpml_unavailable", c),
    do: c |> Map.drop(["blocks", "body"]) |> Map.put("body_html", "<p>Opaque html.</p>")

  defp failed("invalid_blocks", c), do: Map.put(c, "blocks", c["blocks"] ++ [%{"id" => "x"}])

  defp failed("semantic_empty", c),
    do: c |> Map.put("blocks", [heading()]) |> Map.delete("body_html")

  defp failed("bpml_unprintable", c) do
    ref = %{
      "id" => "v",
      "type" => "paragraph",
      "content" => [%{"type" => "valueref", "ref" => "a.b"}]
    }

    c |> Map.put("blocks", c["blocks"] ++ [ref]) |> Map.delete("body_html")
  end

  defp failed("ambiguous_source", c) do
    Map.merge(c, %{
      "body_html" => c["body_html"] <> "<p>Text only the cache holds.</p>",
      "body_html_sv" => Render.body_html_render_version()
    })
  end

  for code <-
        ~w(bpml_unavailable redacted_source invalid_blocks semantic_empty bpml_unprintable ambiguous_source) do
    test "a view that fails as #{code} refuses the pull and the push alike, and writes nothing" do
      schema!(text: true)
      slug = slug("fail")
      paper!(slug, blocks())
      {bpml, rev} = pull!(slug)

      fail!(unquote(code), slug)

      before = row(slug)
      pulled = pull(slug)
      pushed = sync(slug, bpml, rev)

      assert pulled.status == 422
      assert pushed.status == 422
      pull_error = Map.take(json_response(pulled, 422)["error"], ["code", "message", "hint"])
      push_error = Map.take(json_response(pushed, 422)["error"], ["code", "message", "hint"])
      assert pull_error["code"] == unquote(code)
      assert push_error == pull_error
      assert row(slug) == before

      for text <- hidden_text(slug), body <- [pulled.resp_body, pushed.resp_body] do
        refute body =~ text
      end
    end
  end
end
