defmodule BarkparkWeb.BulldocsBpmlReaderViewTest do
  @moduledoc """
  Every BPML answer about a Paper prints the reader's view of it
  (`Papers.BpmlView`): the pull, its title, and the answers to a push that
  updates or creates the Paper. And a push compares against that view, so a
  block that spells as the pull showed it is not edited.

  The Paper's schema hides a block field (`text`) and the description, so the
  reader's view of a heading is empty and prints no description. The rows carry no cached `body_html`, the case in which
  the reader prints them (task-6c7b44bee33f8333 is the cached case).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Content, LabelFixtures, Repo, Tenancy}

  @ds "production"
  @token "barkpark-test-ingest-token"
  @hidden "PRIVATE_HEADING"

  defp t(v), do: %{"type" => "text", "value" => v}
  defp slug(name), do: "bpml-reader-view-#{name}-#{System.unique_integer([:positive])}"
  defp heading, do: %{"id" => "h", "type" => "heading", "level" => 2, "text" => @hidden}
  defp para, do: %{"id" => "p", "type" => "paragraph", "content" => [t("Visible.")]}

  # A Paper whose title comes from its heading, stored with no HTML cache.
  defp paper!(slug, blocks) do
    {:ok, paper} = Content.upsert_paper(LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks}))
    content = paper.content |> Map.put("blocks", blocks) |> Map.delete("body_html")
    paper |> Ecto.Changeset.change(content: content) |> Repo.update!()
  end

  defp hide_block_text! do
    scope = [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

    fields = [
      %{"name" => "title", "type" => "string"},
      %{"name" => "description", "type" => "string", "private" => true},
      %{
        "name" => "blocks",
        "type" => "array",
        "of" => [
          %{
            "type" => "object",
            "fields" => [%{"name" => "text", "type" => "string", "private" => true}]
          }
        ]
      }
    ]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "paper", "title" => "Papers", "visibility" => "public", "fields" => fields},
        @ds,
        scope
      )
  end

  defp pull(slug), do: get(build_conn(), "/papers/#{slug}/source", %{"format" => "bpml"})

  defp pull!(slug) do
    resp = pull(slug)
    [rev] = get_resp_header(resp, "x-paper-rev")
    {response(resp, 200), rev}
  end

  defp sync(slug, bpml, rev) do
    build_conn()
    |> put_req_header("authorization", "Bearer #{@token}")
    |> put_req_header("content-type", "application/json")
    |> post("/v1/plugins/bulldocs/papers/#{slug}/sync", %{"bpml" => bpml, "baseRev" => rev})
  end

  defp stored_blocks(slug), do: get_in(Content.get_paper(slug).content, ["blocks"])

  # The answer prints what a pull of the row prints now, or no text when the
  # pull refuses.
  defp answers_the_pull!(slug, answer) do
    resp = pull(slug)
    description = Content.get_paper(slug).content["description"]
    refute (answer["bpml"] || "") =~ description

    if resp.status == 200,
      do: assert(answer["bpml"] == resp.resp_body),
      else: assert(answer["bpml"] == nil and is_binary(answer["bpml_unprintable"]))

    refute (answer["bpml"] || "") =~ @hidden
  end

  setup do
    LabelFixtures.register_tags!(@ds)
    hide_block_text!()
    :ok
  end

  test "the pull's title is the reader's: a hidden heading is not printed as the title" do
    slug = slug("title")
    paper!(slug, [heading(), para()])
    assert Content.get_paper(slug).title == @hidden

    {bpml, _rev} = pull!(slug)
    assert bpml =~ ~s(<h2 id="h"></h2>)
    refute bpml =~ @hidden

    json = get(build_conn(), "/papers/#{slug}/source") |> json_response(200)
    refute json["title"] == @hidden
  end

  test "an unedited push keeps the field the pull hid" do
    slug = slug("unedited")
    paper!(slug, [heading(), para()])
    {bpml, rev} = pull!(slug)

    assert json_response(sync(slug, bpml, rev), 200)["unchanged"] == true
    assert [heading(), para()] == stored_blocks(slug)
  end

  test "the answer to a push that updates a Paper prints the reader's view" do
    slug = slug("update")
    paper!(slug, [heading(), para()])
    {bpml, rev} = pull!(slug)

    answer = sync(slug, String.replace(bpml, "Visible.", "Edited."), rev) |> json_response(200)
    assert answer["ok"] == true
    head = heading()
    assert [^head, %{"content" => [%{"value" => "Edited."}]}] = stored_blocks(slug)
    answers_the_pull!(slug, answer)
  end

  test "the answer to a push that creates a Paper prints the reader's view" do
    # The text a pull printed for another Paper before its field was hidden,
    # meta included; that Paper is gone, so the new one duplicates nothing.
    Content.upsert_schema(
      %{"name" => "paper", "title" => "Papers", "visibility" => "public", "fields" => []},
      @ds,
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    )

    source = slug("create-source")
    paper!(source, [heading(), para()])
    {bpml, _rev} = pull!(source)
    assert bpml =~ @hidden
    Repo.delete!(Content.get_paper(source))
    hide_block_text!()

    slug = slug("create")
    answer = sync(slug, String.replace(bpml, source, slug), "0") |> json_response(200)
    assert answer["created"] == true
    answers_the_pull!(slug, answer)
  end
end
