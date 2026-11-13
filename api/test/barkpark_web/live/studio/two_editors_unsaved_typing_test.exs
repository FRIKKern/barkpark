defmodule BarkparkWeb.Studio.TwoEditorsUnsavedTyping.HaltOnFail do
  @moduledoc false
  # A before_save hook that refuses any write whose title, excerpt or slug
  # holds "FAIL": a real `{:error, {:halted, _}}` from the writer, so the
  # editor's save answers "Save cancelled" (a save that did not land).
  def lifecycle_hooks, do: %{before_save: [&__MODULE__.halt/1]}

  def halt(%{doc: doc}) do
    content = Map.get(doc, "content") || %{}
    texts = [Map.get(doc, "title"), content["excerpt"], content["slug"]]

    texts =
      Enum.map(texts, fn
        %{"current" => s} -> s
        s -> s
      end)

    if Enum.any?(texts, &(is_binary(&1) and String.contains?(String.downcase(&1), "fail"))),
      do: {:halt, "forced by the test"},
      else: :ok
  end

  def halt(_), do: :ok
end

defmodule BarkparkWeb.Studio.TwoEditorsUnsavedTypingTest do
  @moduledoc """
  Follow-ups from the #25880 review (task-6f5426c4b04de74b, J05): B's save
  did not land, and A saves.

  A save that did not land left the form buffer at the value from before the
  typing, so a remote save "kept" that old value, not B's typing. The banner
  "Updated by another user — your unsaved edits are kept" stayed up after B's
  next save landed. A failed slug generate named no unsaved field, so a remote
  save after an earlier failure replaced it.

  The failure is real: a `before_save` hook halts any write holding "FAIL".
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.TwoEditorsUnsavedTyping.HaltOnFail

  @dataset "production"

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "tu_post_#{n}"
    doc_id = "tu-post-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "TU posts",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "title" => "Title", "type" => "string"},
            %{"name" => "excerpt", "title" => "Excerpt", "type" => "string"},
            %{"name" => "slug", "title" => "Slug", "type" => "slug"}
          ]
        },
        @dataset
      )

    {:ok, _} =
      Content.create_document(
        type,
        %{"doc_id" => doc_id, "title" => "Fixture post", "content" => %{"excerpt" => "First"}},
        @dataset
      )

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "tu-editors-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "tu-editors", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})

    prior = Application.get_env(:barkpark, :plugins)
    Application.put_env(:barkpark, :plugins, [HaltOnFail])
    on_exit(fn -> Application.put_env(:barkpark, :plugins, prior) end)

    url = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio/#{type}/#{doc_id}"
    {:ok, conn: conn, url: url, type: type, doc_id: doc_id}
  end

  defp open(c) do
    {:ok, view, _html} = live(c.conn, c.url)
    view
  end

  defp shown(view, name) do
    html = view |> element(~s(#editor-form input[name="doc[#{name}]"])) |> render()
    [_, value] = Regex.run(~r/value="([^"]*)"/, html)
    value
  end

  defp post_form(view, name, form) do
    view
    |> element("#editor-form")
    |> render_change(%{"_target" => ["doc", name], "doc" => form})
  end

  defp type_in(view, name, text) do
    form = %{"title" => shown(view, "title"), "excerpt" => shown(view, "excerpt")}
    post_form(view, name, Map.update!(form, name, &(&1 <> text)))
  end

  defp stored(c) do
    {doc, _draft?, _published?} = Content.fetch_doc_with_draft(c.type, c.doc_id, @dataset)
    {doc.title, (doc.content || %{})["excerpt"]}
  end

  defp banner?(view), do: has_element?(view, ~s([data-test-id="doc-conflict-banner"]))

  test "B's save did not land; A saves another field: B keeps its typing and gets A's", c do
    a = open(c)
    b = open(c)

    type_in(b, "excerpt", " FAIL")
    assert stored(c) == {"Fixture post", "First"}

    type_in(a, "title", " A2")
    render(b)

    assert shown(b, "title") == "Fixture post A2"
    assert shown(b, "excerpt") == "First FAIL"
    assert banner?(b)
  end

  test "the banner goes when B's next save lands", c do
    a = open(c)
    b = open(c)

    type_in(b, "excerpt", " FAIL")
    type_in(a, "title", " A2")
    render(b)
    assert banner?(b)

    post_form(b, "excerpt", %{"title" => shown(b, "title"), "excerpt" => "First B-ok"})

    assert stored(c) == {"Fixture post A2", "First B-ok"}
    refute banner?(b)
  end

  test "a slug generate that did not land is kept over A's save, with the earlier typing", c do
    a = open(c)
    b = open(c)

    # B's title typing does not land; neither does the slug made from it.
    type_in(b, "excerpt", " FAIL")
    post_form(b, "title", %{"title" => "Fail title", "excerpt" => "First FAIL"})
    render_click(b, "slug-generate", %{"field" => "slug"})

    type_in(a, "title", " A2")
    render(b)

    form = :sys.get_state(b.pid).socket.assigns.editor_form
    assert form["excerpt"] == "First FAIL"
    assert form["title"] == "Fail title"
    assert form["slug"] in ["fail-title", %{"_type" => "slug", "current" => "fail-title"}]
  end
end
