defmodule BarkparkWeb.PaperReaderViewAnswersTest do
  @moduledoc """
  Every answer that carries a Paper carries the caller's view of it: the
  blocks, the title and the copies derived from them follow the same field
  rules `Envelope` applies to the Paper's own fields, for the same caller.

  The Paper here is written by the ordinary write path, so it is a row as any
  stored one. Its schema hides a block field (a heading's `text`) and a label
  field (`description`). A caller without the right to see them must not find
  either text anywhere in the bytes of any answer. A Paper whose view hides a
  field is answered without HTML; its reader page renders it. A caller with
  the right, and a Paper whose view hides nothing, get the full answer.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, LabelFixtures, Tenancy}
  alias Barkpark.Content.{CallerContext, Envelope}

  @ds "production"
  @block_word "HIDDENBLOCKWORD"
  @label_word "HIDDENLABELWORD"
  @hidden [@block_word, @label_word]

  defp t(v), do: %{"type" => "text", "value" => v}

  defp scope,
    do: [
      workspace_id: Tenancy.get_default_workspace().id,
      project_id: Tenancy.get_default_project().id
    ]

  defp put_schema!(fields) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "paper", "title" => "Papers", "visibility" => "public", "fields" => fields},
        @ds,
        scope()
      )
  end

  defp hiding_fields do
    [
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
  end

  defp paper!(slug) do
    blocks = [
      %{"id" => "h", "type" => "heading", "level" => 1, "text" => "#{@block_word} heading"},
      %{
        "id" => "p",
        "type" => "paragraph",
        "content" => [t("Visibleword paragraph for every reader.")]
      },
      %{"id" => "h2", "type" => "heading", "level" => 2, "text" => "#{@block_word} again"},
      # The hidden field inside a nested child block, two sections deep.
      %{
        "id" => "s",
        "type" => "section",
        "title" => "Section",
        "children" => [
          %{"id" => "sp", "type" => "paragraph", "content" => [t("Inner visible text.")]},
          %{
            "id" => "s2",
            "type" => "section",
            "title" => "Inner section",
            "children" => [
              %{
                "id" => "nh",
                "type" => "heading",
                "level" => 3,
                "text" => "#{@block_word} nested"
              },
              %{"id" => "np", "type" => "paragraph", "content" => [t("Deeper visible text.")]}
            ]
          }
        ]
      }
    ]

    description =
      "A description long enough for the label spine, carrying #{@label_word} in its text."

    {:ok, paper} =
      Content.upsert_paper(
        LabelFixtures.paper_attrs(%{slug: slug, blocks: blocks, description: description})
      )

    paper
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp callers(tokens) do
    [{"anonymous", build_conn()}, {"read token", bearer(build_conn(), tokens.reader)}]
  end

  defp leaks(body) when is_binary(body), do: Enum.filter(@hidden, &String.contains?(body, &1))

  setup do
    LabelFixtures.register_tags!(@ds)
    put_schema!(hiding_fields())

    reader = "prv-reader-#{System.unique_integer([:positive])}"
    admin = "prv-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(reader, "reader view reader", @ds, ["read"])
    {:ok, _} = Auth.create_token(admin, "reader view admin", @ds, ["admin"])

    slug = "prv-#{System.unique_integer([:positive])}"
    paper = paper!(slug)
    %{slug: slug, paper: paper, tokens: %{reader: reader, admin: admin}}
  end

  describe "a caller without the right" do
    test "finds a hidden field's text nowhere in any data answer that carries the Paper",
         %{slug: slug, tokens: tokens} do
      answers = [
        {"list", "/v1/data/query/#{@ds}/paper", %{}},
        {"one", "/v1/data/doc/#{@ds}/paper/#{slug}", %{}},
        {"search", "/v1/data/search/#{@ds}", %{"q" => "Visibleword"}},
        {"groq", "/v1/data/groq/#{@ds}", %{"query" => ~s(*[_type == "paper"])}},
        {"export", "/v1/data/export/#{@ds}", %{}}
      ]

      found =
        for {who, conn} <- callers(tokens),
            {name, path, params} <- answers,
            resp = get(conn, path, params),
            resp.status == 200,
            assert(String.contains?(resp.resp_body, slug), "#{who} #{name} carries no Paper"),
            leaks(resp.resp_body) != [],
            do: {who, name, leaks(resp.resp_body)}

      assert found == []
    end

    test "is answered without HTML, and the title is the one the reader shows",
         %{slug: slug, tokens: tokens} do
      # The stored HTML holds the hidden text; the answer must not come from it.
      assert Content.get_paper(slug).content["body_html"] =~ @block_word

      for {who, conn} <- callers(tokens) do
        doc = get(conn, "/v1/data/doc/#{@ds}/paper/#{slug}") |> json_response(200)
        doc = doc["result"]

        refute Map.has_key?(doc, "body_html"), who
        refute Map.has_key?(doc["body"] || %{}, "html"), who
        assert doc["title"] == slug, who
        assert Enum.map(doc["blocks"], & &1["id"]) == ["h", "p", "h2", "s"], who
        assert leaks(Jason.encode!(doc)) == [], who
      end
    end

    test "finds no hidden text in the Paper's email", %{slug: slug, tokens: tokens} do
      for {who, conn} <- callers(tokens) do
        resp = get(conn, "/papers/#{slug}/email")
        assert resp.status == 200, who
        assert leaks(resp.resp_body) == [], who
      end
    end

    test "finds no hidden text in a live update or replay of the Paper", %{paper: paper} do
      schema = Content.Papers.reader_schema(paper, "paper", @ds)
      full = Envelope.render(paper, schema, :internal)

      for ctx <- [CallerContext.anonymous(), nil] do
        assert leaks(Jason.encode!(Envelope.redact(full, schema, ctx))) == []
        assert leaks(Jason.encode!(Envelope.render(paper, schema, ctx))) == []
      end
    end
  end

  defp hidden(text), do: %{"id" => "x", "type" => "heading", "level" => 2, "text" => text}

  defp redacted(paper, blocks) do
    schema = Content.Papers.reader_schema(paper, "paper", @ds)
    envelope = %{"_type" => "paper", "_id" => "x", "title" => "x", "blocks" => blocks}
    Jason.encode!(Envelope.redact(envelope, schema, CallerContext.anonymous()))
  end

  describe "a block field hidden at any depth" do
    test "is hidden in every container kind", %{paper: paper} do
      h = hidden(@block_word)

      containers = [
        %{"type" => "section", "children" => [h]},
        %{"type" => "callout", "blocks" => [h]},
        %{
          "type" => "steps",
          "steps" => [%{"title" => "One", "children" => [h], "blocks" => [h]}]
        },
        %{"type" => "tabs", "tabs" => [%{"label" => "One", "blocks" => [h]}]},
        %{"type" => "columns", "columns" => [[h], [%{"type" => "section", "children" => [h]}]]},
        %{"type" => "figure", "child" => h},
        %{"type" => "list", "items" => [%{"text" => @block_word, "children" => [h]}]}
      ]

      for container <- containers do
        assert leaks(redacted(paper, [container])) == [], inspect(container["type"])
      end
    end

    test "past 32 levels the rest is dropped, never passed through", %{paper: paper} do
      deep = fn depth, word ->
        leaf = %{"id" => "leaf", "type" => "paragraph", "content" => [t(word)]}

        Enum.reduce(1..depth, leaf, fn i, acc ->
          %{"id" => "s#{i}", "type" => "section", "children" => [acc]}
        end)
      end

      shallow = redacted(paper, [deep.(5, "SHALLOWVISIBLE"), deep.(40, "DEEPVISIBLE")])
      assert shallow =~ "SHALLOWVISIBLE"
      refute shallow =~ "DEEPVISIBLE"
    end
  end

  describe "the full answer" do
    test "reaches a caller with the right, unchanged", %{slug: slug, paper: paper, tokens: tokens} do
      doc =
        build_conn()
        |> bearer(tokens.admin)
        |> get("/v1/data/doc/#{@ds}/paper/#{slug}")
        |> json_response(200)

      assert leaks(Jason.encode!(doc["result"])) == @hidden

      schema = Content.Papers.reader_schema(paper, "paper", @ds)

      assert Envelope.render(paper, schema, %CallerContext{is_admin: true}) ==
               Envelope.render(paper, schema, :internal)
    end

    test "reaches every caller of a Paper whose view hides nothing", %{paper: paper} do
      put_schema!([%{"name" => "title", "type" => "string"}])
      schema = Content.Papers.reader_schema(paper, "paper", @ds)

      for ctx <- [CallerContext.anonymous(), nil] do
        assert Envelope.render(paper, schema, ctx) == Envelope.render(paper, schema, :internal)
        assert Envelope.title(paper, schema, ctx) == paper.title
      end
    end
  end
end
