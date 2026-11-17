defmodule BarkparkWeb.Studio.DocumentActionsCarryTheirDocumentTest do
  @moduledoc """
  task-176bd529276ff8b3: a document action is run for the document it was
  pressed in, or not at all.

  Publish, Unpublish, Delete, Discard draft, Duplicate, a revision's Restore
  and the confirm of each one's dialog ran against whatever document the
  socket held when they arrived. Delete confirmed in document A that reached
  the server after the pane had opened document B deleted B. Each now names
  its document (`PostIdentity.pressed/3`); the mark is the one the page
  carries, read here from the rendered page (`EditorPost`).

  A dialog one of them opened is closed when the pane opens another document.

  Both surfaces: the desk and the old Studio page.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Tenancy
  alias BarkparkWeb.EditorPost
  alias BarkparkWeb.Studio.StudioLive.PostIdentity

  @dataset "production"

  # Every dialog a document action opens, on either surface.
  @dialogs [
    "[data-desk-dialog]",
    "#delete-modal-dialog",
    "#discard-modal-dialog",
    "#unpublish-guard-dialog",
    "#history-modal-dialog"
  ]

  setup %{conn: conn} do
    n = System.unique_integer([:positive])
    type = "action_identity_#{n}"
    a = "action-identity-a-#{n}"
    b = "action-identity-b-#{n}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Posts",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    # Each document is published and has a newer draft, so every action has
    # something to do to it.
    for {id, k} <- [{a, 1}, {b, 2}] do
      {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Pub #{k}"}, @dataset)
      {:ok, _} = Content.publish_document(id, type, @dataset)

      {:ok, _} =
        Content.upsert_document(
          type,
          %{"doc_id" => Content.draft_id(id), "title" => "Draft #{k}"},
          @dataset
        )
    end

    {ws, proj} = Barkpark.TenancyFixtures.ensure_default_scope!()
    raw = "action-identity-" <> Ecto.UUID.generate()
    ws_id = Tenancy.get_default_workspace().id
    {:ok, _} = Auth.create_token(raw, "action-identity", @dataset, ~w(read write admin), ws_id)
    conn = Plug.Test.init_test_session(conn, %{"api_token" => raw})
    base = "/w/#{ws.slug}/p/#{proj.slug}/d/#{@dataset}/studio"

    {:ok,
     conn: conn,
     type: type,
     a: a,
     b: b,
     studio: {&"#{base}/#{type}/#{&1}", "#editor-form"},
     desk: {&"#{base}/_desk/#{type};#{&1}", "[data-pane-editing] #editor-form"}}
  end

  defp await(view, sel, id) do
    want = ~s(#{sel}[phx-value-_bp_doc*="#{id}"])
    assert Enum.any?(1..200, fn _ -> has_element?(view, want) or (Process.sleep(10) && false) end)
  end

  defp open(c, surface, id) do
    {url, sel} = Map.fetch!(c, surface)
    {:ok, view, _html} = live(c.conn, url.(id))
    render_async(view, 5_000)
    await(view, sel, id)
    {view, sel}
  end

  # The pane opens another document, as a click on its row does.
  defp goes_to({view, sel}, c, surface, id) do
    {url, _sel} = Map.fetch!(c, surface)
    render_patch(view, url.(id))
    await(view, sel, id)
  end

  # Every stored row of the type: a publish, an unpublish, a discard, a
  # delete, a restore and a copy each change this list.
  defp rows(c) do
    Barkpark.Repo.all(
      from d in Document,
        where: d.type == ^c.type and d.dataset == @dataset,
        order_by: d.doc_id,
        select: {d.doc_id, d.title, d.status}
    )
  end

  defp rows_of(c, id), do: Enum.filter(rows(c), fn {doc_id, _, _} -> pub(doc_id) == id end)
  defp pub(doc_id), do: Content.published_id(doc_id)

  defp dialog?(view), do: Enum.any?(@dialogs, &has_element?(view, &1))
  defp flash(view), do: :sys.get_state(view.pid).socket.assigns.flash

  # The first version of the document: "Pub n", which its draft is not.
  defp revision(c, id) do
    c.type
    |> then(&Content.list_revisions(id, &1, @dataset, limit: 30))
    |> Enum.find(&(&1.title != nil and String.starts_with?(&1.title, "Pub")))
    |> Map.fetch!(:id)
  end

  # Each press and the params its control sends, for the document `id`.
  @presses ~w(publish unpublish confirm-unpublish delete-doc confirm-delete discard-draft
              confirm-discard duplicate-doc restore-revision)

  defp params("restore-revision", c, id), do: %{"id" => revision(c, id)}
  defp params(_event, _c, _id), do: %{}

  # What the page and the store hold: a press that did nothing leaves it.
  defp held(c, view), do: {rows(c), dialog?(view), flash(view)}

  for surface <- [:desk, :studio] do
    @surface surface

    for event <- @presses do
      @event event

      test "#{surface}: #{event} pressed in A that arrives after the pane opened B does nothing",
           c do
        {view, _sel} = page = open(c, @surface, c.a)
        of_a = EditorPost.mark(view)
        params = params(@event, c, c.a)

        goes_to(page, c, @surface, c.b)
        refute EditorPost.mark(view) == of_a
        before = held(c, view)

        EditorPost.press(view, @event, params, of_a)
        render(view)

        assert held(c, view) == before
      end

      test "#{surface}: #{event} that names another document, or a made-up one, does nothing",
           c do
        {view, _sel} = open(c, @surface, c.a)
        params = params(@event, c, c.a)
        before = held(c, view)

        for mark <- [
              %{"_bp_doc" => c.a},
              %{"_bp_doc" => ""},
              %{"_bp_doc" => [@dataset, c.type, c.a]},
              %{"_bp_doc" => PostIdentity.value(@dataset, c.type, c.b)},
              %{"_bp_doc" => PostIdentity.value("other", c.type, c.a)}
            ] do
          # Not a reload either: the page stays.
          assert is_binary(render_click(view, @event, Map.merge(params, mark)))
          render(view)
          assert held(c, view) == before
        end
      end

      # A page whose script is older than the rule sends no mark at all.
      test "#{surface}: #{event} with no mark at all does nothing and reloads the page", c do
        {view, _sel} = open(c, @surface, c.a)
        {url, _sel} = Map.fetch!(c, @surface)
        before = rows(c)

        assert {:error, {:redirect, %{to: to}}} =
                 render_click(view, @event, params(@event, c, c.a))

        assert URI.decode(to) == URI.decode(url.(c.a))
        assert rows(c) == before
      end

      test "#{surface}: #{event} pressed in the open document is run for it", c do
        {view, _sel} = open(c, @surface, c.b)
        of_a = rows_of(c, c.a)
        before = {rows(c), dialog?(view)}

        EditorPost.press(view, @event, params(@event, c, c.b))
        render(view)

        refute {rows(c), dialog?(view)} == before
        assert rows_of(c, c.a) == of_a
      end
    end

    for {opener, confirm, control} <- [
          {"delete-doc", "confirm-delete",
           %{desk: "[data-desk-confirm=delete]", studio: "#delete-modal-dialog .btn-destructive"}},
          {"discard-draft", "confirm-discard",
           %{desk: "[data-test-id=confirm-discard]", studio: "[data-test-id=confirm-discard]"}}
        ] do
      @opener opener
      @confirm confirm
      @control control[surface]

      test "#{surface}: the dialog #{opener} opened in A is closed once the pane opens B, " <>
             "and back in A",
           c do
        {view, _sel} = page = open(c, @surface, c.a)
        EditorPost.press(view, @opener)
        assert dialog?(view)
        before = rows(c)

        goes_to(page, c, @surface, c.b)
        refute dialog?(view)

        goes_to(page, c, @surface, c.a)
        refute dialog?(view)
        assert rows(c) == before
      end

      test "#{surface}: #{confirm} from the dialog's own button, with the page's mark, is run",
           c do
        {view, _sel} = open(c, @surface, c.a)
        of_b = rows_of(c, c.b)
        EditorPost.press(view, @opener)
        before = rows_of(c, c.a)

        EditorPost.press_on(view, element(view, @control))
        render(view)

        refute rows_of(c, c.a) == before
        assert rows_of(c, c.b) == of_b
      end
    end

    test "#{surface}: the history opened in A is closed once the pane opens B", c do
      {view, _sel} = page = open(c, @surface, c.a)
      render_click(view, "show-history", %{})
      assert has_element?(view, "#history-modal-dialog")

      goes_to(page, c, @surface, c.b)
      refute has_element?(view, "#history-modal-dialog")
    end

    test "#{surface}: paper-publish names its document too", c do
      {view, _sel} = page = open(c, @surface, c.a)
      {url, _sel} = Map.fetch!(c, @surface)
      of_a = EditorPost.mark(view)

      goes_to(page, c, @surface, c.b)
      before = held(c, view)
      EditorPost.press(view, "paper-publish", %{}, of_a)
      render(view)
      assert held(c, view) == before

      assert {:error, {:redirect, %{to: to}}} = render_click(view, "paper-publish", %{})
      assert URI.decode(to) == URI.decode(url.(c.b))
    end
  end

  test "the page carries the open document's mark outside the form, the form's own", c do
    for surface <- [:desk, :studio] do
      {view, _sel} = open(c, surface, c.a)
      html = render(view)
      assert [_, held] = Regex.run(~r/<span[^>]*\sid="bp-doc"[^>]*\sdata-bp-doc="([^"]*)"/, html)
      assert String.replace(held, "&quot;", ~s(")) == PostIdentity.value(@dataset, c.type, c.a)
      assert EditorPost.mark(view) == %{"_bp_doc" => PostIdentity.value(@dataset, c.type, c.a)}
    end
  end
end
