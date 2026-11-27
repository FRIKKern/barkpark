defmodule BarkparkWeb.Studio.TopRichTextHtmlBodyExactTest do
  @moduledoc """
  task-62e3d093b98a3bc3 (#29116 review): a legacy `body` the store holds as
  an HTML string (`HtmlBody.field?/2`) was read under the lock by its
  drawing (`HtmlBody.same?/2`, `PortableText.from_html/1`). That drops an
  image, an iframe and a paragraph's class, so B's write that changed the
  string only there read as the value A's page showed, and A's post was
  written over it with no banner. #29116 r2 reads a Portable Text field
  holding a string by the exact string; a legacy body is now read the same.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import BarkparkWeb.ObjectRichText

  alias Barkpark.Content
  alias Barkpark.Content.Forms.HtmlBody
  alias BarkparkWeb.PageSeen

  @moduletag :studio_live

  @banner ~s([data-test-id="doc-conflict-banner"])

  setup %{conn: conn} do
    c = setup_doc(conn)
    put_body(c, "<p>body0</p>")
    c
  end

  defp body(c), do: stored(c)["body"]

  # B's write through the store, as `/v1` makes it: the string as given.
  defp put_body(c, value) do
    {doc, _, _} = Content.fetch_doc_with_draft(c.type, c.id, "production")
    content = Map.put(doc.content, "body", value)

    {:ok, _} =
      Content.upsert_document(
        c.type,
        %{"doc_id" => "drafts." <> c.id, "title" => doc.title, "content" => content},
        "production"
      )
  end

  defp tab(c, surface) do
    path =
      case surface do
        :desk -> "#{c.root}/_desk/#{c.type};#{c.id}"
        :studio -> "#{c.root}/#{c.type}/#{c.id}"
      end

    {:ok, view, _html} = live(c.conn, path)
    render_async(view, 5_000)
    assert eventually(fn -> has_element?(view, "#editor-form") end)
    view
  end

  defp page(view), do: view |> PageSeen.seen() |> Map.put("v", 2)

  defp post(view, target, body, seen, title \\ "T0") do
    view
    |> element("#editor-form")
    |> render_change(%{
      "_target" => [target],
      "doc" => %{"title" => title, "body" => body},
      "_bp_seen" => Jason.encode!(seen)
    })
  end

  defp legacy!(c) do
    {:ok, schema} = Content.get_schema(c.type, "production")
    field = Enum.find(schema.fields, &(&1["name"] == "body"))
    assert HtmlBody.field?(field, body(c)), "body is not a legacy HTML body: no test"
  end

  # B's string differs from body0 only where `PortableText.from_html/1`
  # drops it, so it draws as body0.
  @bs [
    {"B adds an image", ~s(<p>body0</p><img src="x.png">)},
    {"B adds an iframe", ~s(<p>body0</p><iframe src="https://y"></iframe>)},
    {"B adds a class", ~s(<p class="lead">body0</p>)}
  ]

  test "the B strings draw as body0: the probes below mean something" do
    for {_label, b} <- @bs do
      refute b == "<p>body0</p>"
      assert HtmlBody.same?(b, "<p>body0</p>"), "#{b} does not draw as body0: no test"
    end
  end

  for surface <- [:desk, :studio] do
    @surface surface

    for {label, b_val} <- @bs do
      @b_val b_val

      test "#{surface} race, #{label}: B's write lands under A's post: B's kept, A held", c do
        legacy!(c)
        a = tab(c, @surface)
        seen = page(a)
        b_save = fn -> Task.await(Task.async(fn -> put_body(c, @b_val) end)) end

        html = inside(a, b_save, fn -> post(a, "doc[body]", "<p>body0 A</p>", seen) end)

        # On main: A's "<p>body0 A</p>" was written over B's string.
        assert body(c) == @b_val, "A's post was written over B's string: #{inspect(body(c))}"
        assert html =~ "doc-conflict-banner", "A was not held"
        assert has_element?(a, @banner)
      end

      test "#{surface} race, #{label}: under A's title key the body is left as B wrote it, no banner",
           c do
        a = tab(c, @surface)
        seen = page(a)
        b_save = fn -> Task.await(Task.async(fn -> put_body(c, @b_val) end)) end

        html =
          inside(a, b_save, fn -> post(a, "doc[title]", "<p>body0</p>", seen, "T0 A") end)

        assert body(c) == @b_val, "A's unchanged body was written over B's string"
        refute html =~ "doc-conflict-banner", "A was held with no words of A's in the body"
      end
    end

    test "#{surface} control: A alone types on the stored string: written, no banner, then again",
         c do
      a = tab(c, @surface)
      html = post(a, "doc[body]", "<p>body0 A1</p>", page(a))
      assert body(c) == "<p>body0 A1</p>"
      refute html =~ "doc-conflict-banner"

      html = post(a, "doc[body]", "<p>body0 A1 A2</p>", page(a))
      assert body(c) == "<p>body0 A1 A2</p>"
      refute html =~ "doc-conflict-banner"
    end

    test "#{surface} control: A alone types on a stored string with markup the editor drops: written",
         c do
      put_body(c, ~s(<p class="lead">body0</p>))
      a = tab(c, @surface)
      html = post(a, "doc[body]", "<p>body0 A1</p>", page(a))
      assert body(c) == "<p>body0 A1</p>"
      refute html =~ "doc-conflict-banner"
    end
  end
end
